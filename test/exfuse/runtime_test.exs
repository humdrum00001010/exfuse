defmodule Exfuse.RuntimeTest do
  use ExUnit.Case, async: false

  alias Exfuse.{File, Socket}

  defmodule ConcurrentFs do
    @behaviour Exfuse.Fs

    def exfuse_init(owner), do: {:ok, %{owner: owner, writes: 0}}

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

    def handle_event(_operation, _event, socket), do: {:error, :enoent, socket}
  end

  setup do
    {:ok, fs} = Exfuse.start_fs(ConcurrentFs, self(), max_concurrency: 2)
    {:ok, file} = Exfuse.Fs.Runtime.root(fs)
    on_exit(fn -> if Process.alive?(fs), do: Exfuse.stop_fs(fs) end)
    %{root_file: file}
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
end
