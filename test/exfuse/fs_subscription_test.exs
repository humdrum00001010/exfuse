defmodule Exfuse.FsSubscriptionTest do
  use ExUnit.Case, async: false

  setup do
    {:ok, fs} = Exfuse.start_fs(Exfuse.Fs.Memory, files: %{})
    on_exit(fn -> Exfuse.stop_fs(fs) end)
    {:ok, fs: fs}
  end

  test "a mutation is visible before its event", %{fs: fs} do
    assert :ok = Exfuse.Fs.subscribe(fs)
    assert :ok = Exfuse.Fs.write(fs, "/a.md", "hello")

    assert_receive {:file_event, ^fs, {"/a.md", actions}}
    assert :created in actions
    assert :modified in actions
    assert {:ok, "hello"} = Exfuse.Fs.read(fs, "/a.md")
  end

  test "fans out to multiple subscribers and removes a dead subscriber", %{fs: fs} do
    parent = self()

    subscriber =
      spawn(fn ->
        :ok = Exfuse.Fs.subscribe(fs)
        send(parent, {:subscribed, self()})
        forward_events(parent)
      end)

    assert_receive {:subscribed, ^subscriber}
    :ok = Exfuse.Fs.subscribe(fs)

    assert :ok = Exfuse.Fs.write(fs, "/a.md", "hello")
    assert_receive {:file_event, ^fs, {"/a.md", _actions}}
    assert_receive {:forwarded, {:file_event, ^fs, {"/a.md", _actions}}}

    reference = Process.monitor(subscriber)
    Process.exit(subscriber, :kill)
    assert_receive {:DOWN, ^reference, :process, ^subscriber, :killed}
    _ = :sys.get_state(Exfuse.Fs.Supervisor.runtime(fs))

    assert :ok = Exfuse.Fs.write(fs, "/b.md", "hello")
    assert_receive {:file_event, ^fs, {"/b.md", _actions}}
    refute_receive {:forwarded, {:file_event, ^fs, {"/b.md", _actions}}}

    status = Exfuse.Fs.Supervisor.status(fs)
    refute subscriber in status.subscribers
  end

  test "stopping the filesystem notifies subscribers", %{fs: fs} do
    :ok = Exfuse.Fs.subscribe(fs)
    :ok = Exfuse.stop_fs(fs)
    assert_receive {:file_event, ^fs, :stop}
  end

  defp forward_events(parent) do
    receive do
      :stop ->
        :ok

      event ->
        send(parent, {:forwarded, event})
        forward_events(parent)
    end
  end
end
