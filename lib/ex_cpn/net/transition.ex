defmodule ExCpn.Net.Transition do
  alias ExCpn.Net.{Arc, Guard}

  @moduledoc "A transition: in-arcs, out-arcs, optional guard, priority (default 0), label."
  @enforce_keys [:name]
  defstruct name: nil, in: [], out: [], guard: nil, priority: 0, label: "", line: nil

  @type t :: %__MODULE__{
          name: String.t(),
          in: [Arc.t()],
          out: [Arc.t()],
          guard: Guard.t() | nil,
          priority: integer,
          label: String.t(),
          line: pos_integer | nil
        }
end
