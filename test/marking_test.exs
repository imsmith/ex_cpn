defmodule ExCpn.MarkingTest do
  use ExUnit.Case, async: true
  alias ExCpn.Marking

  @fixtures Path.join(__DIR__, "fixtures")

  setup_all do
    {:ok, net} = ExCpn.parse_file(Path.join(@fixtures, "avx-schema-check.cpn.tcl"))
    %{net: net}
  end

  test "initial marking seeds init places", %{net: net} do
    m = Marking.initial(net)
    assert m["timer-tick"] == [%{}]
    assert m["alert-row"] == []
  end

  test "walks the schema-check net fairly despite its self-loop", %{net: net} do
    # fetch-controller-schema is a self-loop and never quiesces; rotation keeps the rest moving.
    {m, fired} = Marking.run(net, Marking.initial(net), [], 40)
    names = Enum.map(fired, & &1.name)
    assert hd(names) == "fire-startup"
    assert "compute-schema-hash" in names
    assert "write-drift-alert" in names
    assert length(m["alert-row"]) >= 1
  end

  test "guards select the binding and priority orders transitions" do
    {:ok, net} =
      ExCpn.parse("""
      cpn-spec 1.0
      place q -type m:n
      place old -type m:n
      place young -type m:n
      transition drop {
        in {q w}
        guard {local {$w(age) > 300}}
        out {old $w}
        priority 5
      }
      transition keep {
        in {q w}
        out {young $w}
      }
      """)

    m = %{"q" => [%{"age" => "10"}, %{"age" => "999"}], "old" => [], "young" => []}

    assert [{%{name: "drop"}, %{"w" => %{"age" => "999"}}}, {%{name: "keep"}, _}] =
             Marking.enabled(net, m)

    {m, fired} = Marking.run(net, m)
    assert Enum.map(fired, & &1.name) == ["drop", "keep"]
    assert m == %{"q" => [], "old" => [%{"age" => "999"}], "young" => [%{"age" => "10"}]}
  end

  test "non-local guards need an evaluator; source transitions mint empty tokens" do
    {:ok, net} =
      ExCpn.parse(
        "cpn-spec 1.0\nplace a -type m:n\ntransition src {\n  out {a $req}\n  guard {http \"ready\"}\n}\n"
      )

    assert Marking.enabled(net, Marking.initial(net)) == []

    assert [{_, %{}}] =
             Marking.enabled(net, Marking.initial(net), guard: fn %{target: :http}, _ -> true end)

    {:ok, _, m} = Marking.step(net, Marking.initial(net), guard: fn _, _ -> true end)
    assert m["a"] == [%{}]
  end

  test "fire accepts produced tokens from a host action" do
    {:ok, net} =
      ExCpn.parse(
        "cpn-spec 1.0\nplace a -type m:n\nplace b -type m:n\ninit a {}\ntransition t {\n  in {a x}\n  out {b $x}\n}\n"
      )

    t = ExCpn.Net.transition(net, "t")
    m = Marking.fire(t, Marking.initial(net), %{"x" => %{}}, %{"b" => %{"hash" => "abc"}})
    assert m == %{"a" => [], "b" => [%{"hash" => "abc"}]}
  end
end
