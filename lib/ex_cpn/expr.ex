defmodule ExCpn.Expr do
  @moduledoc """
  Evaluates the Tcl `expr` subset used by `local` guards against a binding map.

  Supported: `$var`, `$var(field)`, numbers, `"strings"`, `( )`, unary `!` `-`,
  `* / %`, `+ -`, `< > <= >=`, `== != eq ne`, `&&`, `||`.
  Missing variables evaluate to `nil`; any comparison involving `nil` is false.
  """

  @typedoc "Parsed expression tree: `{:num, n}`, `{:str, s}`, `{:var, name, field | nil}`, or an operator node."
  @type ast :: term()

  @doc """
  Parses an expression to an AST.

      iex> ExCpn.Expr.parse("$w(age) > 300")
      {:ok, {:>, {:var, "w", "age"}, {:num, 300}}}
      iex> ExCpn.Expr.parse("1 +")
      {:error, "unexpected end of expression"}
  """
  @spec parse(String.t()) :: {:ok, ast} | {:error, String.t()}
  def parse(src) do
    with {:ok, toks} <- lex(src, []),
         {:ok, ast, []} <- expr(toks, 0) do
      {:ok, ast}
    else
      {:ok, _ast, [t | _]} -> {:error, "unexpected token #{inspect(t)}"}
      err -> err
    end
  end

  @doc """
  Evaluates a guard expression against a binding; true only when the result is truthy.

  Accepts source or a parsed AST. Source that fails to parse raises `ArgumentError`;
  `ExCpn.Validator` reports the same errors without raising.

      iex> ExCpn.Expr.truthy?("$w(age) > 300", %{"w" => %{"age" => "301"}})
      true
      iex> ExCpn.Expr.truthy?(~S<$s(state) eq "denied" || $s(state) eq "unauthenticated">, %{"s" => %{"state" => "denied"}})
      true
      iex> ExCpn.Expr.truthy?("$missing > 1", %{})
      false
  """
  @spec truthy?(String.t() | ast, map()) :: boolean
  def truthy?(src, binding) when is_binary(src) do
    case parse(src) do
      {:ok, ast} -> truthy?(ast, binding)
      {:error, msg} -> raise ArgumentError, "invalid guard expression #{inspect(src)}: #{msg}"
    end
  end

  def truthy?(ast, binding), do: eval(ast, binding) not in [nil, false, 0, "0", "", "false", "no"]

  @doc """
  Evaluates an AST to a value. Arithmetic on non-numbers and comparisons with `nil` yield `nil`.

      iex> {:ok, ast} = ExCpn.Expr.parse("(1 + 2) * $n")
      iex> ExCpn.Expr.eval(ast, %{"n" => "4"})
      12
  """
  @spec eval(ast, map()) :: term()
  def eval({:num, n}, _), do: n
  def eval({:str, s}, _), do: s
  def eval({:var, name, nil}, b), do: Map.get(b, name)

  def eval({:var, name, field}, b) do
    case Map.get(b, name) do
      %{} = m -> Map.get(m, field)
      _ -> nil
    end
  end

  def eval({:not, a}, b), do: not truthy?(a, b)

  def eval({:neg, a}, b) do
    case num(eval(a, b)) do
      n when is_number(n) -> -n
      _ -> nil
    end
  end

  def eval({:&&, a, c}, b), do: truthy?(a, b) and truthy?(c, b)
  def eval({:||, a, c}, b), do: truthy?(a, b) or truthy?(c, b)
  def eval({:eq, a, c}, b), do: str(eval(a, b)) == str(eval(c, b))
  def eval({:ne, a, c}, b), do: str(eval(a, b)) != str(eval(c, b))

  def eval({op, a, c}, b) when op in [:+, :-, :*, :/, :%, :<, :>, :<=, :>=, :==, :!=] do
    arith(op, num(eval(a, b)), num(eval(c, b)))
  end

  defp arith(_, x, y) when is_nil(x) or is_nil(y), do: nil
  defp arith(:+, x, y), do: x + y
  defp arith(:-, x, y), do: x - y
  defp arith(:*, x, y), do: x * y
  defp arith(:/, _, 0), do: nil
  defp arith(:/, x, y) when is_integer(x) and is_integer(y), do: div(x, y)
  defp arith(:/, x, y), do: x / y
  defp arith(:%, _, 0), do: nil
  defp arith(:%, x, y) when is_integer(x) and is_integer(y), do: rem(x, y)
  defp arith(:%, _, _), do: nil
  defp arith(:<, x, y), do: x < y
  defp arith(:>, x, y), do: x > y
  defp arith(:<=, x, y), do: x <= y
  defp arith(:>=, x, y), do: x >= y
  defp arith(:==, x, y), do: x == y
  defp arith(:!=, x, y), do: x != y

  defp num(n) when is_number(n), do: n
  defp num(true), do: 1
  defp num(false), do: 0

  defp num(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, ""} -> i
      _ -> float(s)
    end
  end

  defp num(_), do: nil

  defp float(s) do
    case Float.parse(s) do
      {f, ""} -> f
      _ -> nil
    end
  end

  defp str(nil), do: nil
  defp str(true), do: "1"
  defp str(false), do: "0"
  defp str(v), do: to_string(v)

  # --- lexer ---------------------------------------------------------------

  @two ~w(<= >= == != && ||)
  @one ~w{( ) + - * / % < > !}

  defp lex("", acc), do: {:ok, Enum.reverse(acc)}
  defp lex(<<c, r::binary>>, acc) when c in [?\s, ?\t, ?\n, ?\r], do: lex(r, acc)

  defp lex(<<a, b, r::binary>>, acc) when <<a, b>> in @two,
    do: lex(r, [{:op, String.to_atom(<<a, b>>)} | acc])

  defp lex(<<a, r::binary>>, acc) when <<a>> in @one,
    do: lex(r, [{:op, String.to_atom(<<a>>)} | acc])

  defp lex(<<"eq", c, r::binary>>, acc) when c in [?\s, ?\t], do: lex(r, [{:op, :eq} | acc])
  defp lex(<<"ne", c, r::binary>>, acc) when c in [?\s, ?\t], do: lex(r, [{:op, :ne} | acc])
  defp lex(<<?", r::binary>>, acc), do: lex_str(r, [], acc)

  defp lex(<<?$, r::binary>>, acc) do
    {name, r} = take(r, &ident?/1)

    case r do
      <<?(, r::binary>> ->
        {field, r} = take(r, &(&1 != ?)))

        case r do
          <<?), r::binary>> -> lex(r, [{:var, name, field} | acc])
          _ -> {:error, "unterminated array index for $#{name}"}
        end

      _ ->
        lex(r, [{:var, name, nil} | acc])
    end
  end

  defp lex(<<c, _::binary>> = s, acc) when c in ?0..?9 or c == ?. do
    {text, r} = take(s, &(&1 in ?0..?9 or &1 in [?., ?e, ?E]))

    case {Integer.parse(text), Float.parse(text)} do
      {{i, ""}, _} -> lex(r, [{:num, i} | acc])
      {_, {f, ""}} -> lex(r, [{:num, f} | acc])
      _ -> {:error, "bad number #{text}"}
    end
  end

  defp lex(<<c, _::binary>> = s, acc) when c in ?a..?z or c in ?A..?Z or c == ?_ do
    {word, r} = take(s, &ident?/1)
    lex(r, [{:str, word} | acc])
  end

  defp lex(<<c, _::binary>>, _), do: {:error, "unexpected character #{<<c>>}"}

  defp lex_str(<<>>, _, _), do: {:error, "unterminated string"}

  defp lex_str(<<?", r::binary>>, s, acc),
    do: lex(r, [{:str, s |> Enum.reverse() |> IO.iodata_to_binary()} | acc])

  defp lex_str(<<?\\, c, r::binary>>, s, acc), do: lex_str(r, [c | s], acc)
  defp lex_str(<<c, r::binary>>, s, acc), do: lex_str(r, [c | s], acc)

  defp ident?(c), do: c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in [?_, ?-, ?:]

  defp take(s, pred), do: take(s, pred, [])

  defp take(<<c, r::binary>>, pred, acc),
    do: if(pred.(c), do: take(r, pred, [c | acc]), else: {rev(acc), <<c, r::binary>>})

  defp take(<<>>, _, acc), do: {rev(acc), ""}
  defp rev(acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  # --- Pratt parser --------------------------------------------------------

  @bp %{
    ||: 1,
    &&: 2,
    ==: 3,
    !=: 3,
    eq: 3,
    ne: 3,
    <: 4,
    >: 4,
    <=: 4,
    >=: 4,
    +: 5,
    -: 5,
    *: 6,
    /: 6,
    %: 6
  }

  defp expr(toks, min_bp) do
    with {:ok, lhs, rest} <- prefix(toks), do: infix(lhs, rest, min_bp)
  end

  defp prefix([{:num, n} | r]), do: {:ok, {:num, n}, r}
  defp prefix([{:str, s} | r]), do: {:ok, {:str, s}, r}
  defp prefix([{:var, n, f} | r]), do: {:ok, {:var, n, f}, r}
  defp prefix([{:op, :!} | r]), do: with({:ok, a, r} <- expr(r, 7), do: {:ok, {:not, a}, r})
  defp prefix([{:op, :-} | r]), do: with({:ok, a, r} <- expr(r, 7), do: {:ok, {:neg, a}, r})

  defp prefix([{:op, :"("} | r]) do
    case expr(r, 0) do
      {:ok, a, [{:op, :")"} | r]} -> {:ok, a, r}
      {:ok, _, _} -> {:error, "expected )"}
      err -> err
    end
  end

  defp prefix([t | _]), do: {:error, "unexpected token #{inspect(t)}"}
  defp prefix([]), do: {:error, "unexpected end of expression"}

  defp infix(lhs, [{:op, op} | r] = toks, min_bp) do
    case @bp[op] do
      bp when is_integer(bp) and bp > min_bp ->
        with {:ok, rhs, r} <- expr(r, bp), do: infix({op, lhs, rhs}, r, min_bp)

      _ ->
        {:ok, lhs, toks}
    end
  end

  defp infix(lhs, toks, _), do: {:ok, lhs, toks}
end
