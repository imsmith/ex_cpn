defmodule ExCpn do
  @moduledoc """
  Coloured Petri Net action models in the `.cpn.tcl` format.

  A net is typed places, transitions with `in`/`out` arcs, optional guards,
  priorities, and labels. Topology is implicit in which places each transition
  names. See the README for the full grammar.

      iex> {:ok, net} = ExCpn.parse(\"\"\"
      ...> cpn-spec 1.0
      ...> place todo -type m:item
      ...> place done -type m:item
      ...> init todo {}
      ...> transition finish {
      ...>   in  {todo t}
      ...>   out {done $t}
      ...> }
      ...> \"\"\")
      iex> {:ok, _} = ExCpn.validate(net)
      iex> {marking, fired} = ExCpn.Marking.run(net, ExCpn.Marking.initial(net))
      iex> Enum.map(fired, & &1.name)
      ["finish"]
      iex> marking
      %{"todo" => [], "done" => [%{}]}

  Modules:

    * `ExCpn.Parser` / `ExCpn.Encoder` - source to `ExCpn.Net` and back
    * `ExCpn.Validator` - structural checks
    * `ExCpn.Marking` - pure token-game semantics
    * `ExCpn.Instance` - a running net as a `gen_statem`
    * `ExCpn.Expr` - the Tcl `expr` subset used by `local` guards
  """

  alias ExCpn.{Encoder, Net, Parser, Validator}

  @doc """
  Parses `.cpn.tcl` source into an `ExCpn.Net`.

  Errors carry the source line.

      iex> {:ok, net} = ExCpn.parse("cpn-spec 1.0\\nplace a -type m:n\\n")
      iex> net.version
      "1.0"
      iex> ExCpn.parse("cpn-spec 1.0\\nplace a\\n")
      {:error, {2, "place 'a' missing -type"}}
  """
  @spec parse(String.t()) :: {:ok, Net.t()} | {:error, {pos_integer, String.t()}}
  defdelegate parse(source), to: Parser

  @doc "Reads and parses a `.cpn.tcl` file. File errors come back as `{:error, posix}`."
  @spec parse_file(Path.t()) :: {:ok, Net.t()} | {:error, term()}
  def parse_file(path) do
    with {:ok, src} <- File.read(path), do: parse(src)
  end

  @doc """
  Renders a net back to canonical source. Comments are not preserved.

      iex> {:ok, net} = ExCpn.parse("cpn-spec 1.0\\nplace a -type m:n\\ntransition t {\\n  in {a x}\\n}\\n")
      iex> ExCpn.encode(net)
      "cpn-spec 1.0\\n\\nplace a -type m:n\\n\\ntransition t {\\n  in    {a x}\\n}\\n"
  """
  @spec encode(Net.t()) :: String.t()
  defdelegate encode(net), to: Encoder

  @doc """
  Checks a net for structural problems: unknown places, bad guards, duplicates.

      iex> {:ok, net} = ExCpn.parse("cpn-spec 1.0\\ntransition t {\\n  in {ghost x}\\n}\\n")
      iex> ExCpn.validate(net)
      {:error, [{:error, "transition 't' in references unknown place 'ghost'"}]}
  """
  @spec validate(Net.t()) :: {:ok, Net.t()} | {:error, [Validator.problem()]}
  defdelegate validate(net), to: Validator
end
