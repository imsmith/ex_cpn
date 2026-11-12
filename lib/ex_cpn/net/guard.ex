defmodule ExCpn.Net.Guard do
  @moduledoc """
  A transition guard. `:local` guards are evaluated by `ExCpn.Expr`; `:shell`
  and `:http` are delegated to the host; `:retry` names another transition
  and holds once that transition has exhausted its retry budget.
  """
  @enforce_keys [:target, :expr]
  defstruct [:target, :expr]
  @type target :: :local | :shell | :http | :retry
  @type t :: %__MODULE__{target: target, expr: String.t()}
end
