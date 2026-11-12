defmodule ExCpn.Net.Arc do
  @moduledoc """
  One `in` or `out` entry of a transition.

  On an `in` arc, `expr` is the variable the consumed token is bound to.
  On an `out` arc, `expr` is `$var` to forward a bound token or a literal dict.
  """
  @enforce_keys [:place, :expr]
  defstruct [:place, :expr]
  @type t :: %__MODULE__{place: String.t(), expr: String.t()}
end
