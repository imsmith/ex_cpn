defmodule ExCpn.Parser do
  @moduledoc "Builds an `ExCpn.Net` from `.cpn.tcl` source."

  alias ExCpn.Net
  alias ExCpn.Net.{Arc, Guard, Place, Transition}
  alias ExCpn.Tcl

  @guard_targets %{"local" => :local, "shell" => :shell, "http" => :http, "retry" => :retry}

  @doc """
  Parses source to a net. See `ExCpn.parse/1`.

      iex> {:ok, net} = ExCpn.Parser.parse("cpn-spec 1.0\\nyang import a b\\n")
      iex> net.imports
      ["a", "b"]
  """
  @spec parse(String.t()) :: {:ok, Net.t()} | {:error, {pos_integer, String.t()}}
  def parse(src) do
    with {:ok, cmds} <- Tcl.commands(src),
         {:ok, net} <- reduce(cmds, %Net{}, &top/2) do
      {:ok,
       %{
         net
         | places: Enum.reverse(net.places),
           transitions: Enum.reverse(net.transitions),
           imports: Enum.reverse(net.imports)
       }}
    end
  end

  defp reduce(cmds, acc, fun) do
    Enum.reduce_while(cmds, {:ok, acc}, fn cmd, {:ok, acc} ->
      case fun.(cmd, acc) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, msg} -> {:halt, {:error, {cmd.line, msg}}}
      end
    end)
  end

  defp top(%{words: ["cpn-spec", v]}, net), do: {:ok, %{net | version: v}}

  defp top(%{words: ["yang", "import" | mods]}, net),
    do: {:ok, %{net | imports: Enum.reverse(mods) ++ net.imports}}

  defp top(%{words: ["yang", sub | _]}, _), do: {:error, "unknown yang subcommand: #{sub}"}

  defp top(%{words: ["place", name | opts], line: line}, net) do
    case opts do
      ["-type", type] ->
        {:ok, %{net | places: [%Place{name: name, type: type, line: line} | net.places]}}

      _ ->
        {:error, "place '#{name}' missing -type"}
    end
  end

  defp top(%{words: ["init", place, value]}, net) do
    with {:ok, token} <- token(value), do: {:ok, %{net | init: Map.put(net.init, place, token)}}
  end

  defp top(%{words: ["transition", name, body], line: line}, net) do
    with {:ok, cmds} <- Tcl.commands(body),
         {:ok, t} <- reduce(cmds, %Transition{name: name, line: line}, &tbody/2) do
      {:ok, %{net | transitions: [t | net.transitions]}}
    else
      {:error, {l, msg}} -> {:error, "transition '#{name}' line #{l}: #{msg}"}
      err -> err
    end
  end

  defp top(%{words: [w | _]}, _), do: {:error, "unknown command: #{w}"}

  defp tbody(%{words: ["in" | pairs]}, t),
    do: with({:ok, arcs} <- arcs(pairs), do: {:ok, %{t | in: arcs}})

  defp tbody(%{words: ["out" | pairs]}, t),
    do: with({:ok, arcs} <- arcs(pairs), do: {:ok, %{t | out: arcs}})

  defp tbody(%{words: ["label", s]}, t), do: {:ok, %{t | label: s}}

  defp tbody(%{words: ["priority", n]}, t) do
    case Integer.parse(n) do
      {i, ""} -> {:ok, %{t | priority: i}}
      _ -> {:error, "priority must be an integer, got '#{n}'"}
    end
  end

  defp tbody(%{words: ["guard", spec]}, t) do
    with {:ok, [target, expr]} <- guard_words(spec),
         {:ok, target} <-
           Map.fetch(@guard_targets, target)
           |> ok_or("guard target must be one of: local shell http retry (got '#{target}')") do
      {:ok, %{t | guard: %Guard{target: target, expr: expr}}}
    end
  end

  defp tbody(%{words: [w | _]}, _), do: {:error, "unknown transition subcommand: #{w}"}

  defp guard_words(spec) do
    case Tcl.words(spec) do
      {:ok, [_, _] = w} -> {:ok, w}
      {:ok, _} -> {:error, "guard requires {target expression}, got: #{spec}"}
      {:error, {_, m}} -> {:error, m}
    end
  end

  defp arcs(pairs) do
    Enum.reduce_while(pairs, {:ok, []}, fn pair, {:ok, acc} ->
      case Tcl.words(pair) do
        {:ok, [place, expr]} -> {:cont, {:ok, [%Arc{place: place, expr: expr} | acc]}}
        _ -> {:halt, {:error, "arc must be {place var}, got: #{pair}"}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  @doc """
  Parses a Tcl dict literal (`{}` or `{k v k v}`) into a token map.

      iex> ExCpn.Parser.token("id 7 kind {a b}")
      {:ok, %{"id" => "7", "kind" => "a b"}}
      iex> ExCpn.Parser.token("odd")
      {:error, "token must have an even number of elements: odd"}
  """
  @spec token(String.t()) :: {:ok, map()} | {:error, String.t()}
  def token(value) do
    case Tcl.words(value) do
      {:ok, ws} when rem(length(ws), 2) == 0 ->
        {:ok, ws |> Enum.chunk_every(2) |> Map.new(fn [k, v] -> {k, v} end)}

      {:ok, _} ->
        {:error, "token must have an even number of elements: #{value}"}

      {:error, {_, m}} ->
        {:error, m}
    end
  end

  defp ok_or({:ok, v}, _), do: {:ok, v}
  defp ok_or(:error, msg), do: {:error, msg}
end
