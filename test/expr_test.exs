defmodule ExCpn.ExprTest do
  use ExUnit.Case, async: true
  alias ExCpn.Expr

  @b %{"w" => %{"age" => "301", "max" => 300}, "s" => %{"current-state" => "denied"}, "n" => 4}

  test "fixture guards" do
    assert Expr.truthy?("$w(age) > 300", @b)
    refute Expr.truthy?("$w(age) > 400", @b)
    assert Expr.truthy?("$w(age) > $w(max)", @b)

    assert Expr.truthy?(
             ~S<$s(current-state) eq "unauthenticated" || $s(current-state) eq "denied">,
             @b
           )

    refute Expr.truthy?(~s|$s(current-state) eq "pending-authentication"|, @b)
  end

  test "precedence and arithmetic" do
    assert Expr.truthy?("1 + 2 * 3 == 7", %{})
    assert Expr.truthy?("(1 + 2) * 3 == 9", %{})
    assert Expr.truthy?("!0 && $n % 2 == 0", @b)
    assert Expr.truthy?("-$n < 0", @b)
  end

  test "missing values never satisfy a comparison" do
    refute Expr.truthy?("$missing > 1", @b)
    refute Expr.truthy?("$w(nope) eq \"x\"", @b)
    refute Expr.truthy?("$n / 0 == 1", @b)
  end

  test "parse errors" do
    assert {:error, _} = Expr.parse("1 +")
    assert {:error, _} = Expr.parse("(1")
    assert {:error, _} = Expr.parse("$a(b")
  end
end
