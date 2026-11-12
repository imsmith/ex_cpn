defmodule ExCpn.MixProject do
  @moduledoc false
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/imsmith/ex_cpn"

  def project do
    [
      app: :ex_cpn,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Coloured Petri Net action models: parse, encode, validate, and run .cpn.tcl nets",
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp package do
    [
      licenses: ["AGPL-3.0-only"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md", "LICENSE"],
      groups_for_modules: [
        Format: [ExCpn.Parser, ExCpn.Encoder, ExCpn.Tcl, ExCpn.Validator],
        Model: [ExCpn.Net, ExCpn.Net.Place, ExCpn.Net.Arc, ExCpn.Net.Guard, ExCpn.Net.Transition],
        Semantics: [ExCpn.Marking, ExCpn.Expr],
        Runtime: [ExCpn.Instance]
      ]
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
