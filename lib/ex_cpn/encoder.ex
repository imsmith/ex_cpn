defmodule ExCpn.Encoder do
  @moduledoc "Renders an `ExCpn.Net` back to canonical `.cpn.tcl` source. Comments are not preserved."

  alias ExCpn.Net

  @spec encode(Net.t()) :: String.t()
  def encode(%Net{} = net) do
    [
      "cpn-spec #{net.version}\n",
      section(Enum.map(net.imports, &"yang import #{&1}\n")),
      section(Enum.map(net.places, &"place #{pad(&1.name, net)} -type #{&1.type}\n")),
      section(Enum.map(net.init, fn {p, tok} -> "init #{p} #{token(tok)}\n" end)),
      Enum.map(net.transitions, &transition/1)
    ]
    |> IO.iodata_to_binary()
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end

  defp section([]), do: []
  defp section(lines), do: ["\n" | lines]

  defp pad(name, net) do
    width = net.places |> Enum.map(&String.length(&1.name)) |> Enum.max(fn -> 0 end)
    String.pad_trailing(name, width)
  end

  defp transition(t) do
    body =
      [
        arcs("in", t.in),
        t.guard && "  guard {#{t.guard.target} {#{t.guard.expr}}}\n",
        arcs("out", t.out),
        t.priority != 0 && "  priority #{t.priority}\n",
        t.label != "" && "  label #{quote_str(t.label)}\n"
      ]
      |> Enum.filter(& &1)

    ["\ntransition #{t.name} {\n", body, "}\n"]
  end

  defp arcs(_, []), do: nil

  defp arcs(kw, arcs),
    do:
      "  #{String.pad_trailing(kw, 5)} " <>
        Enum.map_join(arcs, " ", &"{#{&1.place} #{&1.expr}}") <> "\n"

  defp token(map) when map_size(map) == 0, do: "{}"
  defp token(map), do: "{" <> Enum.map_join(map, " ", fn {k, v} -> "#{k} #{v}" end) <> "}"

  defp quote_str(s), do: "\"" <> String.replace(s, ~r/["\\\[\$]/, &"\\#{&1}") <> "\""
end
