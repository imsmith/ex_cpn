defmodule ExCpn.Net.Place do
  @moduledoc "A typed place. `type` is `module:node`, naming a YANG container or grouping."
  @enforce_keys [:name, :type]
  defstruct [:name, :type, :line]
  @type t :: %__MODULE__{name: String.t(), type: String.t(), line: pos_integer | nil}
end
