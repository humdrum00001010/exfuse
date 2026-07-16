defmodule Exfuse.RuntimeTest do
  use ExUnit.Case, async: false

  alias Exfuse.{File, Socket}

  defmodule ConcurrentFs do
    @behaviour Exfuse.Fs

    def exfuse_init(owner), do: {:ok, %{owner: owner, writes: 0, buffers: %{}}}

    def handle_event(:read, %{token: token}, socket) do
      send(socket.state.owner, {:read_started, token, self()})
      receive do: ({:release, ^token} -> {:reply, token, socket})
    end

    def handle_event(:write, %{token: token}, socket) do
      send(socket.state.owner, {:write_started, token, socket.state.writes, self()})

      receive do
        {:release, ^token} ->
          next = Socket.put_state(socket, %{socket.state | writes: socket.state.writes + 1})
          {:reply, socket.state.writes, next}
      end
    end

    def handle_event(
          :write,
          %{handle: handle, offset: offset, data: data},
          socket
        ) do
      current = Map.get(socket.state.buffers, handle, "")
      next_buffer = splice(current, offset, data)

      send(
        socket.state.owner,
        {:offset_write_seen, handle, offset, byte_size(current), self()}
      )

      next =
        Socket.put_state(socket, %{
          socket.state
          | writes: socket.state.writes + 1,
            buffers: Map.put(socket.state.buffers, handle, next_buffer)
        })

      {:reply, byte_size(data), next}
    end

    def handle_event(:getattr, %{token: token}, socket) do
      send(socket.state.owner, {:getattr_started, token, socket.state.writes, self()})

      receive do
        {:release, ^token} ->
          increment = if token == :a, do: 1, else: 2

          next =
            Socket.put_state(socket, %{socket.state | writes: socket.state.writes + increment})

          {:reply, Exfuse.Fs.attr(type: :dir), next}
      end
    end

    def handle_event(_operation, _event, socket), do: {:error, :enoent, socket}

    defp splice(buffer, offset, data) do
      size = byte_size(buffer)

      cond do
        offset == size ->
          buffer <> data

        offset < size ->
          head = binary_part(buffer, 0, offset)
          tail_start = offset + byte_size(data)

          tail =
            if tail_start < size, do: binary_part(buffer, tail_start, size - tail_start), else: ""

          head <> data <> tail

        true ->
          buffer <> :binary.copy(<<0>>, offset - size) <> data
      end
    end
  end

  setup do
    {:ok, fs} = Exfuse.start_fs(ConcurrentFs, self(), max_concurrency: 2)
    {:ok, file} = Exfuse.Fs.Supervisor.root(fs)
    on_exit(fn -> if Process.alive?(fs), do: Exfuse.stop_fs(fs) end)
    %{fs: fs, root_file: file}
  end

  test "immutable reads run concurrently", %{root_file: file} do
    first = Task.async(fn -> File.dispatch(file, :read, %{token: :a, path: "/a"}) end)
    second = Task.async(fn -> File.dispatch(file, :read, %{token: :b, path: "/b"}) end)

    assert_receive {:read_started, :a, a}
    assert_receive {:read_started, :b, b}
    send(a, {:release, :a})
    send(b, {:release, :b})

    assert {:reply, :a, _} = Task.await(first)
    assert {:reply, :b, _} = Task.await(second)
  end

  test "each Fs owns its File and Mount supervisors", %{fs: fs, root_file: root} do
    file_supervisor = Exfuse.Fs.Supervisor.file_supervisor(fs)
    mount_supervisor = Exfuse.Fs.Supervisor.mount_supervisor(fs)

    assert Process.alive?(file_supervisor)
    assert Process.alive?(mount_supervisor)

    assert Enum.any?(DynamicSupervisor.which_children(file_supervisor), fn
             {:undefined, ^root, :worker, [Exfuse.File]} -> true
             _ -> false
           end)
  end

  test "stateful operations are ordered", %{root_file: file} do
    first = Task.async(fn -> File.dispatch(file, :write, %{token: :a, path: "/a"}) end)
    assert_receive {:write_started, :a, 0, a}

    second = Task.async(fn -> File.dispatch(file, :write, %{token: :b, path: "/b"}) end)
    refute_receive {:write_started, :b, _, _}, 25
    send(a, {:release, :a})
    assert {:reply, 0, _} = Task.await(first)

    assert_receive {:write_started, :b, 1, b}
    send(b, {:release, :b})
    assert {:reply, 1, _} = Task.await(second)
  end

  test "offset writes preserve one socket state and isolate backend handles", %{root_file: file} do
    writes = [
      %{handle: 71, offset: 0, data: "AAAA", path: "/projection"},
      %{handle: 71, offset: 8, data: "CCCC", path: "/projection"},
      %{handle: 72, offset: 0, data: "other", path: "/projection"},
      %{handle: 71, offset: 4, data: "BBBB", path: "/projection"}
    ]

    results =
      writes
      |> Enum.map(fn event -> Task.async(fn -> File.dispatch(file, :write, event) end) end)
      |> Enum.map(&Task.await/1)

    assert Enum.sort(Enum.map(results, fn {:reply, written, _socket} -> written end)) == [
             4,
             4,
             4,
             5
           ]

    callback_pids =
      for _ <- writes do
        assert_receive {:offset_write_seen, _handle, _offset, _prior_size, callback_pid}
        callback_pid
      end

    assert callback_pids |> MapSet.new() |> MapSet.size() == length(writes)

    snapshot = File.snapshot(file)
    assert snapshot.state.writes == length(writes)
    assert snapshot.state.buffers[71] == "AAAABBBBCCCC"
    assert snapshot.state.buffers[72] == "other"
  end

  test "conflicting stateful reads retry in order instead of returning EIO", %{root_file: file} do
    first = Task.async(fn -> File.dispatch(file, :getattr, %{token: :a, path: "/"}) end)
    second = Task.async(fn -> File.dispatch(file, :getattr, %{token: :b, path: "/"}) end)

    assert_receive {:getattr_started, :a, 0, a}
    assert_receive {:getattr_started, :b, 0, b}

    send(a, {:release, :a})
    assert {:reply, _attr, _} = Task.await(first)

    send(b, {:release, :b})
    assert_receive {:getattr_started, :b, 1, retried_b}
    send(retried_b, {:release, :b})

    assert {:reply, _attr, socket} = Task.await(second)
    assert socket.state.writes == 3
    assert File.snapshot(file).state.writes == 3
  end

  test "a mount point has one owner and unmount is idempotent", %{fs: fs} do
    mount_point =
      Path.join(System.tmp_dir!(), "exfuse-exclusive-#{System.unique_integer([:positive])}")

    on_exit(fn -> Elixir.File.rm_rf(mount_point) end)

    options = [backend: :fskit, mount_command: "/usr/bin/true", verify: false]

    assert {:ok, mount} = Exfuse.mount(fs, mount_point, options)

    assert {:error, {:already_mounted, ^mount}} =
             Exfuse.mount(fs, mount_point, Keyword.put(options, :wire_port, free_port()))

    assert :ok = Exfuse.unmount(mount_point)
    refute Process.alive?(mount)

    assert :ok = Exfuse.unmount(mount)
  end

  test "mount probes are false for an ordinary directory" do
    path = Path.join(System.tmp_dir!(), "exfuse-probe-#{System.unique_integer([:positive])}")
    Elixir.File.mkdir_p!(path)
    on_exit(fn -> Elixir.File.rm_rf(path) end)

    refute Exfuse.mounted?(path)
    refute Exfuse.serving?(path)
    assert :ok = Exfuse.unmount(path)
    assert Elixir.File.dir?(path)
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
