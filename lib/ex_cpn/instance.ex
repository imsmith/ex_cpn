defmodule ExCpn.Instance do
  @moduledoc """
  One running net as a `gen_statem`. Lifecycle states are `:running`, `:busy` (a host action is
  in flight), and `:quiescent` (nothing enabled). The marking is data, never a state.

  Options:

    * `:net` (required) - an `ExCpn.Net`
    * `:actions` - `%{transition_name => action}`; see `t:action/0`. Bound transitions run their
      action under a `Task.Supervisor` owned by the instance before firing. Unbound transitions
      move tokens as the arcs say.
    * `:guard` - evaluator for `shell`/`http` guards; see `t:guard_fun/0`
    * `:journal` - `(event -> any)`; events are `{:fired, name, binding, marking}` and
      `{:failed, name, reason, count}`
    * `:max_retries` - failures before a transition is retired and its `retry` guard holders
      become enabled (default 3)
    * `:name` - registration: an atom, or any `:gen_statem` server name such as
      `{:via, Registry, {MyRegistry, key}}`

  Stopping the instance stops its task supervisor, so no action outlives it.
  """

  @behaviour :gen_statem

  alias ExCpn.{Marking, Net}

  @typedoc """
  A host action for a transition. Receives the transition name and the binding (`%{var => token}`).
  `{:ok, produced}` supplies out tokens by place; `:ok` lets the arcs decide; `{:error, reason}`
  or a raise counts as one failure.
  """
  @type action :: (String.t(), Marking.binding() ->
                     :ok | {:ok, %{String.t() => Net.token()}} | {:error, term})

  @typedoc "Host evaluator for `shell` and `http` guards."
  @type guard_fun :: (Net.Guard.t(), Marking.binding() -> boolean)

  @typedoc "Journal event."
  @type event ::
          {:fired, String.t(), Marking.binding(), Marking.marking()}
          | {:failed, String.t(), term, pos_integer}

  defstruct [
    :net,
    :marking,
    :guard,
    :journal,
    :task,
    :tasks,
    actions: %{},
    retries: %{},
    max_retries: 3,
    last: nil
  ]

  # --- API -----------------------------------------------------------------

  @doc "Child spec with `restart: :transient`; `id` is `opts[:name]` or this module."
  @spec child_spec(keyword) :: Supervisor.child_spec()
  def child_spec(opts),
    do: %{
      id: opts[:name] || __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }

  @doc "Starts an instance. See the module docs for options."
  @spec start_link(keyword) :: :gen_statem.start_ret()
  def start_link(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, name} when is_atom(name) ->
        :gen_statem.start_link({:local, name}, __MODULE__, opts, [])

      {:ok, name} ->
        :gen_statem.start_link(name, __MODULE__, opts, [])

      :error ->
        :gen_statem.start_link(__MODULE__, opts, [])
    end
  end

  @doc "The current marking."
  @spec marking(:gen_statem.server_ref()) :: Marking.marking()
  def marking(ref), do: :gen_statem.call(ref, :marking)

  @doc "The lifecycle state."
  @spec state(:gen_statem.server_ref()) :: :running | :busy | :quiescent
  def state(ref), do: :gen_statem.call(ref, :state)

  @doc "Adds a token to a place and wakes a quiescent instance."
  @spec put_token(:gen_statem.server_ref(), String.t(), Net.token()) :: :ok
  def put_token(ref, place, token), do: :gen_statem.call(ref, {:put, place, token})

  @doc """
  Blocks until the instance has nothing left to fire, then returns the marking.

  On a net that never quiesces (a self-loop with no guard) this only returns by `timeout`.
  """
  @spec await_quiescent(:gen_statem.server_ref(), timeout) :: Marking.marking()
  def await_quiescent(ref, timeout \\ 5_000), do: :gen_statem.call(ref, :await, timeout)

  # --- callbacks -----------------------------------------------------------

  @impl true
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl true
  def init(opts) do
    net = Keyword.fetch!(opts, :net)
    {:ok, tasks} = Task.Supervisor.start_link()

    data = %__MODULE__{
      net: net,
      marking: Marking.initial(net),
      tasks: tasks,
      actions: Keyword.get(opts, :actions, %{}),
      guard: Keyword.get(opts, :guard),
      journal: Keyword.get(opts, :journal, fn _ -> :ok end),
      max_retries: Keyword.get(opts, :max_retries, 3)
    }

    {:ok, :running, data}
  end

  @impl true
  def handle_event(:enter, _old, :running, _data),
    do: {:keep_state_and_data, [{:state_timeout, 0, :advance}]}

  def handle_event(:enter, _old, _state, _data), do: :keep_state_and_data

  def handle_event({:call, from}, :marking, _state, data),
    do: {:keep_state_and_data, [{:reply, from, data.marking}]}

  def handle_event({:call, from}, :state, state, _data),
    do: {:keep_state_and_data, [{:reply, from, state}]}

  def handle_event({:call, from}, {:put, place, token}, state, data) do
    data = %{data | marking: Marking.put(data.marking, place, token)}
    reply = [{:reply, from, :ok}]

    if state == :quiescent,
      do: {:next_state, :running, data, reply},
      else: {:keep_state, data, reply}
  end

  def handle_event({:call, from}, :await, :quiescent, data),
    do: {:keep_state_and_data, [{:reply, from, data.marking}]}

  def handle_event({:call, _}, :await, _state, _data), do: {:keep_state_and_data, [:postpone]}

  def handle_event(kind, :advance, :running, data) when kind in [:internal, :state_timeout] do
    retired = for {name, n} <- data.retries, n >= data.max_retries, do: name
    opts = [guard: &guard(&1, &2, data), after: data.last, skip: retired]

    case Marking.enabled(data.net, data.marking, opts) do
      [] -> {:next_state, :quiescent, data}
      [{t, binding} | _] -> dispatch(data, t, binding)
    end
  end

  # Task result arrives first; the matching :DOWN follows and is ignored by the catch-all below.
  def handle_event(:info, {ref, result}, :busy, %{task: {ref, t, binding}} = data) do
    Process.demonitor(ref, [:flush])
    data = %{data | task: nil}

    case result do
      :ok ->
        {:next_state, :running, fired(data, t, binding, %{})}

      {:ok, produced} when is_map(produced) ->
        {:next_state, :running, fired(data, t, binding, produced)}

      {:error, why} ->
        {:next_state, :running, failed(data, t, why)}

      other ->
        {:next_state, :running, failed(data, t, {:bad_return, other})}
    end
  end

  def handle_event(
        :info,
        {:DOWN, ref, :process, _pid, reason},
        :busy,
        %{task: {ref, t, _}} = data
      ) do
    {:next_state, :running, failed(%{data | task: nil}, t, {:crashed, reason})}
  end

  def handle_event(:info, _msg, _state, _data), do: :keep_state_and_data

  # --- helpers -------------------------------------------------------------

  defp dispatch(data, t, binding) do
    case Map.fetch(data.actions, t.name) do
      {:ok, action} ->
        %Task{ref: ref} =
          Task.Supervisor.async_nolink(data.tasks, fn -> action.(t.name, binding) end)

        {:next_state, :busy, %{data | task: {ref, t, binding}}}

      :error ->
        {:repeat_state, fired(data, t, binding, %{}), []}
    end
  end

  defp fired(data, t, binding, produced) do
    marking = Marking.fire(t, data.marking, binding, produced)
    data.journal.({:fired, t.name, binding, marking})
    %{data | marking: marking, last: t.name}
  end

  defp failed(data, t, reason) do
    retries = Map.update(data.retries, t.name, 1, &(&1 + 1))
    data.journal.({:failed, t.name, reason, retries[t.name]})
    %{data | retries: retries, last: t.name}
  end

  # A retired transition (over budget) is never enabled; its `retry` guard holders become enabled.
  defp guard(%{target: :retry, expr: name}, _binding, data), do: retired?(data, name)
  defp guard(g, binding, %{guard: f}) when is_function(f, 2), do: f.(g, binding) == true
  defp guard(_, _, _), do: false

  defp retired?(data, name), do: Map.get(data.retries, name, 0) >= data.max_retries
end
