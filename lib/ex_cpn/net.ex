defmodule ExCpn.Net do
  @moduledoc "A parsed Coloured Petri Net. Places and transitions keep source order."

  defmodule Place do
    @moduledoc false
    @enforce_keys [:name, :type]
    defstruct [:name, :type, :line]
    @type t :: %__MODULE__{name: String.t(), type: String.t(), line: pos_integer | nil}
  end

  defmodule Arc do
    @moduledoc "An `in` arc binds a place's token to `var`; an `out` arc writes `expr` to a place."
    @enforce_keys [:place, :expr]
    defstruct [:place, :expr]
    @type t :: %__MODULE__{place: String.t(), expr: String.t()}
  end

  defmodule Guard do
    @moduledoc false
    @enforce_keys [:target, :expr]
    defstruct [:target, :expr]
    @type target :: :local | :shell | :http | :retry
    @type t :: %__MODULE__{target: target, expr: String.t()}
  end

  defmodule Transition do
    @moduledoc false
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

  defstruct version: "1.0", imports: [], places: [], init: %{}, transitions: []

  @type token :: map()
  @type t :: %__MODULE__{
          version: String.t(),
          imports: [String.t()],
          places: [Place.t()],
          init: %{String.t() => token},
          transitions: [Transition.t()]
        }

  @spec place(t, String.t()) :: Place.t() | nil
  def place(%__MODULE__{places: ps}, name), do: Enum.find(ps, &(&1.name == name))

  @spec transition(t, String.t()) :: Transition.t() | nil
  def transition(%__MODULE__{transitions: ts}, name), do: Enum.find(ts, &(&1.name == name))

  @spec place_names(t) :: [String.t()]
  def place_names(%__MODULE__{places: ps}), do: Enum.map(ps, & &1.name)
end
