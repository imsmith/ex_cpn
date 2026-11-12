defmodule ExCpn.Validator do
  @moduledoc "Structural checks on a parsed net. Mirrors the checks of the original Tcl spec-validator."

  alias ExCpn.{Expr, Net}

  @typedoc "Errors block a net from running; warnings are advisory."
  @type problem :: {:error | :warning, String.t()}

  @doc """
  Returns `{:ok, net}` when there are no errors, otherwise every problem found including warnings.

      iex> {:ok, net} = ExCpn.parse("cpn-spec 1.0\\nplace a -type m:n\\n")
      iex> ExCpn.Validator.validate(net)
      {:ok, net}
  """
  @spec validate(Net.t()) :: {:ok, Net.t()} | {:error, [problem]}
  def validate(%Net{} = net) do
    problems = problems(net)

    if Enum.any?(problems, &match?({:error, _}, &1)), do: {:error, problems}, else: {:ok, net}
  end

  @doc """
  Lists every problem, errors and warnings, without deciding pass or fail.

      iex> {:ok, net} = ExCpn.parse("cpn-spec 1.0\\nplace lonely -type m:n\\n")
      iex> ExCpn.Validator.problems(net)
      [{:warning, "place 'lonely' is not referenced by any transition"}]
  """
  @spec problems(Net.t()) :: [problem]
  def problems(%Net{} = net) do
    places = MapSet.new(Net.place_names(net))
    tnames = Enum.map(net.transitions, & &1.name)

    [
      dupes(Net.place_names(net), "place"),
      dupes(tnames, "transition"),
      for(
        {p, _} <- net.init,
        p not in places,
        do: {:error, "init references unknown place '#{p}'"}
      ),
      Enum.flat_map(net.transitions, &transition_problems(&1, places, MapSet.new(tnames))),
      unreferenced(net)
    ]
    |> List.flatten()
  end

  defp dupes(names, kind) do
    names
    |> Enum.frequencies()
    |> Enum.filter(fn {_, n} -> n > 1 end)
    |> Enum.map(fn {n, _} -> {:error, "duplicate #{kind} '#{n}'"} end)
  end

  defp transition_problems(t, places, tnames) do
    arcs =
      for {kw, arcs} <- [in: t.in, out: t.out],
          a <- arcs,
          a.place not in places,
          do: {:error, "transition '#{t.name}' #{kw} references unknown place '#{a.place}'"}

    guard =
      case t.guard do
        nil ->
          []

        %{target: :retry, expr: e} ->
          if e in tnames,
            do: [],
            else: [{:error, "transition '#{t.name}' retry guard names unknown transition '#{e}'"}]

        %{target: :local, expr: e} ->
          local_guard_problems(t.name, e)

        _ ->
          []
      end

    empty =
      if t.in == [] and t.out == [],
        do: [{:warning, "transition '#{t.name}' has neither in nor out"}],
        else: []

    arcs ++ guard ++ empty
  end

  defp local_guard_problems(tname, expr) do
    case Expr.parse(expr) do
      {:ok, _} -> []
      {:error, m} -> [{:error, "transition '#{tname}' local guard: #{m}"}]
    end
  end

  defp unreferenced(net) do
    used = for t <- net.transitions, a <- t.in ++ t.out, into: MapSet.new(), do: a.place

    for p <- net.places,
        p.name not in used,
        do: {:warning, "place '#{p.name}' is not referenced by any transition"}
  end
end
