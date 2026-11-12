defmodule ExCpn.DoctestTest do
  use ExUnit.Case, async: true

  doctest ExCpn
  doctest ExCpn.Encoder
  doctest ExCpn.Expr
  doctest ExCpn.Marking
  doctest ExCpn.Net
  doctest ExCpn.Parser
  doctest ExCpn.Tcl
  doctest ExCpn.Validator
end
