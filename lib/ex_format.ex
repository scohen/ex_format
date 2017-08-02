import Kernel, except: [to_string: 1]

defmodule ExFormat do
  @typedoc "Abstract Syntax Tree (AST)"
  @type t :: expr | {t, t} | atom | number | binary | pid | fun | [t]
  @type expr :: {expr | atom, Keyword.t, atom | [t]}

  @binary_ops [:===, :!==,
    :==, :!=, :<=, :>=,
    :&&, :||, :<>, :++, :--, :\\, :::, :<-, :.., :|>, :=~,
    :<, :>, :->,
    :+, :-, :*, :/, :=, :|, :.,
    :and, :or, :when, :in,
    :~>>, :<<~, :~>, :<~, :<~>, :<|>,
    :<<<, :>>>, :|||, :&&&, :^^^, :~~~]

  @doc false
  defmacro binary_ops, do: @binary_ops

  @unary_ops [:!, :@, :^, :not, :+, :-, :~~~, :&]

  @doc false
  defmacro unary_ops, do: @unary_ops

  @spec binary_op_props(atom) :: {:left | :right, precedence :: integer}
  defp binary_op_props(o) do
    case o do
      o when o in [:<-, :\\]                  -> {:left,  40}
      :when                                   -> {:right, 50}
      :::                                     -> {:right, 60}
      :|                                      -> {:right, 70}
      :=                                      -> {:right, 90}
      o when o in [:||, :|||, :or]            -> {:left, 130}
      o when o in [:&&, :&&&, :and]           -> {:left, 140}
      o when o in [:==, :!=, :=~, :===, :!==] -> {:left, 150}
      o when o in [:<, :<=, :>=, :>]          -> {:left, 160}
      o when o in [:|>, :<<<, :>>>, :<~, :~>,
                :<<~, :~>>, :<~>, :<|>, :^^^] -> {:left, 170}
      :in                                     -> {:left, 180}
      o when o in [:++, :--, :.., :<>]        -> {:right, 200}
      o when o in [:+, :-]                    -> {:left, 210}
      o when o in [:*, :/]                    -> {:left, 220}
      :.                                      -> {:left, 310}
    end
  end

  @split_threshold 80

  @ampersand_operators [:&, :&&, :&&&]

  @parenless_calls [
    :use,
    :import,
    :not,
    :alias,
    :try,
    :raise,
    :reraise,
    :defexception,
    :require
  ]

  def format_string(content) do
    content
    |> prepare_data()
    |> preprocess()
    |> format()
    |> postprocess()
  end

  defp prepare_data(file_content) do
    lines = String.split(file_content, "\n")
    Agent.start_link(fn -> %{} end, name: :lines)
    Agent.start_link(fn -> %{} end, name: :inline_comments)
    state = %{
      parenless_calls: MapSet.new(@parenless_calls),
      parenless_zero_arity?: false,
    }
    for {line, i} <- Enum.with_index(lines) do
      update_line(i+1, String.trim(line))
      inline_comment_token = extract_inline_comment_token(line)

      if inline_comment_token do
        {_, {_, start_col, _}, inline_comment} = inline_comment_token
        fingerprint = line
        |> String.slice(0..start_col)
        |> get_line_fingerprint
        if fingerprint != "", do: update_inline_comments(fingerprint, inline_comment)
      end
    end
    {_, ast} = Code.string_to_quoted(file_content, wrap_literals_in_blocks: true)
    {ast, state}
  end

  defp preprocess({ast, state}) do
    {ast, {_, state}} =
      Macro.prewalk(ast, {[line: 1], state}, fn ast, {prev_meta, state} ->
        {ast, state} = handle_zero_arity_fun(ast) |> handle_parenless_call(state)
        handle_accumulator(ast, prev_meta, state)
      end)
    {ast, state}
  end

  defp format({ast, state}) do
    fun = fn ast, string ->
      case ast do
        {_, meta, _} ->
          Enum.join [
            meta[:prefix_comments],
            meta[:prefix_newline],
            string, meta[:suffix_comments]
          ]
        _ ->
          string
      end
    end
    to_string(ast, fun, state)
  end

  defp postprocess(formatted) do
    formatted_lines = String.split(formatted, "\n")
    formatted = Enum.map_join(formatted_lines, "\n", fn line ->
      line = String.trim_trailing line
      fingerprint = get_line_fingerprint line
      line <> get_inline_comments(fingerprint)
    end)
    formatted <> "\n"
  end

  defp handle_accumulator({sym, curr_meta, args} = ast, prev_meta, state) do
    if curr_meta != [] and prev_meta != [] do
      new_meta = update_meta(curr_meta, prev_meta)
      {{sym, new_meta, args}, {new_meta, state}}
    else
      {ast, {prev_meta, state}}
    end
  end

  defp handle_accumulator(ast, prev_meta, state) do
    {ast, {prev_meta, state}}
  end

  defp extract_inline_comment_token(line) do
    {_, _, _, tokens} = :elixir_tokenizer.tokenize(to_charlist(line), 0,
      preserve_comments: true, check_terminators: false)
    token = tokens
    |> Stream.with_index
    |> Stream.filter(fn {token, i} ->
      elem(token, 0) == :comment and i > 0 and get_lineno(Enum.at(tokens, i-1)) == get_lineno(token)
    end)
    |> Enum.to_list
    |> List.first
    if token, do: elem(token, 0), else: token
  end

  defp get_line_fingerprint(line) do
    # TODO: be less aggressive with removing non-word chars here
    Enum.join String.split(line, ~r/\W+/)
  end

  defp get_lineno(nil), do: nil
  defp get_lineno(token) do
    {lineno, _, _} = elem(token, 1)
    lineno
  end

  @defs [:def, :defp, :defmacro, :defmacrop, :defdelegate]
  defp handle_zero_arity_fun({sym, meta1, [{fun, meta2, nil} | rest]}) when sym in @defs do
    {sym, meta1, [{fun, meta2, []} | rest]}
  end
  defp handle_zero_arity_fun({:|>, meta1, [left, {fun, meta2, nil}]}) do
    {:|>, meta1, [left, {fun, meta2, []}]}
  end
  defp handle_zero_arity_fun(ast), do: ast

  defp handle_parenless_call({sym, _, list} = ast, state) when is_list(list) do
    {_, last} = :elixir_utils.split_last(list)
    state =
      if Keyword.keyword?(last) and Keyword.has_key?(last, :do) do
        %{state | parenless_calls: MapSet.put(state.parenless_calls, sym)}
      else
        state
      end
    {ast, state}
  end
  defp handle_parenless_call(ast, state), do: {ast, state}

  defp update_meta(curr_meta) do
    curr_lineno = curr_meta[:line]
    # TODO: is suffix_newline necessary?
    [{:suffix_comments, get_suffix_comments(curr_lineno+1)}] ++ curr_meta
  end
  defp update_meta(curr_meta, prev_meta) do
    curr_lineno = curr_meta[:line]
    prev_lineno = prev_meta[:line]

    [{:prev, prev_lineno}] ++
    [{:prefix_comments, get_prefix_comments(curr_lineno-1, prev_lineno)}] ++
    [{:prefix_newline, get_prefix_newline(curr_lineno-1, prev_lineno)}] ++ curr_meta
  end

  defp get_line(k), do: Agent.get(:lines, fn map -> Map.get(map, k) end)
  defp update_line(k, v), do: Agent.update(:lines, fn map -> Map.put(map, k, v) end)
  defp clear_line(k), do: Agent.update(:lines, fn map -> Map.put(map, k, nil) end)

  def parenless_zero_arity?(args, state), do: state.parenless_zero_arity? and args == []

  defp parenless_call?(call, args, state) when is_atom(call) do
    MapSet.member?(state.parenless_calls, call) or
    parenless_zero_arity?(args, state)
  end
  defp parenless_call?({:., _, [left, _right]}, args, state) do
    case left do
      {:__aliases__, _, _} ->
        parenless_zero_arity?(args, state)
      {:__block__, _, [expr]} when is_atom(expr) ->
        parenless_zero_arity?(args, state)
      _ ->
        args == []
    end
  end
  defp parenless_call?(_, args, state), do: parenless_zero_arity?(args, state)

  defp update_inline_comments(k, v) do
    Agent.update(:inline_comments, fn map ->
      if Map.has_key?(map, k) do
        val = Map.get(map, k)
        Map.put(map, k, val ++ [v])
      else
        Map.put(map, k, [v])
      end
    end)
  end
  defp get_inline_comments(k) do
    vals = Agent.get(:inline_comments, fn map -> Map.get(map, k) end)
    case vals do
      nil ->
        ""
      [] ->
        ""
      [v | rest] ->
        Agent.update(:inline_comments, fn map -> Map.put(map, k, rest) end)
        " " <> String.Chars.to_string(v)
    end
  end

  defp get_prefix_newline(curr, prev \\ 0) do
    if curr >= prev and get_line(curr) == "", do: "\n", else: ""
  end

  defp get_prefix_comments(curr, prev) when curr < prev, do: ""
  defp get_prefix_comments(curr, prev) do
    case get_line(curr) do
      "#" <> comment ->
        comment = get_prefix_newline(curr-1, prev) <> "#" <> comment <> "\n"
        clear_line(curr) # clear current comment to avoid duplicates
        get_prefix_comments(curr-1, prev) <> comment
      "" ->
        get_prefix_comments(curr-1, prev)
      _ ->
        ""
    end
  end

  defp get_suffix_comments(curr) do
    case get_line(curr) do
      "#" <> comment ->
        comment = "\n" <> get_prefix_newline(curr-1) <> "#" <> comment
        clear_line(curr)
        comment <> get_suffix_comments(curr+1)
      "" ->
        get_suffix_comments(curr+1)
      _ ->
        ""
    end
  end

  defp has_suffix_comments(curr) do
    case get_line(curr) do
      "#" <> _ -> true
      "" -> has_suffix_comments(curr+1)
      _ -> false
    end
  end

  defp multiline?(ast, state) do
    case ast do
      {:__block__, meta, [_expr]} ->
        format({ast, state}) =~ "\n" or
        (meta != [] and
        (has_suffix_comments(meta[:line]+1) or
         meta[:line] != meta[:prev]))
      {:__block__, _, _} ->
        true
      {_, meta, _} ->
        meta != [] and meta[:line] > meta[:prev]
      _ ->
        true
    end
  end

  defp get_first_token(nil), do: ""
  defp get_first_token(line) do
    line
    |> String.trim_leading
    |> String.split
    |> List.first
  end

  defp get_meta({_, meta, _}) do
    if Keyword.keyword?(meta), do: meta, else: []
  end
  defp get_meta(_), do: []

  defp on_same_line?(args, tuple, state)
       when is_list(args) and is_tuple(tuple) do
    arg = List.first args
    {arg_meta, tuple_meta} = {get_meta(arg), get_meta(tuple)}
    cond do
      arg_meta != [] and tuple_meta != [] ->
        arg_meta[:line] == tuple_meta[:line]
      true ->
        tuple_string = format({tuple, state})
        not (tuple_string =~ "\n") and fits?(tuple_string)
    end
  end

  defp assign_on_next_line?(ast) do
    case ast do
      {:%, _, [_structname, _map]} ->
        false
       {:%{}, _, _} ->
        false
      {:__block__, _, [expr]} when is_list(expr) or is_tuple(expr) ->
        false
      _ ->
        true
    end
  end

  defp parenless_capture?({atom, _, _})
       when is_atom(atom) and
       atom not in unquote(@unary_ops) and
       atom not in unquote(@binary_ops) do
    true
  end
  defp parenless_capture?({{:., _, args}, _, _}) do
    {sym, _, _} = List.first(args)
    sym not in @ampersand_operators
  end
  defp parenless_capture?({:__block__, _, [expr]})
       when is_list(expr) or is_tuple(expr) do
    true
  end
  defp parenless_capture?(_), do: false

  @doc """
  Converts the given expression to a binary.
  The given `fun` is called for every node in the AST with two arguments: the
  AST of the node being printed and the string representation of that same
  node. The return value of this function is used as the final string
  representation for that AST node.
  ## Examples
      iex> Macro.to_string(quote(do: foo.bar(1, 2, 3)))
      "foo.bar(1, 2, 3)"
      iex> Macro.to_string(quote(do: 1 + 2), fn
      ...>   1, _string -> "one"
      ...>   2, _string -> "two"
      ...>   _ast, string -> string
      ...> end)
      "one + two"
  """
  @spec to_string(Macro.t) :: String.t
  @spec to_string(Macro.t, (Macro.t, String.t -> String.t), %{}) :: String.t
  def to_string(tree, fun \\ fn(_ast, string) -> string end, state \\ %{})

  # Variables
  def to_string({var, _, atom} = ast, fun, _state) when is_atom(atom) do
    fun.(ast, Atom.to_string(var))
  end

  # Aliases
  def to_string({:__aliases__, _, refs} = ast, fun, state) do
    fun.(ast, Enum.map_join(refs, ".", &call_to_string(&1, fun, state)))
  end

  # Blocks
  def to_string({:__block__, meta, [expr]} = ast, fun, state) do
    if Keyword.has_key?(meta, :format) do
      format_literal(ast, fun)
    else
      fun.(ast, to_string(expr, fun, state))
    end
  end

  def to_string({:__block__, _, _} = ast, fun, state) do
    fun.(ast, block_to_string(ast, fun, state))
  end

  # Bits containers
  def to_string({:<<>>, _, parts} = ast, fun, state) do
    if interpolated?(ast) do
      fun.(ast, interpolate(ast, fun, state))
    else
      result = Enum.map_join(parts, ", ", fn(part) ->
        str = bitpart_to_string(part, fun, state)
        if :binary.first(str) == ?< or :binary.last(str) == ?> do
          "(" <> str <> ")"
        else
          str
        end
      end)
      fun.(ast, "<<" <> result <> ">>")
    end
  end

  # Tuple containers
  def to_string({:{}, _, args} = ast, fun, state) do
    tuple = "{" <> tuple_to_string(args, fun, state) <> "}"
    fun.(ast, tuple)
  end

  # Map containers
  def to_string({:%{}, _, args} = ast, fun, state) do
    map = "%{" <> map_to_string(args, fun, state) <> "}"
    fun.(ast, map)
  end

  def to_string({:%, _, [structname, map]} = ast, fun, state) do
    {:%{}, _, args} = map
    struct = "%" <> to_string(structname, fun, state) <> "{" <> map_to_string(args, fun, state) <> "}"
    fun.(ast, struct)
  end

  # Fn keyword
  def to_string({:fn, _, [{:->, _, [args, tuple]}] = arrow} = ast, fun, state) do
    if not is_tuple(tuple) or (on_same_line?(args, tuple, state)) do
      fun.(ast, "fn " <> arrow_to_string(arrow, fun, state) <> " end")
    else
      fun.(ast, "fn " <> block_to_string(arrow, fun, state) <> "\nend")
    end
  end

  def to_string({:fn, _, block} = ast, fun, state) do
    block = adjust_new_lines block_to_string(block, fun, state), "\n  "
    fun.(ast, "fn\n  " <> block <> "\nend")
  end

  # Ranges
  def to_string({:.., _, args} = ast, fun, state) do
    range = Enum.map_join(args, "..", &to_string(&1, fun, state))
    fun.(ast, range)
  end

  # left -> right
  def to_string([{:->, _, _} | _] = ast, fun, state) do
    fun.(ast, "(" <> arrow_to_string(ast, fun, true, state) <> ")")
  end

  # left when right
  def to_string({:when, ctx, [left, right]} = ast, fun, state) do
    right =
      if right != [] and Keyword.keyword?(right) do
        kw_list_to_string(right, fun, state)
      else
        fun.(right, op_to_string(right, fun, :when, :right, state))
      end

    {padding, newline} =
      if multiline?(ast, state) do
        token = get_first_token(get_line ctx[:prev])
        {Enum.join(for _ <- 0..String.length(token), do: " "), "\n"}
      else
        {" ", ""}
      end
    op_to_string(left, fun, :when, :left, state) <> newline <> fun.(ast, "#{padding}when " <> right)
  end

  # Multiline-able binary ops
  def to_string({op, _, [left, right]} = ast, fun, state) when op in [:<>, :++, :and, :or] do
    {left_meta, right_meta} ={get_meta(left), get_meta(right)}
    {left_string, right_string} = {
      op_to_string(left, fun, op, :left, state),
      op_to_string(right, fun, op, :right, state)
    }
    string = fun.(ast, left_string <> " #{op} " <> right_string)

    bin_op = cond do
      left_meta == [] or right_meta == [] -> " #{op} "
      left_meta[:line] != right_meta[:line] -> " #{op}\n"
      not fits?(string) -> " #{op}\n"
      true -> " #{op} "
    end
    fun.(ast, left_string <> bin_op <> right_string)
  end

  # Pipeline op
  def to_string({:|> = op, _, [left, right]} = ast, fun, state) do
    {left_meta, right_meta} ={get_meta(left), get_meta(right)}
    {left_string, right_string} = {
      op_to_string(left, fun, op, :left, state),
      op_to_string(right, fun, op, :right, state)
    }
    string = fun.(ast, left_string <> " #{op} " <> right_string)

    pipeline_op = cond do
      left_meta == [] or right_meta == [] -> " #{op} "
      left_meta[:line] != right_meta[:line] -> "\n#{op} "
      not fits?(string) -> "\n#{op} "
      true -> " #{op} "
    end
    fun.(ast, left_string <> pipeline_op <> right_string)
  end

  # Assignment op
  def to_string({:= = op, _, [left, right]} = ast, fun, state) do
    left_op_string = op_to_string(left, fun, op, :left, state)
    right_op_string = op_to_string(right, fun, op, :right, state)
    if assign_on_next_line?(right) and right_op_string =~ "\n" do
      fun.(ast, left_op_string <> adjust_new_lines(" #{op}\n" <> right_op_string, "\n  "))
    else
      fun.(ast, left_op_string <> " #{op} " <> right_op_string)
    end
  end

  # Spec op
  def to_string({::: = op, _, [left, right]} = ast, fun, state) do
    state = %{state | parenless_zero_arity?: true}
    left = op_to_string(left, fun, op, :left, state)
    right = op_to_string(right, fun, op, :right, state)
    fun.(ast, left <> " #{op} " <> right)
  end

  # Binary ops
  def to_string({op, _, [left, right]} = ast, fun, state) when op in unquote(@binary_ops) do
    fun.(ast, op_to_string(left, fun, op, :left, state) <> " #{op} " <> op_to_string(right, fun, op, :right, state))
  end

  # Splat when
  def to_string({:when, _, args} = ast, fun, state) do
    {left, right} = :elixir_utils.split_last(args)
    fun.(ast, "(" <> Enum.map_join(left, ", ", &to_string(&1, fun, state)) <> ") when " <> to_string(right, fun, state))
  end

  # Capture
  def to_string({:&, _, [{:/, _, [{name, _, ctx}, arity]}]} = ast, fun, state)
      when is_atom(name) and is_atom(ctx) do
    if name in @ampersand_operators do
      fun.(ast, "&(" <> Atom.to_string(name) <> "/" <> to_string(arity, fun, state) <> ")")
    else
      fun.(ast, "&" <> Atom.to_string(name) <> "/" <> to_string(arity, fun, state))
    end
  end

  def to_string({:&, _, [{:/, _, [{{:., _, [mod, name]}, _, []}, arity]}]} = ast, fun, state)
      when is_atom(name) do
    fun.(ast, "&" <> to_string(mod, fun, state) <> "." <> Atom.to_string(name) <> "/" <> to_string(arity, fun, state))
  end

  def to_string({:&, _, [arg]} = ast, fun, state) when not is_integer(arg) do
    if parenless_capture?(arg) do
      fun.(ast, "&" <> to_string(arg, fun, state))
    else
      fun.(ast, "&(" <> to_string(arg, fun, state) <> ")")
    end
  end

  # Unary ops
  def to_string({unary, _, [{binary, _, [_, _]} = arg]} = ast, fun, state)
      when unary in unquote(@unary_ops) and binary in unquote(@binary_ops) do
    fun.(ast, Atom.to_string(unary) <> "(" <> to_string(arg, fun, state) <> ")")
  end

  def to_string({:not, _, [arg]} = ast, fun, state)  do
    fun.(ast, "not " <> to_string(arg, fun, state))
  end

  def to_string({:@ = op, _, [{target, _, _} = arg]} = ast, fun, state) do
    state = %{state | parenless_calls: MapSet.put(state.parenless_calls, target)}
    fun.(ast, Atom.to_string(op) <> to_string(arg, fun, state))
  end

  def to_string({op, _, [arg]} = ast, fun, state) when op in unquote(@unary_ops) do
    fun.(ast, Atom.to_string(op) <> to_string(arg, fun, state))
  end

  # Access
  def to_string({{:., _, [Access, :get]}, _, [{op, _, _} = left, right]} = ast, fun, state)
      when op in unquote(@binary_ops) do
    fun.(ast, "(" <> to_string(left, fun, state) <> ")" <> to_string([right], fun, state))
  end

  def to_string({{:., _, [Access, :get]}, _, [left, right]} = ast, fun, state) do
    fun.(ast, to_string(left, fun, state) <> to_string([right], fun, state))
  end

  # Interpolated charlist heredoc
  def to_string({{:., _, [String, :to_charlist]}, _, args} = ast, fun, state) when is_list(args) do
    fun.(ast, args_to_string(args, fun, state))
  end

  # foo.{bar, baz}
  def to_string({{:., _, [left, :{}]}, _, args} = ast, fun, state) do
    tupleized = {:{}, [], args}
    fun.(ast, to_string(left, fun, state) <> "." <> to_string(tupleized, fun, state))
  end

  # All other calls
  def to_string({target, _, args} = ast, fun, state) when is_list(args) do
    if sigil = sigil_call(ast, fun, state) do
      sigil
    else
      {list, last} = :elixir_utils.split_last(args)
      fun.(ast, case kw_blocks?(last) do
        true  -> call_to_string_with_args(target, list, fun, state) <> kw_blocks_to_string(last, fun, list, state)
        false -> call_to_string_with_args(target, args, fun, state)
      end)
    end
  end

  # Two-element tuples
  def to_string({left, right}, fun, state) do
    to_string({:{}, [], [left, right]}, fun, state)
  end

  # Lists
  def to_string(list, fun, state) when is_list(list) do
    fun.(list, cond do
      list == [] ->
        "[]"
      :io_lib.printable_list(list) ->
        {escaped, _} = Inspect.BitString.escape(IO.chardata_to_string(list), ?')
        IO.iodata_to_binary [?', escaped, ?']
      Inspect.List.keyword?(list) ->
        "[" <> kw_list_to_string(list, fun, state) <> "]"
      true ->
        "[" <> list_to_string(list, fun, state) <> "]"
    end)
  end

  # All other structures
  def to_string(other, fun, _state) do
    fun.(other, inspect(other, []))
  end

  defp bitpart_to_string({:::, _, [left, right]} = ast, fun, state) do
    result =
      op_to_string(left, fun, :::, :left, state) <>
      "::" <>
      bitmods_to_string(right, fun, :::, :right, state)
    fun.(ast, result)
  end

  defp bitpart_to_string(ast, fun, state) do
    to_string(ast, fun, state)
  end

  defp bitmods_to_string({op, _, [left, right]} = ast, fun, _, _, state) when op in [:*, :-] do
    result =
      bitmods_to_string(left, fun, op, :left, state) <>
      Atom.to_string(op) <>
      bitmods_to_string(right, fun, op, :right, state)
    fun.(ast, result)
  end

  defp bitmods_to_string(other, fun, parent_op, side, state) do
    op_to_string(other, fun, parent_op, side, state)
  end

  # Block keywords
  @kw_keywords [:do, :catch, :rescue, :after, :else]

  defp kw_blocks?([{:do, _} | _] = kw) do
    Enum.all?(kw, &match?({x, _} when x in unquote(@kw_keywords), &1))
  end
  defp kw_blocks?(_), do: false

  # Check if we have an interpolated string.
  defp interpolated?({:<<>>, _, [_ | _] = parts}) do
    Enum.all?(parts, fn
      {:::, _, [{{:., _, [Kernel, :to_string]}, _, [_]},
                {:binary, _, _}]} -> true
      binary when is_binary(binary) -> true
      _ -> false
    end)
  end

  defp interpolated?(_) do
    false
  end

  defp interpolate({:<<>>, meta, _parts} = ast, fun, state) do
    if Keyword.has_key?(meta, :format) do
      interpolate_heredoc(ast, fun, state)
    else
      interpolate_string(ast, fun, state)
    end
  end

  defp interpolate_string({:<<>>, _, parts}, fun, state) do
    parts = Enum.map_join(parts, "", fn
      {:::, _, [{{:., _, [Kernel, :to_string]}, _, [arg]}, {:binary, _, _}]} ->
        "\#{" <> to_string(arg, fun, state) <> "}"
      binary when is_binary(binary) ->
        binary = inspect(binary, [])
        :binary.part(binary, 1, byte_size(binary) - 2)
    end)
    # TODO: wrap it in to_string?
    <<?", parts::binary, ?">>
  end

  defp interpolate_heredoc({:<<>>, meta, parts}, fun, state) do
    parts = Enum.map_join(parts, "", fn
      {:::, _, [{{:., _, [Kernel, :to_string]}, _, [arg]}, {:binary, _, _}]} ->
        "\#{" <> to_string(arg, fun, state) <> "}"
      binary when is_binary(binary) ->
        binary
    end)
    format_literal({:__block__, meta, [parts]}, fun)
  end

  defp sigil_terminator(?/), do: ?/
  defp sigil_terminator(?|), do: ?|
  defp sigil_terminator(?"), do: ?"
  defp sigil_terminator(?'), do: ?'
  defp sigil_terminator(?(), do: ?)
  defp sigil_terminator(?[), do: ?]
  defp sigil_terminator(?{), do: ?}
  defp sigil_terminator(?<), do: ?>

  defp interpolate_with_terminator({:<<>>, _, parts}, terminator, fun, state) do
    parts = Enum.map_join(parts, "", fn
      {:::, _, [{{:., _, [Kernel, :to_string]}, _, [arg]}, {:binary, _, _}]} ->
        "\#{" <> to_string(arg, fun, state) <> "}"
      binary when is_binary(binary) ->
        escape_terminators(binary, terminator)
    end)
    case terminator do
      [c] ->
        <<c, parts::binary, sigil_terminator(c)>>
      [c, c, c] ->
        <<c, c, c, ?\n, parts::binary, c, c, c>>
    end
  end

  defp escape_terminators(binary, terminator) do
    c = List.first terminator
    if length(terminator) == 1 do
      String.replace(binary, <<c>>, <<?\\, c>>)
    else
      binary
    end
  end

  defp module_to_string(atom, _fun, _state) when is_atom(atom), do: inspect(atom, [])
  defp module_to_string(other, fun, state), do: call_to_string(other, fun, state)

  defp sigil_call({func, meta, [{:<<>>, _, _} = bin, args]} = ast, fun, state)
       when is_atom(func) and is_list(args) do
    sigil =
      case Atom.to_string(func) do
        <<"sigil_", name>> ->
          "~" <> <<name>> <>
          interpolate_with_terminator(bin, meta[:terminator], fun, state) <>
          sigil_args(args, fun)
        _ ->
          nil
      end
    fun.(ast, sigil)
  end

  defp sigil_call(_other, _fun, _state) do
    nil
  end

  defp sigil_args([], _fun),   do: ""
  defp sigil_args(args, fun), do: fun.(args, List.to_string(args))

  defp call_to_string(atom, _fun, _state) when is_atom(atom),
    do: Atom.to_string(atom)
  defp call_to_string({:., _, [{:&, _, [val]} = arg]}, fun, state) when not is_integer(val),
    do: "(" <> module_to_string(arg, fun, state) <> ")."
  defp call_to_string({:., _, [{:fn, _, _} = arg]}, fun, state),
    do: "(" <> module_to_string(arg, fun, state) <> ")."
  defp call_to_string({:., _, [arg]}, fun, state),
    do: module_to_string(arg, fun, state) <> "."
  # e.g. env.module()
  defp call_to_string({:., _, [left, right]}, fun, state),
    do: module_to_string(left, fun, state) <> "." <> call_to_string(right, fun, state)
  defp call_to_string(other, fun, state),
    do: to_string(other, fun, state)

  defp call_to_string_with_args({:., _, [:erlang, :binary_to_atom]}, args, fun, state) do
    args = args_to_string(args, fun, state)
    |> String.split("\"")
    |> Enum.drop(-1)
    |> Enum.join()

    <<?:, ?", args::binary, ?">>
  end

  defp call_to_string_with_args(target, args, fun, state) when target in [:with, :for, :defstruct] do
    target_string = Atom.to_string(target) <> " "
    delimiter = ",\n#{String.duplicate(" ", String.length(target_string))}"
    args_string = args_to_string(args, fun, delimiter, state) |> String.trim
    target_string <> args_string
  end

  defp call_to_string_with_args(target, args, fun, state) do
    target_string = call_to_string(target, fun, state)
    args_string = args_to_string(args, fun, state)
    if parenless_call?(target, args, state) do
      (target_string <> " " <> args_string) |> String.trim()
    else
      target_string <> "(" <> args_string <> ")"
    end
  end

  defp args_to_string(args, fun, state) do
    args_to_string(args, fun, ", ", state)
  end

  defp args_to_string(args, fun, delimiter, state) do
    {list, last} = :elixir_utils.split_last(args)
    if last != [] and Inspect.List.keyword?(last) do
      prefix =
        case list do
          [] -> ""
          _  -> Enum.map_join(list, delimiter, &to_string(&1, fun, state)) <> ", "
        end
      kw_list_string =
        last
        |> kw_list_to_string(fun, state)
        |> String.replace_suffix(",\n", "")
        |> handle_kw_list_delimiter(delimiter)
      prefix <> kw_list_string
    else
      Enum.map_join(args, delimiter, &to_string(&1, fun, state))
    end
  end

  defp handle_kw_list_delimiter(kw_list_string, delimiter) do
    case delimiter do
      <<?,, ?\n, indentation::binary>> ->
        String.split(kw_list_string, "\n  ")
        |> Enum.map_join("\n#{indentation}", &(&1))
      _ ->
        kw_list_string
    end
  end

  defp kw_blocks_to_string(kw, fun, args, state) do
    {s, multiline?} = Enum.reduce(@kw_keywords, {"", false}, fn(x, acc) ->
      if Keyword.has_key?(kw, x) do
        ast = Keyword.get(kw, x)
        {s, multiline?} = acc
        multiline? = multiline? or multiline?(ast, state)
        s = s <> kw_block_to_string(x, ast, fun, multiline?, args, state)
        {s, multiline?}
      else
        acc
      end
    end)
    if multiline?, do: " " <> s <> "end", else: s
  end

  defp kw_block_to_string(key, value, fun, multiline?, args, state) do
    block = block_to_string(value, fun, state)
    args_in_front? = length(args) > 0
    if multiline? do
      block = adjust_new_lines block, "\n  "
      Atom.to_string(key) <> "\n  " <> block <> "\n"
    else
      if args_in_front? do
        ", "
      else 
        " "
      end <> Atom.to_string(key) <> ": " <> block
    end
  end

  defp block_to_string([{:->, _, _} | _] = block, fun, state) do
    Enum.map_join(block, "\n", fn({:->, _, [left, right]}) ->
      left = comma_join_or_empty_paren(left, fun, false, state)
      left <> "->\n  " <> adjust_new_lines block_to_string(right, fun, state), "\n  "
    end)
  end

  defp block_to_string({:__block__, meta, [expr]}, fun, state) do
    ast = {:__block__, update_meta(meta), [expr]}
    to_string(ast, fun, state)
  end

  defp block_to_string({:__block__, _, exprs}, fun, state) do
    Enum.map_join(exprs, "\n", &to_string(&1, fun, state))

  end

  defp block_to_string(other, fun, state), do: to_string(other, fun, state)

  defp map_to_string([{:|, _, [update_map, update_args]}], fun, state) do
    to_string(update_map, fun, state) <> " | " <> map_to_string(update_args, fun, state)
  end

  defp map_to_string(list, fun, state) do
    cond do
      Inspect.List.keyword?(list) -> kw_list_to_string(list, fun, state)
      true -> map_list_to_string(list, fun, state)
    end
  end

  def fits?(s), do: String.length(s) <= @split_threshold

  defp line_breaks?(list) when is_list(list) do
    Enum.drop(list, 1) |> Enum.any?(fn elem ->
      value = case elem do
        {k, v} when is_atom(k) -> v
        {k, _} -> k
        v -> v
      end
      case value do
        {_, meta, _} -> meta[:prev] < meta[:line]
        _ -> false
      end
    end)
  end
  defp line_breaks?(_), do: false

  defp prefix_comments_to_elem(elem_ast, elem_string) do
    case elem_ast do
      {_, meta, _} ->
        prefix_comments = meta[:prefix_comments]
        if prefix_comments != nil and prefix_comments != "" do
          adjust_new_lines(prefix_comments <> elem_string, "\n  ")
        else
          elem_string
        end
      _ ->
        elem_string
    end
  end

  defp list_to_string(list, fun, state) do
    list_string = Enum.map_join(list, ", ", &to_string(&1, fun, state))
    if not fits?("  " <> list_string <> "  ") or line_breaks?(list) do
      list_to_multiline_string(list, fun, state)
    else
      list_string
    end
  end

  defp list_to_multiline_string(list, _fun, state) do
    list_string = Enum.map_join(list, ",\n  ", fn value ->
      elem = adjust_new_lines(to_string(value, fn(_ast, string) -> string end, state), "\n  ")
      prefix_comments_to_elem(value, elem)
    end)
    "\n  " <> list_string <> ",\n"
  end

  defp kw_list_to_string(list, fun, state) do
    list_string = Enum.map_join(list, ", ", fn {key, value} ->
      atom_name = case Inspect.Atom.inspect(key) do
        ":" <> rest -> rest
        other       -> other
      end
      atom_name <> ": " <> to_string(value, fn(_ast, string) -> string end, state)
    end)
    if not fits?("  " <> list_string <> "  ") or line_breaks?(list) do
      kw_list_to_multiline_string(list, fun, state)
    else
      list_string
    end
  end

  defp kw_list_to_multiline_string(list, _fun, state) do
    list_string = Enum.map_join(list, ",\n  ", fn {key, value} ->
      atom_name = case Inspect.Atom.inspect(key) do
        ":" <> rest -> rest
        other       -> other
      end
      elem = atom_name <> ": " <> adjust_new_lines(to_string(value, fn(_ast, string) -> string end, state), "\n  ")
      prefix_comments_to_elem(value, elem)
    end)
    "\n  " <> list_string <> ",\n"
  end

  defp map_list_to_string(list, fun, state) do
    list_string = Enum.map_join(list, ", ", fn
      {key, value} ->
        to_string(key, fun, state) <> " => " <> to_string(value, fun, state)
      value ->
        to_string(value, fun, state)
    end)
    if not fits?("  " <> list_string <> "  ") or line_breaks?(list) do
      map_list_to_multiline_string(list, fun, state)
    else
      list_string
    end
  end

  defp map_list_to_multiline_string(list, _fun, state) do
    list_string = Enum.map_join(list, ",\n  ", fn {key, value} ->
      elem = to_string(key, fn(_ast, string) -> string end, state) <> " => " <>
        adjust_new_lines(to_string(value, fn(_ast, string) -> string end, state), "\n  ")
      prefix_comments_to_elem(value, elem)
    end)
    "\n  " <> list_string <> ",\n"
  end

  defp tuple_to_string(tuple, fun, state) do
    tuple_string = Enum.map_join(tuple, ", ", &to_string(&1, fun, state))
    if not fits?("  " <> tuple_string <> "  ") or line_breaks?(tuple) do
      tuple_to_multiline_string(tuple, fun, state)
    else
      tuple_string
    end
  end

  defp tuple_to_multiline_string(tuple, _fun, state) do
    tuple_string = Enum.map_join(tuple, ",\n  ", fn value ->
      elem = adjust_new_lines(to_string(value, fn(_ast, string) -> string end, state), "\n  ")
      prefix_comments_to_elem(value, elem)
    end)
    "\n  " <> tuple_string <> ",\n"
  end

  defp parenthise(expr, fun, state) do
    "(" <> to_string(expr, fun, state) <> ")"
  end

  defp op_to_string({op, _, [_, _]} = expr, fun, parent_op, side, state) when op in unquote(@binary_ops) do
    {parent_assoc, parent_prec} = binary_op_props(parent_op)
    {_, prec}                   = binary_op_props(op)
    cond do
      parent_prec < prec -> to_string(expr, fun, state)
      parent_prec > prec -> parenthise(expr, fun, state)
      true ->
        # parent_prec == prec, so look at associativity.
        if parent_assoc == side do
          to_string(expr, fun, state)
        else
          parenthise(expr, fun, state)
        end
    end
  end

  defp op_to_string(expr, fun, _, _, state), do: to_string(expr, fun, state)

  defp arrow_to_string(pairs, fun, paren \\ false, state) do
    Enum.map_join(pairs, "; ", fn({:->, _, [left, right]}) ->
      left = comma_join_or_empty_paren(left, fun, paren, state)
      left <> "-> " <> to_string(right, fun, state)
    end)
  end

  defp comma_join_or_empty_paren([], _fun, true, _state),  do: "() "
  defp comma_join_or_empty_paren([], _fun, false, _state), do: ""

  defp comma_join_or_empty_paren(left, fun, _, state) do
    Enum.map_join(left, ", ", &to_string(&1, fun, state)) <> " "
  end

  defp adjust_new_lines(block, replacement) do
    for <<x <- block>>, into: "" do
      if x == ?\n do
        replacement
      else
        <<x>>
      end
    end
  end

  # Only underscore decimals that have six or more digits
  defp underscores_in_decimal(string) when byte_size(string) < 6, do: string
  defp underscores_in_decimal(string) do
    string
    |> String.reverse()
    |> Stream.unfold(&String.split_at(&1, 3))
    |> Enum.take_while(&(&1 != ""))
    |> Enum.map_join("_", &(&1))
    |> String.reverse()
  end

  defp codepoint_to_string(int) do
    char = List.to_string([int]) |> inspect([])
    char_string = :binary.part(char, 1, byte_size(char) - 2)
    # Special-case some escape codes
    case char_string do
      "\s" -> "\\s"
      "<0>" -> "\\0"
      _ -> char_string
    end
  end

  defp format_literal({:__block__, meta, [literal]} = ast, fun) do
    expr =
      case meta[:format] do
        :char ->
          "?" <> codepoint_to_string(literal)
        :binary ->
          "0b" <> Integer.to_string(literal, 2)
        :octal ->
          "0o" <> Integer.to_string(literal, 8)
        :hexadecimal ->
          "0x" <> Integer.to_string(literal, 16)
        :decimal ->
          Integer.to_string(literal) |> underscores_in_decimal()
        :bin_heredoc ->
          "\"\"\"\n" <> literal <> "\"\"\""
        :list_heredoc when is_binary(literal) ->
          "'''\n" <> literal <> "'''"
        :list_heredoc ->
          "'''\n" <> List.to_string(literal) <> "'''"
        _ ->
          literal
      end
    fun.(ast, expr)
  end
end
