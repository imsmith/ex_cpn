defmodule ExCpn.Instance do
  @moduledoc """
  One running net as a `gen_statem`. Lifecycle states are `:running`, `:busy` (a host action is
  in flight), and `:quiescent` (nothing enabled). The marking is data, never a state.

  Options:

    * `:net` (required) - an `ExCpn.Net`
    * `:actions` - `%{transition_name => (name, binding -> :ok | {:ok, produced} | {:error, reason})}`.
      Bound transitions run their action in a monitored process before firing; `produced` maps
      out-place to token. Unbound transitions move tokens as the arcs say.
    * `:guard` - evaluator for `shell`/`http` guards, `(Guard.t, binding -> boolean)`
    * `:journal` - `(event -> any)`; events are `{:fired, name, binding, marking}` and
      `{:failed, name, reason, count}`
    * `:max_retries` - failures before a transition is retired and its `retry` guard holders
      become enabled (default 3)
    * `:name` - registration, as for `GenServer`
  """

  @behaviour :gen_statem

  alias ExCpn.{Marking, Net}

  defstruct [
    :net,
    :marking,
    :guard,
    :journal,
    :task,
    actions: %{},
    retries: %{},
    max_retries: 3,
    last: nil
  ]

  # --- API -----------------------------------------------------------------

  @doc "Child spec with `restart: :transient`; `id` is `opts[:name]` or this module."
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
      {:ok, name} -> :gen_statem.start_link(via(name), __MODULE__, opts, [])
      :error -> :gen_statem.start_link(__MODULE__, opts, [])
    end
  end

  defp via(name) when is_atom(name), do: {:local, name}
  defp via(other), do: other

  @doc "The current marking."
  @spec marking(:gen_statem.server_ref()) :: Marking.marking()
  def marking(ref), do: :gen_statem.call(ref, :marking)

  @doc "The lifecycle state."
  @spec state(:gen_statem.server_ref()) :: :running | :busy | :quiescent
  def state(ref), do: :gen_statem.call(ref, :state)

  @doc "Adds a token to a place and wakes a quiescent instance."
  @spec put_token(:gen_statem.server_ref(), String.t(), Net.token()) :: :ok
  def put_token(ref, place, token), do: :gen_statem.call(ref, {:put, place, token})

  @doc "Blocks until the instance has nothing left to fire, then returns the marking."
  @spec await_quiescent(:gen_statem.server_ref(), timeout) :: Marking.marking()
  def await_quiescent(ref, timeout \\ 5_000), do: :gen_statem.call(ref, :await, timeout)

  # --- callbacks -----------------------------------------------------------

  @impl true
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl true
  def init(opts) do
    net = Keyword.fetch!(opts, :net)

    data = %__MODULE__{
      net: net,
      marking: Marking.initial(net),
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

    if state == :quiescent,
      do: {:next_state, :running, data, [{:reply, from, :ok}]},
      else: {:keep_state, data, [{:reply, from, :ok}]}
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

  def handle_event(
        :info,
        {:DOWN, ref, :process, _pid, reason},
        :busy,
        %{task: {ref, t, binding}} = data
      ) do
    data = %{data | task: nil}

    case reason do
      {:result, :ok} ->
        {:next_state, :running, fired(data, t, binding, %{})}

      {:result, {:ok, produced}} when is_map(produced) ->
        {:next_state, :running, fired(data, t, binding, produced)}

      {:result, {:error, why}} ->
        {:next_state, :running, failed(data, t, why)}

      {:result, other} ->
        {:next_state, :running, failed(data, t, {:bad_return, other})}

      crash ->
        {:next_state, :running, failed(data, t, crash)}
    end
  end

  def handle_event(:info, _msg, _state, _data), do: :keep_state_and_data

  # --- helpers -------------------------------------------------------------

  defp dispatch(data, t, binding) do
    case Map.fetch(data.actions, t.name) do
      {:ok, action} ->
        {_pid, ref} =
          spawn_monitor(fn -> exit({:result, run_action(action, t.name, binding)}) end)

        {:next_state, :busy, %{data | task: {ref, t, binding}}}

      :error ->
        {:repeat_state, fired(data, t, binding, %{}), []}
    end
  end

  # Host actions are untrusted code at the library boundary: any raise becomes a
  # counted failure rather than killing the instance.
  defp run_action(action, name, binding) do
    action.(name, binding)
  rescue
    e -> {:error, {e, __STACKTRACE__}}
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
