defmodule ExCpn.Tcl do
  @moduledoc """
  Minimal Tcl word tokenizer: splits source into commands and commands into
  words, honouring `{braces}`, `"quotes"`, backslash escapes, `#` comments,
  `;` and newline separators. No substitution is performed; words are literal.
  """

  @type word :: String.t()
  @type command :: %{words: [word], line: pos_integer}

  @doc "Splits a script into commands with line numbers."
  @spec commands(String.t()) :: {:ok, [command]} | {:error, {pos_integer, String.t()}}
  def commands(src) do
    scan(src, 1, [], [], true)
  rescue
    e in ArgumentError -> {:error, {0, Exception.message(e)}}
  end

  @doc "Splits one Tcl list (one line or braced body) into words."
  @spec words(String.t()) :: {:ok, [word]} | {:error, {pos_integer, String.t()}}
  def words(src) do
    case commands(String.replace(src, "\n", " ")) do
      {:ok, []} -> {:ok, []}
      {:ok, [%{words: w}]} -> {:ok, w}
      {:ok, _} -> {:error, {1, "unexpected command separator in list"}}
      err -> err
    end
  end

  # scan(rest, line, current_words_rev, commands_rev, at_command_start?)
  defp scan(<<>>, _line, [], cmds, _), do: {:ok, Enum.reverse(cmds)}
  defp scan(<<>>, line, ws, cmds, _), do: {:ok, Enum.reverse([cmd(ws, line) | cmds])}

  defp scan(<<"\\\n", r::binary>>, line, ws, cmds, start), do: scan(r, line + 1, ws, cmds, start)

  defp scan(<<c, r::binary>>, line, ws, cmds, start) when c in [?\s, ?\t, ?\r],
    do: scan(r, line, ws, cmds, start)

  defp scan(<<c, r::binary>>, line, ws, cmds, _) when c in [?\n, ?;] do
    nl = if c == ?\n, do: 1, else: 0

    case ws do
      [] -> scan(r, line + nl, [], cmds, true)
      _ -> scan(r, line + nl, [], [cmd(ws, line) | cmds], true)
    end
  end

  defp scan(<<?#, r::binary>>, line, [], cmds, true) do
    {_, rest} = take_until_newline(r)
    scan(rest, line, [], cmds, true)
  end

  defp scan(src, line, ws, cmds, _) do
    case word(src, line) do
      {:ok, w, rest, nls} -> scan(rest, line + nls, [w | ws], cmds, false)
      {:error, msg} -> {:error, {line, msg}}
    end
  end

  defp cmd(ws, line), do: %{words: Enum.reverse(ws), line: line}

  defp take_until_newline(s) do
    case :binary.split(s, "\n") do
      [a, b] -> {a, "\n" <> b}
      [a] -> {a, ""}
    end
  end

  defp word(<<?{, r::binary>>, _line), do: braced(r, 1, [], 0)
  defp word(<<?", r::binary>>, _line), do: quoted(r, [], 0)
  defp word(src, _line), do: bare(src, [])

  defp braced(<<>>, _, _, _), do: {:error, "unterminated brace"}
  defp braced(<<?}, r::binary>>, 1, acc, nls), do: {:ok, rev(acc), r, nls}
  defp braced(<<?}, r::binary>>, d, acc, nls), do: braced(r, d - 1, [?} | acc], nls)
  defp braced(<<?{, r::binary>>, d, acc, nls), do: braced(r, d + 1, [?{ | acc], nls)

  defp braced(<<?\\, c, r::binary>>, d, acc, nls),
    do: braced(r, d, [c, ?\\ | acc], nls + if(c == ?\n, do: 1, else: 0))

  defp braced(<<?\n, r::binary>>, d, acc, nls), do: braced(r, d, [?\n | acc], nls + 1)
  defp braced(<<c, r::binary>>, d, acc, nls), do: braced(r, d, [c | acc], nls)

  defp quoted(<<>>, _, _), do: {:error, "unterminated quote"}
  defp quoted(<<?", r::binary>>, acc, nls), do: {:ok, rev(acc), r, nls}
  defp quoted(<<?\\, c, r::binary>>, acc, nls), do: quoted(r, [unescape(c) | acc], nls)
  defp quoted(<<?\n, r::binary>>, acc, nls), do: quoted(r, [?\n | acc], nls + 1)
  defp quoted(<<c, r::binary>>, acc, nls), do: quoted(r, [c | acc], nls)

  defp bare(<<>>, acc), do: {:ok, rev(acc), "", 0}

  defp bare(<<c, _::binary>> = r, acc) when c in [?\s, ?\t, ?\r, ?\n, ?;],
    do: {:ok, rev(acc), r, 0}

  defp bare(<<?\\, c, r::binary>>, acc), do: bare(r, [unescape(c) | acc])
  defp bare(<<c, r::binary>>, acc), do: bare(r, [c | acc])

  defp unescape(?n), do: ?\n
  defp unescape(?t), do: ?\t
  defp unescape(c), do: c

  defp rev(acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()
end
