defmodule Exfuse.Fs.Dsl do
  @moduledoc false

  @ops [
    :readdir,
    :getattr,
    :readlink,
    :read,
    :write,
    :open,
    :create,
    :truncate,
    :unlink,
    :rename,
    :mkdir,
    :rmdir,
    :chmod,
    :chown,
    :flush,
    :release,
    :fsync
  ]
  @error_noent 2
  @attr_dir 1
  @attr_file 2
  @attr_symlink 3

  defmacro init(do: block) do
    init = Macro.escape({block, __CALLER__.line})

    quote do
      @exfuse_init unquote(init)
    end
  end

  defmacro readdir(path, do: block), do: route(__CALLER__, :readdir, path, block)
  defmacro getattr(path, do: block), do: route(__CALLER__, :getattr, path, block)
  defmacro readlink(path, do: block), do: route(__CALLER__, :readlink, path, block)
  defmacro read(path, do: block), do: route(__CALLER__, :read, path, block)
  defmacro write(path, do: block), do: route(__CALLER__, :write, path, block)
  defmacro open(path, do: block), do: route(__CALLER__, :open, path, block)
  defmacro create(path, do: block), do: route(__CALLER__, :create, path, block)
  defmacro truncate(path, do: block), do: route(__CALLER__, :truncate, path, block)
  defmacro unlink(path, do: block), do: route(__CALLER__, :unlink, path, block)
  defmacro rename(path, do: block), do: route(__CALLER__, :rename, path, block)
  defmacro mkdir(path, do: block), do: route(__CALLER__, :mkdir, path, block)
  defmacro rmdir(path, do: block), do: route(__CALLER__, :rmdir, path, block)
  defmacro chmod(path, do: block), do: route(__CALLER__, :chmod, path, block)
  defmacro chown(path, do: block), do: route(__CALLER__, :chown, path, block)
  defmacro flush(path, do: block), do: route(__CALLER__, :flush, path, block)
  defmacro release(path, do: block), do: route(__CALLER__, :release, path, block)
  defmacro fsync(path, do: block), do: route(__CALLER__, :fsync, path, block)

  defmacro plug(path, module), do: plug_route(__CALLER__, path, module)

  defmacro __before_compile__(env) do
    routes =
      env.module
      |> Module.get_attribute(:exfuse_routes)
      |> Enum.reverse()

    init_block = Module.get_attribute(env.module, :exfuse_init)
    has_routes? = routes != []
    init_ast = compile_init(env, init_block, has_routes?)
    exfuse_ast = compile_exfuse(env, routes, has_routes?)

    quote do
      unquote(init_ast)
      unquote(exfuse_ast)
    end
  end

  def attr(opts) when is_list(opts) do
    type = Keyword.fetch!(opts, :type)
    mode = Keyword.get(opts, :mode, default_mode(type))
    size = Keyword.get(opts, :size, 0)

    case Keyword.get(opts, :mtime) do
      nil -> {mode, attr_type(type), size}
      mtime when is_integer(mtime) -> {mode, attr_type(type), size, mtime}
    end
  end

  def put_state(%Exfuse.Socket{} = socket, state), do: Exfuse.Socket.put_state(socket, state)

  def split_path("/"), do: []

  def split_path("/" <> path) when is_binary(path) do
    String.split(path, "/", trim: true)
  end

  def split_path(path) when is_binary(path) do
    String.split(path, "/", trim: true)
  end

  def put_params(%{} = event, params), do: Map.put(event, :params, params)

  def normalize_init_result({:ok, _state} = result), do: result
  def normalize_init_result({:error, _reason} = result), do: result
  def normalize_init_result(state), do: {:ok, state}

  def default_event_result(op, socket)
      when op in [:open, :flush, :release, :fsync],
      do: {:noreply, socket}

  def default_event_result(op, socket)
      when op in [:write, :create, :truncate, :unlink, :rename, :mkdir, :rmdir, :chmod, :chown],
      do: {:error, errno(:enosys), socket}

  def default_event_result(_op, socket), do: {:error, errno(:enoent), socket}

  def normalize_event_result(op, result, _socket) do
    case result do
      {:noreply, %Exfuse.Socket{} = socket} ->
        {:noreply, socket}

      {:reply, reply, %Exfuse.Socket{} = socket} ->
        {:reply, normalize_route_value(op, reply), socket}

      {:error, reason, %Exfuse.Socket{} = socket} ->
        {:error, errno(reason), socket}

      _other ->
        raise ArgumentError,
              "expected handle_event/3 to return {:reply, reply, socket}, {:noreply, socket}, or {:error, reason, socket}"
    end
  end

  def errno(:enoent), do: @error_noent
  def errno(:eperm), do: 1
  def errno(:eio), do: 5
  def errno(:e2big), do: 7
  def errno(:eagain), do: 11
  def errno(:eacces), do: 13
  def errno(:ebusy), do: 16
  def errno(:eexist), do: 17
  def errno(:enotdir), do: 20
  def errno(:eisdir), do: 21
  def errno(:einval), do: 22
  def errno(:enospc), do: 28
  def errno(:erofs), do: 30
  def errno(:enosys), do: 38
  def errno(code) when is_integer(code), do: code

  defp route(caller, op, path, block) when op in @ops do
    route = parse_route!(path, caller)
    entry = Macro.escape({:route, op, route, block, caller.line})

    quote do
      @exfuse_routes unquote(entry)
    end
  end

  defp plug_route(caller, path, module) do
    route = parse_route!(path, caller)
    module = Macro.expand(module, caller)

    unless is_atom(module) do
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description: "exfuse plug module must be an alias or atom"
    end

    entry = Macro.escape({:plug, route, module, caller.line})

    quote do
      @exfuse_routes unquote(entry)
    end
  end

  defp parse_route!(path, caller) when is_binary(path) do
    unless String.starts_with?(path, "/") do
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description: "exfuse route must start with /"
    end

    segments =
      path
      |> String.trim_leading("/")
      |> case do
        "" -> []
        rest -> String.split(rest, "/", trim: false)
      end

    if Enum.any?(segments, &(&1 == "")) do
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description: "exfuse route contains an empty segment"
    end

    tokens = Enum.map(segments, &parse_segment!(&1, caller))

    case Enum.find_index(tokens, &match?({:glob, _}, &1)) do
      nil ->
        tokens

      index when index == length(tokens) - 1 ->
        tokens

      _index ->
        raise CompileError,
          file: caller.file,
          line: caller.line,
          description: "exfuse glob route must be the last segment"
    end
  end

  defp parse_route!(_path, caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description: "exfuse route must be a literal string"
  end

  defp parse_segment!("*", _caller), do: {:glob, nil}
  defp parse_segment!("*" <> name, caller), do: {:glob, parse_binding!(name, caller)}
  defp parse_segment!(":" <> name, caller), do: {:binding, parse_binding!(name, caller)}
  defp parse_segment!(segment, _caller), do: {:literal, segment}

  defp parse_binding!(name, caller) do
    if Regex.match?(~r/^[a-z_][a-zA-Z0-9_]*$/, name) do
      String.to_atom(name)
    else
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description: "invalid exfuse route binding #{inspect(name)}"
    end
  end

  defp compile_init(_env, nil, false), do: nil

  defp compile_init(env, nil, true) do
    if Module.defines?(env.module, {:exfuse_init, 1}, :def) do
      nil
    else
      quote do
        def exfuse_init(init_arg), do: {:ok, init_arg}
      end
    end
  end

  defp compile_init(env, {block, line}, _has_routes?) do
    if Module.defines?(env.module, {:exfuse_init, 1}, :def) do
      raise CompileError,
        file: env.file,
        line: line,
        description: "init macro cannot be used with exfuse_init/1"
    end

    quote do
      def exfuse_init(var!(opts)) do
        _ = var!(opts)
        Exfuse.Fs.Dsl.normalize_init_result(unquote(block))
      end
    end
  end

  defp compile_exfuse(_env, _routes, false), do: nil

  defp compile_exfuse(env, routes, true) do
    if Module.defines?(env.module, {:handle_event, 3}, :def) do
      raise CompileError,
        file: env.file,
        line: entry_line(hd(routes)),
        description: "route macros cannot be used with handle_event/3"
    end

    route_clauses =
      routes
      |> Enum.flat_map(&compile_entry_clauses/1)

    dispatch_clauses =
      Enum.map(@ops, fn op ->
        dispatch = dispatch_name(op)

        quote do
          def handle_event(unquote(op), %{path: path} = event, socket) do
            unquote(dispatch)(Exfuse.Fs.Dsl.split_path(path), event, socket)
          end
        end
      end)

    routes_by_op = routes_by_op(routes)

    dispatch_defaults =
      Enum.map(@ops, fn op ->
        dispatch = dispatch_name(op)

        unless Enum.any?(Map.get(routes_by_op, op, []), &catch_all_route?/1) do
          quote do
            defp unquote(dispatch)(_path, _event, socket),
              do: Exfuse.Fs.Dsl.default_event_result(unquote(op), socket)
          end
        end
      end)
      |> Enum.reject(&is_nil/1)

    quote do
      unquote_splicing(dispatch_clauses)

      def handle_event(op, _event, socket), do: Exfuse.Fs.Dsl.default_event_result(op, socket)

      unquote_splicing(route_clauses)
      unquote_splicing(dispatch_defaults)
    end
  end

  defp entry_line({:route, _op, _route, _block, line}), do: line
  defp entry_line({:plug, _route, _module, line}), do: line

  defp compile_entry_clauses({:route, op, _route, _block, _line} = entry),
    do: [compile_route_clause(dispatch_name(op), entry)]

  defp compile_entry_clauses({:plug, route, module, _line}) do
    Enum.map(@ops, fn op ->
      compile_plug_clause(dispatch_name(op), op, route, module)
    end)
  end

  defp compile_route_clause(dispatch, {:route, op, route, block, _line}) do
    pattern = route_pattern(route)

    quote do
      defp unquote(dispatch)(unquote(pattern), var!(event), var!(socket)) do
        var!(state) = var!(socket).state
        _ = var!(event)
        _ = var!(socket)
        _ = var!(state)
        Exfuse.Fs.Dsl.normalize_event_result(unquote(op), unquote(block), var!(socket))
      end
    end
  end

  defp compile_plug_clause(dispatch, op, route, module) do
    pattern = route_pattern(route)
    params = route_params(route)
    declaration = Macro.escape({module, route})

    quote do
      defp unquote(dispatch)(unquote(pattern), event, socket) do
        params = unquote(params)
        event = Exfuse.Fs.Dsl.put_params(event, params)

        Exfuse.Fs.Runtime.dispatch_plug(
          socket,
          unquote(declaration),
          unquote(module),
          unquote(op),
          event
        )
      end
    end
  end

  defp routes_by_op(routes) do
    routes
    |> Enum.flat_map(fn
      {:route, op, route, _block, _line} -> [{op, route}]
      {:plug, route, _module, _line} -> Enum.map(@ops, &{&1, route})
    end)
    |> Enum.group_by(fn {op, _route} -> op end, fn {_op, route} -> route end)
  end

  defp catch_all_route?([{:glob, _name}]), do: true
  defp catch_all_route?(_route), do: false

  defp route_pattern(route) do
    {prefix, tail} =
      case List.last(route) do
        {:glob, name} -> {Enum.drop(route, -1), glob_tail(name)}
        _ -> {route, []}
      end

    prefix
    |> Enum.reverse()
    |> Enum.reduce(tail, fn
      {:literal, segment}, acc -> cons(segment, acc)
      {:binding, name}, acc -> cons(bound_var(name), acc)
    end)
  end

  defp glob_tail(nil), do: {:_, [], Elixir}
  defp glob_tail(name), do: bound_var(name)
  defp cons(head, tail), do: [{:|, [], [head, tail]}]
  defp bound_var(name), do: {:var!, [], [{name, [], Elixir}]}

  defp route_params(route) do
    params =
      route
      |> Enum.flat_map(fn
        {:binding, name} -> [{name, bound_var(name)}]
        {:glob, name} when is_atom(name) -> [{name, bound_var(name)}]
        _segment -> []
      end)

    {:%{}, [], params}
  end

  defp dispatch_name(op), do: :"__exfuse_#{op}__"

  defp default_mode(:dir), do: 0o0755
  defp default_mode(:file), do: 0o0644
  defp default_mode(:symlink), do: 0o0755

  defp normalize_route_value(:getattr, value), do: normalize_attr(value)

  defp normalize_route_value(:readdir, entries) when is_list(entries) do
    Enum.map(entries, fn {name, attributes} -> {name, normalize_attr(attributes)} end)
  end

  defp normalize_route_value(_op, value), do: value

  defp normalize_attr(%{} = attrs) do
    type = Map.fetch!(attrs, :type)
    mode = Map.get(attrs, :mode, default_mode(type))
    size = Map.get(attrs, :size, 0)

    case Map.get(attrs, :mtime) do
      nil -> {mode, attr_type(type), size}
      mtime -> {mode, attr_type(type), size, mtime}
    end
  end

  defp normalize_attr({mode, type, size}) when is_atom(type) do
    {mode, attr_type(type), size}
  end

  defp normalize_attr({mode, type, size}), do: {mode, type, size}

  defp normalize_attr({mode, type, size, mtime}) when is_atom(type) do
    {mode, attr_type(type), size, mtime}
  end

  defp normalize_attr({mode, type, size, mtime}), do: {mode, type, size, mtime}

  defp attr_type(:dir), do: @attr_dir
  defp attr_type(:file), do: @attr_file
  defp attr_type(:symlink), do: @attr_symlink
end
