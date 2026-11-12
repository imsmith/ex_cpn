defmodule ExCpn.InstanceTest do
  use ExUnit.Case, async: true
  alias ExCpn.Instance

  @net """
  cpn-spec 1.0
  place todo   -type m:n
  place hashed -type m:n
  place done   -type m:n
  place failed -type m:n
  init todo {}
  transition hash {
    in  {todo t}
    out {hashed $t}
  }
  transition publish {
    in  {hashed h}
    out {done $h}
  }
  transition give-up {
    in  {hashed h}
    guard {retry publish}
    out {failed $h}
  }
  """

  defp net, do: ExCpn.parse(@net) |> elem(1)

  test "bound actions run before firing and can produce tokens" do
    test = self()

    actions = %{
      "hash" => fn "hash", %{"t" => _} -> {:ok, %{"hashed" => %{"sha" => "abc"}}} end,
      "publish" => fn "publish", %{"h" => h} ->
        send(test, {:published, h})
        :ok
      end
    }

    pid = start_supervised!({Instance, net: net(), actions: actions, journal: &send(test, &1)})
    marking = Instance.await_quiescent(pid)
    assert marking["done"] == [%{"sha" => "abc"}]
    assert_received {:published, %{"sha" => "abc"}}
    assert_received {:fired, "hash", _, _}
    assert_received {:fired, "publish", _, _}
    assert Instance.state(pid) == :quiescent
  end

  test "a failing action is retried up to the budget, then its retry guard routes the token" do
    test = self()
    actions = %{"publish" => fn _, _ -> {:error, :boom} end}

    pid =
      start_supervised!(
        {Instance, net: net(), actions: actions, max_retries: 2, journal: &send(test, &1)}
      )

    marking = Instance.await_quiescent(pid)
    assert marking["failed"] == [%{}]
    assert marking["done"] == []
    assert_received {:failed, "publish", :boom, 1}
    assert_received {:failed, "publish", :boom, 2}
    assert_received {:fired, "give-up", _, _}
  end

  @tag :capture_log
  test "a crashing action counts as a failure, not an instance crash" do
    test = self()
    actions = %{"hash" => fn _, _ -> raise "nope" end}

    pid =
      start_supervised!(
        {Instance, net: net(), actions: actions, max_retries: 1, journal: &send(test, &1)}
      )

    marking = Instance.await_quiescent(pid)
    assert marking["todo"] == [%{}]
    assert_received {:failed, "hash", {:crashed, {%RuntimeError{message: "nope"}, _}}, 1}
    assert Instance.state(pid) == :quiescent
  end

  test "stopping the instance stops an in-flight action" do
    test = self()

    actions = %{
      "hash" => fn _, _ ->
        send(test, {:action_pid, self()})
        Process.sleep(:infinity)
      end
    }

    start_supervised!({Instance, net: net(), actions: actions})
    assert_receive {:action_pid, action_pid}
    ref = Process.monitor(action_pid)
    :ok = stop_supervised!(Instance)
    assert_receive {:DOWN, ^ref, :process, ^action_pid, _}
  end

  test "registers under an atom name and via a Registry" do
    start_supervised!({Instance, net: net(), name: :cpn_named})
    assert %{"done" => [%{}]} = Instance.await_quiescent(:cpn_named)

    start_supervised!({Registry, keys: :unique, name: ExCpn.TestRegistry})
    via = {:via, Registry, {ExCpn.TestRegistry, "net-1"}}
    start_supervised!(Supervisor.child_spec({Instance, net: net(), name: via}, id: :via_instance))
    assert %{"done" => [%{}]} = Instance.await_quiescent(via)
  end

  test "put_token wakes a quiescent instance" do
    pid = start_supervised!({Instance, net: net()})
    assert %{"done" => [%{}]} = Instance.await_quiescent(pid)
    :ok = Instance.put_token(pid, "todo", %{"id" => 2})
    assert %{"done" => [%{}, %{"id" => 2}]} = Instance.await_quiescent(pid)
  end
end
