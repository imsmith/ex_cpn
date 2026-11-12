defmodule ExCpn.ParserTest do
  use ExUnit.Case, async: true

  @fixtures Path.join(__DIR__, "fixtures")

  defp fixture(name), do: ExCpn.parse_file(Path.join(@fixtures, name))

  test "parses the schema-check net" do
    assert {:ok, net} = fixture("avx-schema-check.cpn.tcl")
    assert net.version == "1.0"
    assert net.imports == ~w(avx-api-integration avx-azure avx-common avx-data-transformation)
    assert length(net.places) == 6
    assert ExCpn.Net.place(net, "alert-row").type == "avx-common:meta-attributes"
    assert net.init == %{"timer-tick" => %{}, "startup-signal" => %{}}
    assert length(net.transitions) == 8

    t = ExCpn.Net.transition(net, "fire-startup")
    assert [%{place: "startup-signal", expr: "s"}] = t.in
    assert [%{place: "controller-schema", expr: "$s"}] = t.out
    assert t.label =~ "startup"
  end

  test "parses guards with all four targets" do
    assert {:ok, poll} = fixture("avx-poll-cycle.cpn.tcl")

    assert %{target: :local, expr: "$l(age) > $l(max-fold-age-seconds)"} =
             ExCpn.Net.transition(poll, "prune-ledger").guard

    assert {:ok, deploy} = fixture("avx-deploy-orchestration.cpn.tcl")

    targets =
      deploy.transitions
      |> Enum.map(& &1.guard)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(& &1.target)
      |> Enum.uniq()

    assert Enum.sort(targets) == [:http, :retry, :shell]
  end

  test "multi-arc in and multi-arc out" do
    assert {:ok, poll} = fixture("avx-poll-cycle.cpn.tcl")
    t = ExCpn.Net.transition(poll, "handle-403")
    assert Enum.map(t.out, & &1.place) == ["controller-degraded", "alert-row"]
    t = ExCpn.Net.transition(poll, "ensure-session")
    assert Enum.map(t.in, & &1.expr) == ["req", "s"]
  end

  test "rejects a place without -type, with the line number" do
    assert {:error, {3, "place 'x' missing -type"}} = ExCpn.parse("cpn-spec 1.0\n\nplace x\n")
  end

  test "rejects bad guard targets" do
    assert {:error, {_, msg}} = ExCpn.parse("transition t {\n  guard {magic 1}\n}\n")
    assert msg =~ "guard target must be one of"
  end

  test "all fixtures round-trip through encode" do
    for f <- File.ls!(@fixtures) do
      assert {:ok, net} = fixture(f)
      assert {:ok, again} = ExCpn.parse(ExCpn.encode(net))

      strip = fn n ->
        %{
          n
          | places: Enum.map(n.places, &%{&1 | line: nil}),
            transitions: Enum.map(n.transitions, &%{&1 | line: nil})
        }
      end

      assert strip.(net) == strip.(again), f
    end
  end

  test "all fixtures validate" do
    for f <- File.ls!(@fixtures) do
      assert {:ok, net} = fixture(f)
      assert {:ok, _} = ExCpn.validate(net), f
    end
  end

  test "validator catches unknown places and retry targets" do
    {:ok, net} =
      ExCpn.parse(
        "cpn-spec 1.0\nplace a -type m:n\ntransition t {\n  in {a x}\n  out {b $x}\n  guard {retry nope}\n}\n"
      )

    assert {:error, problems} = ExCpn.validate(net)
    msgs = for {:error, m} <- problems, do: m
    assert Enum.any?(msgs, &(&1 =~ "unknown place 'b'"))
    assert Enum.any?(msgs, &(&1 =~ "unknown transition 'nope'"))
  end
end
