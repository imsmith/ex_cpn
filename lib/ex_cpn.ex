defmodule ExCpn do
  @moduledoc """
  Coloured Petri Net action models in the `.cpn.tcl` format.

      {:ok, net} = ExCpn.parse_file("deploy.cpn.tcl")
      {:ok, net} = ExCpn.validate(net)
      marking = ExCpn.Marking.initial(net)
      {marking, fired} = ExCpn.Marking.run(net, marking)
      ExCpn.encode(net)
  """

  alias ExCpn.{Encoder, Net, Parser, Validator}

  @spec parse(String.t()) :: {:ok, Net.t()} | {:error, {pos_integer, String.t()}}
  defdelegate parse(source), to: Parser

  @spec parse_file(Path.t()) :: {:ok, Net.t()} | {:error, term()}
  def parse_file(path) do
    with {:ok, src} <- File.read(path), do: parse(src)
  end

  @spec encode(Net.t()) :: String.t()
  defdelegate encode(net), to: Encoder

  @spec validate(Net.t()) :: {:ok, Net.t()} | {:error, [Validator.problem()]}
  defdelegate validate(net), to: Validator
end
