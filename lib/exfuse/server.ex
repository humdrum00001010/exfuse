defmodule Exfuse.Server do
  @moduledoc """
  The server joins the FS implementation (the `Exfuse.Fs` callback module) to the
  port (which joins the Elixir run time to the OS / kernel).
  """

  use GenServer
  use Exfuse.Fs, attribs: true
  alias Exfuse.Socket

  defstruct mount_point: nil,
            fs_mod: nil,
            fs_state: nil,
            socket: nil,
            phase: :init,
            port: nil,
            port_os_pid: nil

  @doc """
  Called by the `Exfuse.MountSup` supervisor, `start_link` starts an FS
  as a `GenServer`. The three arguments are the same as for `Exfuse.mount/3`.
  """

  @spec start_link(String.t(), module, term) :: {:ok, pid} | {:error, term}

  def start_link(mount_point, fs_mod, fs_opts) do
    GenServer.start_link(__MODULE__, [mount_point, fs_mod, fs_opts], [])
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
  def init([mount_point, fs_mod, fs_opts]) do
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
        port: port
      }

      case wait_for_port(port) do
        {:ok, port_os_pid} -> {:ok, %{state | phase: :ready, port_os_pid: port_os_pid}}
        {:error, reason} -> {:stop, reason}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  def terminate(
        _reason,
        %__MODULE__{
          port_os_pid: nil
        } = _state
      ) do
    :undefined
  end

  def terminate(_reason, state) do
    server_stop_port(state)
    :undefined
  end

  defp port_tx(data, %__MODULE__{port: port} = state) do
    Port.command(port, <<@magiccookie::size(32), data::binary>>)
    state
  catch
    :error, :badarg -> state
  end

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
