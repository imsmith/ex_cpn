defmodule ExCpn.Marking do
  @moduledoc """
  Pure token-game semantics. A marking is `%{place => [token]}`; each list is a multiset in arrival order.

  Guard evaluation: `local` guards are evaluated here. Other targets are delegated to the
  `:guard` option, a `(Guard.t, binding -> boolean)` function; without one they are disabled.
  """

  alias ExCpn.Net
  alias ExCpn.Net.Transition
  alias ExCpn.Expr

  @type marking :: %{String.t() => [Net.token()]}
  @type binding :: %{String.t() => Net.token()}
  @type opts :: [
          guard: (Net.Guard.t(), binding -> boolean),
          after: String.t() | nil,
          skip: [String.t()]
        ]

  @spec initial(Net.t()) :: marking
  def initial(%Net{} = net) do
    base = Map.new(net.places, &{&1.name, []})
    Enum.reduce(net.init, base, fn {p, tok}, m -> Map.update(m, p, [tok], &(&1 ++ [tok])) end)
  end

  @spec put(marking, String.t(), Net.token()) :: marking
  def put(marking, place, token), do: Map.update(marking, place, [token], &(&1 ++ [token]))

  @doc "First binding (one token per in-place) satisfying the guard, or nil."
  @spec binding(Transition.t(), marking, opts) :: binding | nil
  def binding(%Transition{} = t, marking, opts \\ []) do
    t.in
    |> Enum.map(fn a -> Enum.map(marking[a.place] || [], &{a.expr, &1}) end)
    |> product()
    |> Enum.find(fn pairs -> guard_ok?(t, Map.new(pairs), opts) end)
    |> case do
      nil -> nil
      pairs -> Map.new(pairs)
    end
  end

  @doc """
  Enabled transitions, highest priority first. Within a priority, source order rotated to start
  just after `opts[:after]` (the last fired transition), so self-loops cannot starve their siblings.
  """
  @spec enabled(Net.t(), marking, opts) :: [{Transition.t(), binding}]
  def enabled(%Net{} = net, marking, opts \\ []) do
    net.transitions
    |> Enum.reject(&(&1.name in Keyword.get(opts, :skip, [])))
    |> rotate_after(opts[:after])
    |> Enum.sort_by(& &1.priority, :desc)
    |> Enum.flat_map(fn t ->
      with(%{} = b <- binding(t, marking, opts), do: [{t, b}], else: (_ -> []))
    end)
  end

  defp rotate_after(ts, nil), do: ts

  defp rotate_after(ts, name) do
    case Enum.find_index(ts, &(&1.name == name)) do
      nil -> ts
      i -> Enum.drop(ts, i + 1) ++ Enum.take(ts, i + 1)
    end
  end

  @doc """
  Fires `t` under `binding`: consumes one bound token per in-place and produces out tokens.
  `produced` overrides the out token for the places it names; others follow the arc expression.
  """
  @spec fire(Transition.t(), marking, binding, %{String.t() => Net.token()}) :: marking
  def fire(%Transition{} = t, marking, binding, produced \\ %{}) do
    consumed =
      Enum.reduce(t.in, marking, fn a, m ->
        Map.update!(m, a.place, &List.delete(&1, binding[a.expr]))
      end)

    Enum.reduce(t.out, consumed, fn a, m ->
      put(m, a.place, Map.get(produced, a.place, out_token(a.expr, binding)))
    end)
  end

  @doc "Fires the first enabled transition. Returns `:quiescent` when nothing is enabled."
  @spec step(Net.t(), marking, opts) :: {:ok, Transition.t(), marking} | :quiescent
  def step(%Net{} = net, marking, opts \\ []) do
    case enabled(net, marking, opts) do
      [{t, b} | _] -> {:ok, t, fire(t, marking, b)}
      [] -> :quiescent
    end
  end

  @doc "Runs `step` fairly until quiescent or `max` firings. Returns fired transitions in order."
  @spec run(Net.t(), marking, opts, pos_integer) :: {marking, [Transition.t()]}
  def run(%Net{} = net, marking, opts \\ [], max \\ 10_000), do: run(net, marking, opts, max, [])

  defp run(_, m, _, 0, fired), do: {m, Enum.reverse(fired)}

  defp run(net, m, opts, n, fired) do
    last = with([t | _] <- fired, do: t.name, else: (_ -> nil))

    case step(net, m, Keyword.put(opts, :after, last)) do
      {:ok, t, m} -> run(net, m, opts, n - 1, [t | fired])
      :quiescent -> {m, Enum.reverse(fired)}
    end
  end

  defp out_token("$" <> var, binding), do: Map.get(binding, var, %{})

  defp out_token(literal, _) do
    case ExCpn.Parser.token(literal) do
      {:ok, tok} -> tok
      _ -> %{"value" => literal}
    end
  end

  defp guard_ok?(%{guard: nil}, _, _), do: true
  defp guard_ok?(%{guard: %{target: :local, expr: e}}, binding, _), do: Expr.truthy?(e, binding)

  defp guard_ok?(%{guard: g}, binding, opts) do
    case opts[:guard] do
      f when is_function(f, 2) -> f.(g, binding) == true
      _ -> false
    end
  end

  defp product([]), do: [[]]
  defp product([xs | rest]), do: for(x <- xs, tail <- product(rest), do: [x | tail])
end
