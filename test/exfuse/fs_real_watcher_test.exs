defmodule Exfuse.FsRealWatcherTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  defmodule RestartFailureFs do
    @behaviour Exfuse.Fs

    def exfuse_init(opts) do
      {:ok, state} = Exfuse.Fs.Real.exfuse_init(opts)
      {:ok, Map.put(state, :watcher_mode, Keyword.fetch!(opts, :watcher_mode))}
    end

    def handle_event(operation, event, socket),
      do: Exfuse.Fs.Real.handle_event(operation, event, socket)

    def watcher(%{watcher_mode: watcher_mode} = state) do
      case Agent.get(watcher_mode, & &1) do
        :running -> Exfuse.Fs.Real.watcher(state)
        :fail -> {:ok, backend: :missing_backend, dirs: [state.root]}
      end
    end

    def event_path(state, host_path),
      do: Exfuse.Fs.Real.event_path(state, host_path)
  end

  test "an external host write reaches direct subscribers with a relative path" do
    root = tmp_root()
    {:ok, fs} = Exfuse.start_fs(Exfuse.Fs.Real, root: root)
    on_exit(fn -> Exfuse.stop_fs(fs) end)

    assert :ok = Exfuse.Fs.subscribe(fs)
    File.write!(Path.join(root, "external.md"), "outside")

    assert_receive {:file_event, ^fs, {"/external.md", actions}}, 2_000
    assert Enum.any?(actions, &(&1 in [:created, :modified, :renamed]))
  end

  test "stopping the filesystem stops its native watcher" do
    root = tmp_root()
    {:ok, fs} = Exfuse.start_fs(Exfuse.Fs.Real, root: root)

    watcher = Exfuse.Fs.Supervisor.status(fs).watcher
    assert is_pid(watcher)
    reference = Process.monitor(watcher)

    assert :ok = Exfuse.stop_fs(fs)
    assert_receive {:DOWN, ^reference, :process, ^watcher, _reason}
  end

  test "a stopped native watcher is replaced without losing subscribers" do
    root = tmp_root()
    {:ok, fs} = Exfuse.start_fs(Exfuse.Fs.Real, root: root)
    on_exit(fn -> Exfuse.stop_fs(fs) end)
    :ok = Exfuse.Fs.subscribe(fs)

    runtime = Exfuse.Fs.Supervisor.runtime(fs)
    first = Exfuse.Fs.Supervisor.status(fs).watcher
    send(runtime, {:file_event, first, :stop})

    assert_receive {:file_event, ^fs, :stop}
    _ = :sys.get_state(runtime)

    second = Exfuse.Fs.Supervisor.status(fs).watcher
    assert is_pid(second)
    refute second == first

    File.write!(Path.join(root, "after-restart.md"), "outside")
    assert_receive {:file_event, ^fs, {"/after-restart.md", _actions}}, 2_000
  end

  test "watcher restart failure leaves operations available and appears in status" do
    root = tmp_root()
    watcher_mode = start_supervised!({Agent, fn -> :running end})

    {:ok, fs} =
      Exfuse.start_fs(RestartFailureFs,
        root: root,
        watcher_mode: watcher_mode
      )

    on_exit(fn -> Exfuse.stop_fs(fs) end)
    runtime = Exfuse.Fs.Supervisor.runtime(fs)
    first = Exfuse.Fs.Supervisor.status(fs).watcher

    log =
      capture_log(fn ->
        Agent.update(watcher_mode, fn _ -> :fail end)
        send(runtime, {:file_event, first, :stop})
        _ = :sys.get_state(runtime)
      end)

    status = Exfuse.Fs.Supervisor.status(fs)
    assert status.watcher == nil
    assert status.watcher_error == :watcher_ignored
    assert {:ok, []} = Exfuse.Fs.list(fs, "/")

    send(runtime, {:file_event, first, {Path.join(root, "late-probe"), [:created]}})
    _ = :sys.get_state(runtime)
    assert {:ok, []} = Exfuse.Fs.list(fs, "/")

    assert log =~ "Not able to start file_system worker"
    assert log =~ "Exfuse filesystem watcher restart failed"
  end

  defp tmp_root do
    path =
      Path.join(
        System.tmp_dir!(),
        "exfuse-watcher-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
