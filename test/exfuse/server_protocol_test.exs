defmodule Exfuse.ServerProtocolTest do
  use ExUnit.Case
  use Exfuse.Fs, attribs: true

  defmodule WriteFs do
    alias Exfuse.Socket

    def handle_event(:write, %{path: "/file", offset: 5, data: "abc"}, socket) do
      {:reply, 3, Socket.put_state(socket, :written)}
    end
  end

  defmodule SocketWriteFs do
    alias Exfuse.Socket

    def handle_event(:write, %{path: "/file", handle: 101, offset: 5, data: "abc"}, socket) do
      {:reply, 3, Socket.put_state(socket, :socket_written)}
    end
  end

  defmodule ReadOnlyFs do
    def handle_event(_op, _event, socket), do: {:error, :enosys, socket}
  end

  defmodule FineGrainedFs do
    alias Exfuse.Socket

    def handle_event(:open, %{path: "/file", flags: 2}, socket),
      do: {:noreply, Socket.put_state(socket, :opened)}

    def handle_event(:create, %{path: "/created", mode: 0o0644, flags: 2}, socket),
      do: {:noreply, Socket.put_state(socket, :created)}

    def handle_event(:truncate, %{path: "/file", size: 3}, socket),
      do: {:noreply, Socket.put_state(socket, :truncated)}

    def handle_event(:unlink, %{path: "/file"}, socket),
      do: {:noreply, Socket.put_state(socket, :unlinked)}

    def handle_event(:rename, %{path: "/old", target: "/new"}, socket),
      do: {:noreply, Socket.put_state(socket, :renamed)}

    def handle_event(:mkdir, %{path: "/dir", mode: 0o0755}, socket),
      do: {:noreply, Socket.put_state(socket, :made_dir)}

    def handle_event(:rmdir, %{path: "/dir"}, socket),
      do: {:noreply, Socket.put_state(socket, :removed_dir)}

    def handle_event(:chmod, %{path: "/file", mode: 0o0600}, socket),
      do: {:noreply, Socket.put_state(socket, :chmodded)}

    def handle_event(:chown, %{path: "/file", owner_uid: 501, owner_gid: 20}, socket),
      do: {:noreply, Socket.put_state(socket, :chowned)}

    def handle_event(:flush, %{path: "/file", flags: 2, handle: 101}, socket),
      do: {:noreply, Socket.put_state(socket, :flushed)}

    def handle_event(:release, %{path: "/file", flags: 2, handle: 101}, socket),
      do: {:noreply, Socket.put_state(socket, :released)}

    def handle_event(:fsync, %{path: "/file", datasync: false, flags: 2, handle: 101}, socket),
      do: {:noreply, Socket.put_state(socket, :synced)}
  end

  defmodule SocketFs do
    alias Exfuse.Socket

    def handle_event(
          :read,
          %{
            path: "/ctx",
            uid: 501,
            gid: 20,
            pid: 12_345,
            umask: 0o022,
            handle: 101,
            offset: 2,
            size: 3
          },
          %Socket{state: :state} = socket
        ) do
      {:reply, "ctx", Socket.put_state(socket, :seen)}
    end

    def handle_event(_op, _event, socket), do: {:error, :enoent, socket}
  end

  test "dispatches handle_event requests with caller context" do
    port = open_echo_port()
    on_exit(fn -> close_port(port) end)

    request =
      <<@magiccookie::32, @request_read::32, ctx()::binary,
        read_payload("/ctx", 0, 101, 2, 3)::binary>>

    assert {:noreply, state} =
             Exfuse.Server.handle_info(
               {port, {:data, request}},
               server_state(SocketFs, port)
             )

    assert state.fs_state == :seen
    assert_receive {^port, {:data, <<@magiccookie::32, @request_read::32, 0::32, "ctx">>}}
  end

  test "dispatches framed wire packets without an Erlang Port reply target" do
    port = open_echo_port()
    on_exit(fn -> close_port(port) end)

    request =
      <<@magiccookie::32, @request_read::32, ctx()::binary,
        read_payload("/ctx", 0, 101, 2, 3)::binary>>

    ref = make_ref()

    assert {:noreply, state} =
             Exfuse.Server.handle_call(
               {:wire_packet, request},
               {self(), ref},
               server_state(SocketFs, port)
             )

    assert state.fs_state == :seen
    assert_receive {^ref, <<@magiccookie::32, @request_read::32, 0::32, "ctx">>}
  end

  test "dispatches write requests" do
    port = open_echo_port()
    on_exit(fn -> close_port(port) end)

    path = "/file"
    data = "abc"

    request =
      <<@magiccookie::32, @request_write::32, ctx()::binary, 101::64, 5::64, byte_size(path)::32,
        path::binary, data::binary>>

    assert {:noreply, state} =
             Exfuse.Server.handle_info(
               {port, {:data, request}},
               server_state(WriteFs, port)
             )

    assert state.fs_state == :written
    assert_receive {^port, {:data, <<@magiccookie::32, @request_write::32, 0::32, 3::32>>}}
  end

  test "dispatches handle_event write requests with handle" do
    port = open_echo_port()
    on_exit(fn -> close_port(port) end)

    path = "/file"
    data = "abc"

    request =
      <<@magiccookie::32, @request_write::32, ctx()::binary, 101::64, 5::64, byte_size(path)::32,
        path::binary, data::binary>>

    assert {:noreply, state} =
             Exfuse.Server.handle_info(
               {port, {:data, request}},
               server_state(SocketWriteFs, port)
             )

    assert state.fs_state == :socket_written
    assert_receive {^port, {:data, <<@magiccookie::32, @request_write::32, 0::32, 3::32>>}}
  end

  test "returns enosys when write callback is absent" do
    port = open_echo_port()
    on_exit(fn -> close_port(port) end)

    path = "/file"

    request =
      <<@magiccookie::32, @request_write::32, ctx()::binary, 0::64, 0::64, byte_size(path)::32,
        path::binary>>

    assert {:noreply, state} =
             Exfuse.Server.handle_info(
               {port, {:data, request}},
               server_state(ReadOnlyFs, port)
             )

    assert state.fs_state == :state
    assert_receive {^port, {:data, <<@magiccookie::32, @request_write::32, @error_nosys::32>>}}
  end

  describe "desired fine-grained requests" do
    test "dispatches open requests" do
      assert_dispatch(@request_open, path_u32_payload("/file", 2), :opened)
    end

    test "dispatches create requests" do
      assert_dispatch(
        @request_create,
        <<0o0644::32, 2::32, path_payload("/created")::binary>>,
        :created
      )
    end

    test "dispatches truncate requests" do
      assert_dispatch(@request_truncate, <<3::64, path_payload("/file")::binary>>, :truncated)
    end

    test "dispatches unlink requests" do
      assert_dispatch(@request_unlink, "/file", :unlinked)
    end

    test "dispatches rename requests" do
      old = "/old"

      assert_dispatch(
        @request_rename,
        <<0::32, path_payload(old)::binary, path_payload("/new")::binary>>,
        :renamed
      )
    end

    test "dispatches mkdir requests" do
      assert_dispatch(@request_mkdir, path_u32_payload("/dir", 0o0755), :made_dir)
    end

    test "dispatches rmdir requests" do
      assert_dispatch(@request_rmdir, "/dir", :removed_dir)
    end

    test "dispatches chmod requests" do
      assert_dispatch(@request_chmod, path_u32_payload("/file", 0o0600), :chmodded)
    end

    test "dispatches chown requests" do
      assert_dispatch(
        @request_chown,
        <<501::32, 20::32, path_payload("/file")::binary>>,
        :chowned
      )
    end

    test "dispatches flush requests" do
      assert_dispatch(@request_flush, path_handle_payload("/file", 2, 101), :flushed)
    end

    test "dispatches release requests" do
      assert_dispatch(@request_release, path_handle_payload("/file", 2, 101), :released)
    end

    test "dispatches fsync requests" do
      assert_dispatch(
        @request_fsync,
        <<0::32, 2::32, 101::64, path_payload("/file")::binary>>,
        :synced
      )
    end
  end

  defp path_payload(path), do: <<byte_size(path)::32, path::binary>>
  defp path_u32_payload(path, value), do: <<value::32, path_payload(path)::binary>>

  defp path_handle_payload(path, flags, handle),
    do: <<flags::32, handle::64, path_payload(path)::binary>>

  defp read_payload(path, flags, handle, offset, size),
    do: <<flags::32, handle::64, offset::64, size::64, path_payload(path)::binary>>

  defp ctx, do: <<501::32, 20::32, 12_345::32, 0o022::32>>

  defp server_state(fs_mod, port, fs_state \\ :state) do
    %Exfuse.Server{
      fs_mod: fs_mod,
      fs_state: fs_state,
      socket: Exfuse.Socket.new("/mnt", fs_state),
      port: port
    }
  end

  defp assert_dispatch(code, payload, expected_state) do
    port = open_echo_port()
    on_exit(fn -> close_port(port) end)

    request = <<@magiccookie::32, code::32, ctx()::binary, payload::binary>>

    assert {:noreply, state} =
             Exfuse.Server.handle_info(
               {port, {:data, request}},
               server_state(FineGrainedFs, port)
             )

    assert state.fs_state == expected_state
    assert_receive {^port, {:data, <<@magiccookie::32, ^code::32, 0::32>>}}, 100
  end

  defp open_echo_port do
    cat = System.find_executable("cat")
    Port.open({:spawn_executable, cat}, [{:packet, 4}, :binary])
  end

  defp close_port(port) do
    Port.close(port)
  catch
    :error, :badarg -> :ok
  end
end
