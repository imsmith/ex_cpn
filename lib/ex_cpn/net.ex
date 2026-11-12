defmodule ExCpn.Net do
  @moduledoc """
  A parsed Coloured Petri Net.

  `places` and `transitions` keep source order, which `ExCpn.Marking` uses to
  break ties between equal-priority transitions. `init` maps a place name to
  its single seed token.
  """

  defmodule Place do
    @moduledoc "A typed place. `type` is `module:node`, naming a YANG container or grouping."
    @enforce_keys [:name, :type]
    defstruct [:name, :type, :line]
    @type t :: %__MODULE__{name: String.t(), type: String.t(), line: pos_integer | nil}
  end

  defmodule Arc do
    @moduledoc """
    One `in` or `out` entry of a transition.

    On an `in` arc, `expr` is the variable the consumed token is bound to.
    On an `out` arc, `expr` is `$var` to forward a bound token or a literal dict.
    """
    @enforce_keys [:place, :expr]
    defstruct [:place, :expr]
    @type t :: %__MODULE__{place: String.t(), expr: String.t()}
  end

  defmodule Guard do
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

  defmodule Transition do
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

  defstruct version: "1.0", imports: [], places: [], init: %{}, transitions: []

  @typedoc "A token is a string-keyed map. `init p {}` seeds an empty one."
  @type token :: map()
  @type t :: %__MODULE__{
          version: String.t(),
          imports: [String.t()],
          places: [Place.t()],
          init: %{String.t() => token},
          transitions: [Transition.t()]
        }

  @doc """
  Looks up a place by name.

      iex> {:ok, net} = ExCpn.parse("cpn-spec 1.0\\nplace a -type m:n\\n")
      iex> ExCpn.Net.place(net, "a").type
      "m:n"
      iex> ExCpn.Net.place(net, "b")
      nil
  """
  @spec place(t, String.t()) :: Place.t() | nil
  def place(%__MODULE__{places: ps}, name), do: Enum.find(ps, &(&1.name == name))

  @doc """
  Looks up a transition by name.

      iex> {:ok, net} = ExCpn.parse("cpn-spec 1.0\\ntransition t {\\n  priority 2\\n}\\n")
      iex> ExCpn.Net.transition(net, "t").priority
      2
  """
  @spec transition(t, String.t()) :: Transition.t() | nil
  def transition(%__MODULE__{transitions: ts}, name), do: Enum.find(ts, &(&1.name == name))

  @doc """
  Place names in source order.

      iex> {:ok, net} = ExCpn.parse("cpn-spec 1.0\\nplace b -type m:n\\nplace a -type m:n\\n")
      iex> ExCpn.Net.place_names(net)
      ["b", "a"]
  """
  @spec place_names(t) :: [String.t()]
  def place_names(%__MODULE__{places: ps}), do: Enum.map(ps, & &1.name)
end
