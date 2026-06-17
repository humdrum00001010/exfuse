defmodule Exfuse.FsDslTest do
  use ExUnit.Case
  alias Exfuse.Socket

  @attr_dir 1
  @attr_file 2
  @error_noent 2

  defmodule SampleFs do
    use Exfuse.Fs

    init do
      %{mount_point: mount_point, opts: opts, reads: 0}
    end

    readdir "/" do
      {:reply, ["docx", "latest"], socket}
    end

    getattr "/" do
      {:reply, dir(), socket}
    end

    getattr "/docx/:file" do
      {:reply, file(size: byte_size(file)), socket}
    end

    getattr "/meta" do
      {:reply, %{type: :file, mode: 0o600, size: 4}, socket}
    end

    read "/docx/special" do
      {:reply, "special:#{state.reads}", put_state(socket, %{state | reads: state.reads + 1})}
    end

    read "/docx/:file" do
      {:reply, "file=#{file};mount=#{state.mount_point}", socket}
    end

    read "/ctx/:file" do
      {:reply, "file=#{file};uid=#{event.uid};path=#{event.path}", socket}
    end

    read "/docx/*path" do
      {:reply, Enum.join(path, "/"), socket}
    end

    read "/tmp/*" do
      {:reply, "tmp", socket}
    end

    readlink "/latest" do
      {:reply, "/docx/special", socket}
    end

    open "/docx/:file" do
      {:reply, {:opened, file, event.flags}, socket}
    end

    write "/docx/:file" do
      _ = file
      {:reply, byte_size(event.data), socket}
    end
  end

  defmodule DefaultInitFs do
    use Exfuse.Fs

    read "/hello" do
      {:reply, "hello", socket}
    end
  end

  defmodule PlugEndpoint do
    def handle_event(:getattr, %{params: %{file: file}}, socket) do
      {:reply, %{type: :file, mode: 0o600, size: byte_size(file)}, socket}
    end

    def handle_event(:read, %{params: %{file: file}, path: path}, socket) do
      {:reply, "file=#{file};path=#{path}", socket}
    end

    def handle_event(:read, %{params: %{path: path}}, socket) do
      {:reply, Enum.join(path, "/"), socket}
    end

    def handle_event(:write, %{params: %{file: file}, data: data}, socket) do
      {:reply, byte_size(file <> data), socket}
    end

    def handle_event(_op, _event, socket), do: {:error, :enoent, socket}
  end

  defmodule PlugFs do
    use Exfuse.Fs

    read "/plug/special" do
      {:reply, "local", socket}
    end

    plug("/plug/:file", Exfuse.FsDslTest.PlugEndpoint)
    plug("/tree/*path", Exfuse.FsDslTest.PlugEndpoint)
  end

  defmodule ProcessEndpoint do
    def init(socket) do
      send(socket.state.owner, {:plug_init, self()})
      {:ok, Exfuse.Socket.assign(socket, :count, 0)}
    end

    def handle_event(:read, %{params: %{file: file}}, socket) do
      count = Exfuse.Socket.get_assign(socket, :count, 0)
      send(socket.state.owner, {:plug_event, self(), file, count})
      {:reply, "#{file}:#{count}", Exfuse.Socket.assign(socket, :count, count + 1)}
    end

    def handle_event(_op, _event, socket), do: {:error, :enoent, socket}
  end

  defmodule ProcessPlugFs do
    use Exfuse.Fs

    plug("/process/:file", Exfuse.FsDslTest.ProcessEndpoint)
  end

  describe "route DSL" do
    test "generates init from init block" do
      assert {:ok, %{mount_point: "/mnt", opts: [answer: 42], reads: 0}} =
               SampleFs.exfuse_init("/mnt", answer: 42)
    end

    test "uses mount opts as default state when no init block is provided" do
      assert {:ok, [answer: 42]} = DefaultInitFs.exfuse_init("/mnt", answer: 42)
    end

    test "matches root routes" do
      state = state()
      assert_ok(SampleFs, :readdir, "/", state, ["docx", "latest"], state)
      assert_ok(SampleFs, :getattr, "/", state, {0o0755, @attr_dir, 0}, state)
    end

    test "binds named path segments" do
      state = state()

      assert_ok(SampleFs, :getattr, "/docx/report", state, {0o0644, @attr_file, 6}, state)
      assert_ok(SampleFs, :read, "/docx/report", state, "file=report;mount=/mnt", state)
    end

    test "keeps route params local to the endpoint" do
      state = state()
      socket = Socket.new("/mnt", state)

      event = %{path: "/ctx/report", uid: 501}

      assert {:reply, "file=report;uid=501;path=/ctx/report", result} =
               SampleFs.handle_event(:read, event, socket)

      refute Map.has_key?(Map.from_struct(result), :params)
    end

    test "normalizes getattr maps" do
      state = state()
      assert_ok(SampleFs, :getattr, "/meta", state, {0o600, @attr_file, 4}, state)
    end

    test "matches exact routes before broader routes" do
      state = state()

      assert {:reply, "special:0", %Socket{state: %{reads: 1}}} =
               dispatch(SampleFs, :read, "/docx/special", state)
    end

    test "binds named glob tails as segment lists" do
      state = state()

      assert_ok(SampleFs, :read, "/docx/deep/file.txt", state, "deep/file.txt", state)
    end

    test "matches unnamed glob tails" do
      state = state()

      assert_ok(SampleFs, :read, "/tmp/a/b", state, "tmp", state)
    end

    test "normalizes readlink routes" do
      state = state()

      assert_ok(SampleFs, :readlink, "/latest", state, "/docx/special", state)
    end

    test "routes fine-grained file ops" do
      state = state()

      assert {:reply, {:opened, "report", 2}, %Socket{}} =
               dispatch(SampleFs, :open, "/docx/report", state, %{flags: 2})

      assert {:reply, 3, %Socket{}} =
               dispatch(SampleFs, :write, "/docx/report", state, %{data: "abc"})
    end

    test "delegates matching packets to plug modules" do
      state = state()

      assert {:reply, "file=report;path=/plug/report", %Socket{} = socket} =
               dispatch(PlugFs, :read, "/plug/report", state)

      refute Map.has_key?(Map.from_struct(socket), :params)

      assert {:reply, {0o600, @attr_file, 6}, %Socket{}} =
               dispatch(PlugFs, :getattr, "/plug/report", state)

      assert {:reply, 9, %Socket{}} =
               dispatch(PlugFs, :write, "/plug/report", state, %{data: "abc"})
    end

    test "plug modules receive glob params" do
      assert {:reply, "deep/file.txt", %Socket{}} =
               dispatch(PlugFs, :read, "/tree/deep/file.txt", state())
    end

    test "plug modules run as endpoint processes keyed by params" do
      state = Map.put(state(), :owner, self())
      socket = Socket.new("/mnt", state)

      assert {:reply, "a:0", socket} =
               ProcessPlugFs.handle_event(:read, %{path: "/process/a"}, socket)

      assert_receive {:plug_init, pid_a}
      assert_receive {:plug_event, ^pid_a, "a", 0}
      refute pid_a == self()
      refute Map.has_key?(socket.assigns, :count)

      assert {:reply, "a:1", socket} =
               ProcessPlugFs.handle_event(:read, %{path: "/process/a"}, socket)

      assert_receive {:plug_event, ^pid_a, "a", 1}
      refute_receive {:plug_init, _pid}, 50

      assert {:reply, "b:0", _socket} =
               ProcessPlugFs.handle_event(:read, %{path: "/process/b"}, socket)

      assert_receive {:plug_init, pid_b}
      assert_receive {:plug_event, ^pid_b, "b", 0}
      refute pid_b == pid_a
    end

    test "routes before plug modules keep precedence" do
      assert {:reply, "local", %Socket{}} =
               dispatch(PlugFs, :read, "/plug/special", state())
    end

    test "falls back to enoent for unmatched routes" do
      state = state()

      assert {:error, @error_noent, %Socket{state: ^state}} =
               dispatch(SampleFs, :read, "/missing", state)

      assert {:error, @error_noent, %Socket{state: ^state}} =
               dispatch(DefaultInitFs, :getattr, "/hello", state)
    end
  end

  defp assert_ok(fs, op, path, state, response, expected_state) do
    assert {:reply, ^response, %Socket{state: ^expected_state}} =
             dispatch(fs, op, path, state)
  end

  defp dispatch(fs, op, path, state, attrs \\ %{}) do
    fs.handle_event(op, Map.put(attrs, :path, path), Socket.new("/mnt", state))
  end

  defp state do
    %{mount_point: "/mnt", opts: [], reads: 0}
  end
end
