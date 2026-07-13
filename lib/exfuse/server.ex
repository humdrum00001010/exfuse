defmodule Exfuse.Server do
  @moduledoc """
  The server joins the FS implementation (the `Exfuse.Fs` callback module) to the
  port (which joins the Elixir run time to the OS / kernel).
  """

  use GenServer
  use Exfuse.Fs, attribs: true
  require Logger
  alias Exfuse.Socket
  @protocol_v2 0x7632_0002

  defstruct mount_point: nil,
            fs_mod: nil,
            fs_state: nil,
            socket: nil,
            phase: :init,
            backend: :fuse,
            port: nil,
            port_os_pid: nil,
            listener: nil,
            fskit_resource: nil,
            reply_to: nil,
            request_id: nil,
            max_concurrency: 8,
            inflight: %{},
            request_queue: :queue.new()

  @doc """
  Called by the `Exfuse.MountSup` supervisor, `start_link` starts an FS
  as a `GenServer`. The three arguments are the same as for `Exfuse.mount/3`.
  """

  @spec start_link(String.t(), module, term) :: {:ok, pid} | {:error, term}

  def start_link(mount_point, fs_mod, fs_opts, opts \\ []) do
    GenServer.start_link(__MODULE__, [mount_point, fs_mod, fs_opts, opts],
      name: {:via, Registry, {Exfuse.Registry, mount_point}}
    )
  end

  @doc """
  Called to stop an FS. A single argument, the PID of the server, is given.
  This is the same as `Exfuse.umount/1` except it requires the PID of the
  `GenServer` process, instead of the mount point.
  """

  @spec stop(pid) :: :ok

  def stop(pid) do
    pid
    |> mount_point()
    |> maybe_unmount()

    GenServer.call(pid, :stop)
  end

  @doc """
  Return a tuple representing the state of the FS. This PID of the `GenServer`
  process must be passed as an argument.

  The tuple elements are the mount point, callback module, the internal
  state of the callback module and the OS PID of the port process.
  """

  @spec status(pid, timeout) :: {String.t(), atom, term, integer}

  def status(pid, timeout \\ 5_000) do
    {:ok, status} = GenServer.call(pid, :status, timeout)
    status
  end

  @doc false
  def dispatch(pid, packet, timeout \\ 5_000) when is_binary(packet) do
    GenServer.call(pid, {:wire_packet, packet}, timeout)
  end

  @doc false
  def init([mount_point, fs_mod, fs_opts, opts]) do
    case Keyword.get_lazy(opts, :backend, &default_backend/0) do
      :fskit -> init_fskit(mount_point, fs_mod, fs_opts, opts)
      :fuse -> init_fuse(mount_point, fs_mod, fs_opts)
    end
  end

  defp default_backend do
    case :os.type() do
      {:unix, :darwin} -> :fskit
      _ -> :fuse
    end
  end

  defp init_fuse(mount_point, fs_mod, fs_opts) do
    case :os.type() do
      {:unix, :darwin} -> {:stop, :fuse_backend_unsupported_on_macos}
      _ -> init_fuse_port(mount_point, fs_mod, fs_opts)
    end
  end

  defp init_fuse_port(mount_point, fs_mod, fs_opts) do
    with {:ok, fs_state} <- fs_mod.exfuse_init(mount_point, fs_opts),
         {:ok, port_path} <- Exfuse.App.find_port!() do
      port =
        Port.open(
          {:spawn_executable, port_path},
          [{:args, ["--mount-point", mount_point]}, {:packet, 4}, :exit_status, :binary]
        )

      socket = Socket.new(mount_point, fs_state)

      state = %__MODULE__{
        mount_point: mount_point,
        fs_mod: fs_mod,
        fs_state: fs_state,
        socket: socket,
        backend: :fuse,
        port: port,
        max_concurrency: System.schedulers_online()
      }

      case wait_for_port(port) do
        {:ok, port_os_pid} -> {:ok, %{state | phase: :ready, port_os_pid: port_os_pid}}
        {:error, reason} -> {:stop, reason}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp init_fskit(mount_point, fs_mod, fs_opts, opts) do
    port = Keyword.get(opts, :wire_port, 35_368)

    with {:ok, fs_state} <- fs_mod.exfuse_init(mount_point, fs_opts),
         {:ok, listener} <- Exfuse.WireListener.start_link(server: self(), port: port) do
      socket = Socket.new(mount_point, fs_state)

      state = %__MODULE__{
        mount_point: mount_point,
        fs_mod: fs_mod,
        fs_state: fs_state,
        socket: socket,
        phase: :ready,
        backend: :fskit,
        listener: listener,
        fskit_resource: Keyword.get(opts, :fskit_resource),
        max_concurrency: Keyword.get(opts, :max_concurrency, System.schedulers_online())
      }

      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  def terminate(
        _reason,
        %__MODULE__{
          port_os_pid: nil,
          listener: nil
        } = _state
      ) do
    :undefined
  end

  def terminate(_reason, state) do
    server_stop_port(state)
    :undefined
  end

  defp port_tx(data, %__MODULE__{reply_to: {:capture, pid, ref}} = state) do
    send(pid, {:captured_reply, ref, wire_reply(state, data)})
    state
  end

  defp port_tx(data, %__MODULE__{reply_to: {:genserver_client, from}} = state) do
    GenServer.reply(from, wire_reply(state, data))
    state
  end

  defp port_tx(data, %__MODULE__{reply_to: {:port, port}} = state) do
    Port.command(port, wire_reply(state, data))
    state
  catch
    :error, :badarg -> state
  end

  defp port_tx(data, %__MODULE__{port: port} = state) do
    Port.command(port, wire_reply(state, data))
    state
  catch
    :error, :badarg -> state
  end

  defp wire_reply(%__MODULE__{request_id: nil}, data),
    do: <<@magiccookie::size(32), data::binary>>

  defp wire_reply(%__MODULE__{request_id: request_id}, <<code::size(32), rest::binary>>),
    do:
      <<@magiccookie::size(32), @protocol_v2::size(32), code::size(32), request_id::size(64),
        rest::binary>>

  defp mount_point(pid) do
    case GenServer.call(pid, :status, 1_000) do
      {:ok, {mount_point, _fs_mod, _fs_state, _port_os_pid}} -> mount_point
    end
  catch
    :exit, _reason -> nil
  end

  defp maybe_unmount(nil), do: :ok
  defp maybe_unmount(mount_point), do: unmount(mount_point)

  @spec handle_fusereq(%__MODULE__{}, map, integer, fun) :: %__MODULE__{}
  defp handle_fusereq(state, event, req_code, reply_fun),
    do: handle_event_fusereq(state, event, req_code, reply_fun)

  defp handle_event_fusereq(
         %__MODULE__{fs_mod: fs_mod, socket: %Socket{} = socket} = state,
         %{op: op} = event,
         req_code,
         reply_fun
       ) do
    payload = Map.delete(event, :op)

    result =
      Exfuse.Fs.Dsl.normalize_event_result(
        op,
        fs_mod.handle_event(op, payload, socket),
        socket
      )

    {status, payload, socket} = event_response(result, reply_fun)

    port_tx(
      <<req_code::size(32), status::size(32), payload::binary>>,
      %__MODULE__{state | fs_state: socket.state, socket: socket}
    )
  end

  defp event_response({:noreply, %Socket{} = socket}, _reply_fun), do: {0, <<>>, socket}

  defp event_response({:reply, reply, %Socket{} = socket}, reply_fun),
    do: {0, reply_fun.(reply), socket}

  defp event_response({:error, error, %Socket{} = socket}, _reply_fun), do: {error, <<>>, socket}

  defp handle_unit_fusereq(state, event, req_code),
    do: handle_event_fusereq(state, event, req_code, fn _reply -> <<>> end)

  defp handle_open_fusereq(state, event, req_code),
    do: handle_event_fusereq(state, event, req_code, &open_payload/1)

  defp take_path(<<len::size(32), rest::binary>>) do
    <<path::binary-size(^len), tail::binary>> = rest
    {path, tail}
  end

  defp context(<<uid::size(32), gid::size(32), pid::size(32), umask::size(32), payload::binary>>) do
    {%{uid: uid, gid: gid, pid: pid, umask: umask}, payload}
  end

  defp event(op, ctx, attrs) do
    ctx
    |> Map.merge(Map.new(attrs))
    |> Map.put(:op, op)
  end

  defp open_payload(handle) when is_integer(handle), do: <<handle::size(64)>>

  defp route_request(state, code, request_id, data, destination) do
    request = {code, request_id, data, destination}

    cond do
      parallel_code?(code) and map_size(state.inflight) < state.max_concurrency and
          queue_empty?(state.request_queue) ->
        {:noreply, start_parallel_request(state, request)}

      map_size(state.inflight) == 0 and queue_empty?(state.request_queue) ->
        {:noreply, run_serial_request(state, request)}

      true ->
        {:noreply, %{state | request_queue: :queue.in(request, state.request_queue)}}
    end
  end

  defp start_parallel_request(state, {code, request_id, data, destination}) do
    parent = self()
    ref = make_ref()
    base_socket = state.socket

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        worker_state = %{state | reply_to: {:capture, self(), ref}, request_id: request_id}
        packet = <<@magiccookie::size(32), code::size(32), data::binary>>
        {:noreply, completed} = handle_info({state.port, {:data, packet}}, worker_state)

        receive do
          {:captured_reply, ^ref, response} ->
            send(parent, {:parallel_request_done, ref, response, completed.socket})
        end
      end)

    entry = %{
      base_socket: base_socket,
      destination: destination,
      code: code,
      request_id: request_id,
      pid: pid,
      monitor_ref: monitor_ref
    }

    %{state | inflight: Map.put(state.inflight, ref, entry)}
  end

  defp run_serial_request(state, {code, request_id, data, destination}) do
    packet = <<@magiccookie::size(32), code::size(32), data::binary>>
    state = %{state | request_id: request_id, reply_to: destination}
    {:noreply, state} = handle_info({state.port, {:data, packet}}, state)
    %{state | request_id: nil, reply_to: nil}
  end

  defp drain_request_queue(state) do
    case :queue.out(state.request_queue) do
      {:empty, _queue} ->
        state

      {{:value, {code, _, _, _} = request}, queue}
      when code in [@request_readdir, @request_getattr, @request_readlink, @request_read] and
             map_size(state.inflight) < state.max_concurrency ->
        state
        |> Map.put(:request_queue, queue)
        |> start_parallel_request(request)
        |> drain_request_queue()

      {{:value, request}, queue} when map_size(state.inflight) == 0 ->
        state
        |> Map.put(:request_queue, queue)
        |> run_serial_request(request)
        |> drain_request_queue()

      _blocked ->
        state
    end
  end

  defp parallel_code?(code),
    do: code in [@request_readdir, @request_getattr, @request_readlink, @request_read]

  defp queue_empty?(queue), do: :queue.is_empty(queue)

  defp send_wire_reply({:port, port}, response), do: Port.command(port, response)
  defp send_wire_reply({:genserver_client, from}, response), do: GenServer.reply(from, response)

  defp retry_response(
         <<@magiccookie::size(32), @protocol_v2::size(32), code::size(32), request_id::size(64),
           _status::size(32), _payload::binary>>
       ) do
    <<@magiccookie::size(32), @protocol_v2::size(32), code::size(32), request_id::size(64),
      11::size(32)>>
  end

  defp error_response(code, request_id, errno) do
    <<@magiccookie::size(32), @protocol_v2::size(32), code::size(32), request_id::size(64),
      errno::size(32)>>
  end

  # Protocol v2 adds a request id after the operation code. Read-only requests
  # may execute in bounded workers and therefore complete out of order. Stateful
  # requests retain arrival ordering and wait for earlier reads to finish.
  def handle_info(
        {port,
         {:data,
          <<@magiccookie::size(32), @protocol_v2::size(32), code::size(32), request_id::size(64),
            data::binary>>}},
        %__MODULE__{port: port} = state
      )
      when code >= @request_readdir and code <= @request_fsync do
    route_request(state, code, request_id, data, {:port, port})
  end

  def handle_info({:parallel_request_done, ref, response, worker_socket}, state) do
    case Map.pop(state.inflight, ref) do
      {nil, _inflight} ->
        {:noreply, state}

      {%{base_socket: base_socket, destination: destination, monitor_ref: monitor_ref}, inflight} ->
        Process.demonitor(monitor_ref, [:flush])

        {response, socket} =
          if state.socket == base_socket do
            {response, worker_socket}
          else
            # The callback returned state derived from an obsolete snapshot.
            # EAGAIN prevents a successful reply from silently losing it.
            {retry_response(response), state.socket}
          end

        send_wire_reply(destination, response)

        state = %{state | inflight: inflight, socket: socket, fs_state: socket.state}
        {:noreply, drain_request_queue(state)}
    end
  end

  def handle_info({:DOWN, monitor_ref, :process, _pid, reason}, state) do
    case Enum.find(state.inflight, fn {_ref, entry} -> entry.monitor_ref == monitor_ref end) do
      nil ->
        {:noreply, state}

      {ref, entry} ->
        Logger.error(
          "Exfuse parallel request worker failed",
          operation_code: entry.code,
          request_id: entry.request_id,
          reason: inspect(reason)
        )

        send_wire_reply(entry.destination, error_response(entry.code, entry.request_id, 5))
        state = %{state | inflight: Map.delete(state.inflight, ref)}
        {:noreply, drain_request_queue(state)}
    end
  end

  def handle_info(
        {port, {:data, <<@magiccookie::size(32), @request_readdir::size(32), data::binary>>}},
        %__MODULE__{port: port} = state
      ) do
    {ctx, path} = context(data)
    event = event(:readdir, ctx, path: path)

    new_state =
      handle_fusereq(state, event, @request_readdir, fn reply ->
        List.foldl(reply, <<>>, fn e, a when is_binary(e) ->
          <<a::binary, e::binary, 0::size(8)>>
        end)
      end)

    {:noreply, new_state}
  end

  def handle_info(
        {port, {:data, <<@magiccookie::size(32), @request_getattr::size(32), data::binary>>}},
        %__MODULE__{port: port} = state
      ) do
    {ctx, path} = context(data)
    event = event(:getattr, ctx, path: path)

    new_state =
      handle_fusereq(state, event, @request_getattr, fn
        {mode, type, size} when is_integer(mode) and is_integer(type) and is_integer(size) ->
          <<mode::size(32), type::size(32), size::size(32)>>

        {mode, type, size, mtime}
        when is_integer(mode) and is_integer(type) and is_integer(size) and is_integer(mtime) ->
          <<mode::size(32), type::size(32), size::size(32), mtime::size(64)>>
      end)

    {:noreply, new_state}
  end

  def handle_info(
        {port, {:data, <<@magiccookie::size(32), @request_readlink::size(32), data::binary>>}},
        %__MODULE__{port: port} = state
      ) do
    {ctx, path} = context(data)
    event = event(:readlink, ctx, path: path)

    new_state =
      handle_fusereq(state, event, @request_readlink, fn link_dest ->
        <<link_dest::binary, 0::size(8)>>
      end)

    {:noreply, new_state}
  end

  def handle_info(
        {port, {:data, <<@magiccookie::size(32), @request_read::size(32), data::binary>>}},
        %__MODULE__{port: port} = state
      ) do
    {ctx, <<flags::size(32), handle::size(64), offset::size(64), size::size(64), rest::binary>>} =
      context(data)

    {path, <<>>} = take_path(rest)

    event =
      event(:read, ctx, path: path, flags: flags, handle: handle, offset: offset, size: size)

    new_state =
      handle_fusereq(
        state,
        event,
        @request_read,
        fn content -> content end
      )

    {:noreply, new_state}
  end

  def handle_info(
        {port, {:data, <<@magiccookie::size(32), @request_write::size(32), data::binary>>}},
        %__MODULE__{port: port} = state
      ) do
    {ctx, <<handle::size(64), offset::size(64), path_len::size(32), rest::binary>>} =
      context(data)

    <<path::binary-size(^path_len), data::binary>> = rest

    event =
      event(:write, ctx,
        path: path,
        handle: handle,
        offset: offset,
        data: data
      )

    new_state =
      handle_fusereq(state, event, @request_write, fn written when is_integer(written) ->
        <<written::size(32)>>
      end)

    {:noreply, new_state}
  end

  def handle_info(
        {port, {:data, <<@magiccookie::size(32), @request_open::size(32), data::binary>>}},
        %__MODULE__{port: port} = state
      ) do
    {ctx, <<flags::size(32), rest::binary>>} = context(data)
    {path, <<>>} = take_path(rest)
    event = event(:open, ctx, path: path, flags: flags)

    new_state = handle_open_fusereq(state, event, @request_open)

    {:noreply, new_state}
  end

  def handle_info(
        {port, {:data, <<@magiccookie::size(32), @request_create::size(32), data::binary>>}},
        %__MODULE__{port: port} = state
      ) do
    {ctx, <<mode::size(32), flags::size(32), rest::binary>>} = context(data)
    {path, <<>>} = take_path(rest)
    event = event(:create, ctx, path: path, mode: mode, flags: flags)

    new_state = handle_open_fusereq(state, event, @request_create)

    {:noreply, new_state}
  end

  def handle_info(
        {port, {:data, <<@magiccookie::size(32), @request_truncate::size(32), data::binary>>}},
        %__MODULE__{port: port} = state
      ) do
    {ctx, <<size::size(64), rest::binary>>} = context(data)
    {path, <<>>} = take_path(rest)
    event = event(:truncate, ctx, path: path, size: size)

    new_state = handle_unit_fusereq(state, event, @request_truncate)

    {:noreply, new_state}
  end

  def handle_info(
        {port, {:data, <<@magiccookie::size(32), @request_unlink::size(32), data::binary>>}},
        %__MODULE__{port: port} = state
      ) do
    {ctx, path} = context(data)
    event = event(:unlink, ctx, path: path)

    new_state = handle_unit_fusereq(state, event, @request_unlink)

    {:noreply, new_state}
  end

  def handle_info(
        {port, {:data, <<@magiccookie::size(32), @request_rename::size(32), data::binary>>}},
        %__MODULE__{port: port} = state
      ) do
    {ctx, <<_flags::size(32), rest::binary>>} = context(data)
    {old_path, rest} = take_path(rest)
    {new_path, <<>>} = take_path(rest)
    event = event(:rename, ctx, path: old_path, target: new_path)

    new_state = handle_unit_fusereq(state, event, @request_rename)

    {:noreply, new_state}
  end

  def handle_info(
        {port, {:data, <<@magiccookie::size(32), @request_mkdir::size(32), data::binary>>}},
        %__MODULE__{port: port} = state
      ) do
    {ctx, <<mode::size(32), rest::binary>>} = context(data)
    {path, <<>>} = take_path(rest)
    event = event(:mkdir, ctx, path: path, mode: mode)

    new_state = handle_unit_fusereq(state, event, @request_mkdir)

    {:noreply, new_state}
  end

  def handle_info(
        {port, {:data, <<@magiccookie::size(32), @request_rmdir::size(32), data::binary>>}},
        %__MODULE__{port: port} = state
      ) do
    {ctx, path} = context(data)
    event = event(:rmdir, ctx, path: path)

    new_state = handle_unit_fusereq(state, event, @request_rmdir)

    {:noreply, new_state}
  end

  def handle_info(
        {port, {:data, <<@magiccookie::size(32), @request_chmod::size(32), data::binary>>}},
        %__MODULE__{port: port} = state
      ) do
    {ctx, <<mode::size(32), rest::binary>>} = context(data)
    {path, <<>>} = take_path(rest)
    event = event(:chmod, ctx, path: path, mode: mode)

    new_state = handle_unit_fusereq(state, event, @request_chmod)

    {:noreply, new_state}
  end

  def handle_info(
        {port, {:data, <<@magiccookie::size(32), @request_chown::size(32), data::binary>>}},
        %__MODULE__{port: port} = state
      ) do
    {ctx, <<uid::size(32), gid::size(32), rest::binary>>} = context(data)
    {path, <<>>} = take_path(rest)
    event = event(:chown, ctx, path: path, owner_uid: uid, owner_gid: gid)

    new_state = handle_unit_fusereq(state, event, @request_chown)

    {:noreply, new_state}
  end

  def handle_info(
        {port, {:data, <<@magiccookie::size(32), @request_flush::size(32), data::binary>>}},
        %__MODULE__{port: port} = state
      ) do
    {ctx, <<flags::size(32), handle::size(64), rest::binary>>} = context(data)
    {path, <<>>} = take_path(rest)
    event = event(:flush, ctx, path: path, flags: flags, handle: handle)

    new_state = handle_unit_fusereq(state, event, @request_flush)

    {:noreply, new_state}
  end

  def handle_info(
        {port, {:data, <<@magiccookie::size(32), @request_release::size(32), data::binary>>}},
        %__MODULE__{port: port} = state
      ) do
    {ctx, <<flags::size(32), handle::size(64), rest::binary>>} = context(data)
    {path, <<>>} = take_path(rest)
    event = event(:release, ctx, path: path, flags: flags, handle: handle)

    new_state = handle_unit_fusereq(state, event, @request_release)

    {:noreply, new_state}
  end

  def handle_info(
        {port, {:data, <<@magiccookie::size(32), @request_fsync::size(32), data::binary>>}},
        %__MODULE__{port: port} = state
      ) do
    {ctx, <<datasync::size(32), flags::size(32), handle::size(64), rest::binary>>} =
      context(data)

    {path, <<>>} = take_path(rest)

    event =
      event(:fsync, ctx,
        path: path,
        datasync: datasync != 0,
        flags: flags,
        handle: handle
      )

    new_state = handle_unit_fusereq(state, event, @request_fsync)

    {:noreply, new_state}
  end

  def handle_info(
        {port,
         {:data, <<@magiccookie::size(32), @status_data::size(32), port_os_pid::size(32)>>}},
        %__MODULE__{port: port} = state
      ) do
    {:noreply, %__MODULE__{state | phase: :ready, port_os_pid: port_os_pid}}
  end

  def handle_info(
        {port, {:exit_status, 0}},
        %__MODULE__{port: port} = state
      ) do
    {:noreply, server_slow_stop(%{state | port_os_pid: nil}, :normal)}
  end

  def handle_info(
        {port, {:exit_status, 143}},
        %__MODULE__{phase: :stopping, port: port} = state
      ) do
    {:noreply, %{state | port_os_pid: nil}}
  end

  def handle_info({port, {:exit_status, status}}, %__MODULE__{port: port} = state) do
    log_error("port exited with status #{status} for #{state.mount_point}")
    {:noreply, server_slow_stop(%{state | port_os_pid: nil}, {:port_exit, status})}
  end

  def handle_info(
        {port, {:data, <<@magiccookie::size(32), data::binary>>}},
        %__MODULE__{port: port, port_os_pid: port_os_pid} = state
      ) do
    log_error(
      "ignoring port (PID #{port_os_pid}) unrecognised data #{inspect(data)} to exfuse #{:erlang.pid_to_list(self())}"
    )

    {:noreply, state}
  end

  def handle_info(
        {port, {:data, data}},
        %__MODULE__{port: port, port_os_pid: port_os_pid} = state
      ) do
    log_error(
      "port (PID #{port_os_pid}) data #{inspect(data)} to exfuse #{:erlang.pid_to_list(self())} received without correct cookie"
    )

    {_method, state} = server_stop_port(state)

    {:noreply,
     server_slow_stop(state, {:error, "communication with port fatally compromised (bad cookie)"})}
  end

  def handle_info(
        {:slow_stop, {reason, {:genserver_client, client}}},
        %__MODULE__{phase: :stopping} = state
      ) do
    GenServer.reply(client, :ok)
    {:stop, reason, state}
  end

  def handle_info({:slow_stop, reason}, %__MODULE__{phase: :stopping} = state) do
    {:stop, reason, state}
  end

  def handle_call(:stop, from, %__MODULE__{phase: :init} = state) do
    {:noreply, server_slow_stop(state, {:normal, from})}
  end

  def handle_call(:stop, from, %__MODULE__{} = state) do
    case server_stop_port(state) do
      {:unmounted, state} ->
        {:reply, :ok, server_slow_stop(state, :normal)}

      {:killed, state} ->
        {:noreply, server_slow_stop(state, {:normal, {:genserver_client, from}})}
    end
  end

  def handle_call(:status, _from, %__MODULE__{port_os_pid: port_os_pid} = state) do
    status = {
      state.mount_point,
      state.fs_mod,
      state.fs_state,
      port_os_pid
    }

    {:reply, {:ok, status}, state}
  end

  def handle_call({:wire_packet, packet}, from, %__MODULE__{} = state) do
    case packet do
      <<@magiccookie::size(32), @protocol_v2::size(32), code::size(32), request_id::size(64),
        data::binary>>
      when code >= @request_readdir and code <= @request_fsync ->
        route_request(state, code, request_id, data, {:genserver_client, from})

      # v2-framed but outside the supported operation range (a newer client
      # talking to this server): answer ENOSYS instead of leaving the wire
      # client blocked on a reply that will never come.
      <<@magiccookie::size(32), @protocol_v2::size(32), code::size(32), request_id::size(64),
        _data::binary>> ->
        {:reply, error_response(code, request_id, 38), state}

      <<@magiccookie::size(32), code::size(32), _data::binary>>
      when code >= @request_readdir and code <= @request_fsync ->
        state = %{state | reply_to: {:genserver_client, from}}

        case handle_info({state.port, {:data, packet}}, state) do
          {:noreply, state} -> {:noreply, %{state | reply_to: nil}}
          {:stop, reason, state} -> {:stop, reason, %{state | reply_to: nil}}
        end

      # Unrecognizable wire packet (protocol skew, garbage): a transport
      # client is waiting synchronously, so reply an EIO-framed error rather
      # than hanging its connection thread forever. The mismatch is loud in
      # the log either way.
      _unrecognized ->
        log_error(
          "replying EIO to unrecognizable wire packet (#{byte_size(packet)} bytes) " <>
            "for #{state.mount_point}; protocol skew between the FSKit extension " <>
            "and this exfuse version?"
        )

        {:reply, error_response(0, 0, 5), state}
    end
  end

  defp server_stop_port(%__MODULE__{backend: :fskit, listener: listener} = state) do
    if is_pid(listener), do: GenServer.stop(listener)

    cleanup_fskit_resource(state.fskit_resource)
    {:unmounted, %{state | listener: nil, fskit_resource: nil}}
  end

  defp server_stop_port(%__MODULE__{port_os_pid: nil} = state) do
    {:unmounted, state}
  end

  defp server_stop_port(%__MODULE__{port_os_pid: port_os_pid} = state) do
    kill_port(port_os_pid)

    {:killed, %{state | port_os_pid: nil}}
  end

  defp unmount(mount_point) do
    System.cmd("umount", [mount_point], stderr_to_stdout: true)

    if mounted?(mount_point) do
      with diskutil when is_binary(diskutil) <- System.find_executable("diskutil") do
        System.cmd(diskutil, ["unmount", "force", mount_point], stderr_to_stdout: true)
      end
    end
  end

  defp cleanup_fskit_resource(nil), do: :ok

  defp cleanup_fskit_resource(%{owned: true, device: device, image: image}) do
    if is_binary(device) and device != "" do
      System.cmd("hdiutil", ["detach", device], stderr_to_stdout: true)
    end

    if is_binary(image), do: File.rm(image)
    :ok
  end

  defp cleanup_fskit_resource(_resource), do: :ok

  defp kill_port(port_os_pid) do
    pid = "#{port_os_pid}"
    System.cmd("kill", [pid], stderr_to_stdout: true)
    Process.sleep(100)

    if port_alive?(pid) do
      System.cmd("kill", ["-9", pid], stderr_to_stdout: true)
    end
  end

  defp port_alive?(pid) do
    case System.cmd("kill", ["-0", pid], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp mounted?(mount_point) do
    paths = mount_candidates(mount_point)

    case System.cmd("mount", [], stderr_to_stdout: true) do
      {mounts, 0} -> Enum.any?(paths, &String.contains?(mounts, " on #{&1} "))
      _ -> false
    end
  end

  defp mount_candidates(mount_point) do
    [mount_point, realpath(mount_point)]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp realpath(path) do
    case :file.read_link_all(String.to_charlist(path)) do
      {:ok, path} -> List.to_string(path)
      {:error, _reason} -> nil
    end
  end

  defp wait_for_port(port) do
    receive do
      {^port, {:data, <<@magiccookie::size(32), @status_data::size(32), port_os_pid::size(32)>>}} ->
        {:ok, port_os_pid}

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}

      {^port, {:data, data}} ->
        {:error, {:bad_port_data, data}}
    after
      5_000 ->
        {:error, :port_start_timeout}
    end
  end

  defp server_slow_stop(%__MODULE{phase: phase} = state, _info) when phase === :stopping do
    state
  end

  defp server_slow_stop(state, info) do
    Process.send_after(self(), {:slow_stop, info}, 100, [])
    %{state | phase: :stopping}
  end

  defp log_error(msg) do
    :ok = :error_logger.error_msg(String.to_charlist(msg))
  end
end
