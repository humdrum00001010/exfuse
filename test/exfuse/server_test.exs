defmodule Exfuse.ServerTest do
  use ExUnit.Case
  use Exfuse.Fs, attribs: true
  import ExUnit.CaptureLog

  @moduletag :fuse

  describe "server" do
    setup do
      mp = tmp_mount("server")
      System.cmd("mkdir", ["-p", mp])

      {:ok, pid} = Exfuse.mount(mp, TestFs, this: 2, that: 3)

      on_exit(fn -> cleanup_mount(mp) end)
      {:ok, %{fs_pid: pid, mp: mp}}
    end

    test "status returns mp, mod, state and port PID", %{fs_pid: fs_pid, mp: mp} do
      assert {^mp, TestFs, {^mp, [this: 2, that: 3]}, port_os_pid} =
               Exfuse.Server.status(fs_pid)

      assert is_integer(port_os_pid)
    end

    test "stops on demand and not respanwed", %{fs_pid: fs_pid} do
      assert length(Exfuse.list()) == 1
      Exfuse.Server.stop(fs_pid)
      assert_eventually(fn -> length(Exfuse.list()) == 0 end)
    end

    test "unmounts and kills port when stop requested", %{fs_pid: fs_pid, mp: mp} do
      {^mp, TestFs, {^mp, [this: 2, that: 3]}, port_os_pid} = Exfuse.Server.status(fs_pid)

      assert :ok = Exfuse.Server.stop(fs_pid)
      assert_eventually(fn -> not port_alive?(port_os_pid) end)
      assert_eventually(fn -> not mounted?(mp) end)
    end

    test "stops on OS port kill (term) and not respanwed", %{fs_pid: fs_pid, mp: mp} do
      {^mp, TestFs, {^mp, [this: 2, that: 3]}, port_os_pid} = Exfuse.Server.status(fs_pid)
      assert length(Exfuse.list()) == 1
      System.cmd("kill", ["#{port_os_pid}"])
      assert_eventually(fn -> length(Exfuse.list()) == 0 end)
    end

    test "logs error when receiving unknown port requests" do
      log =
        capture_log(fn ->
          Exfuse.Server.handle_info(
            {self(), {:data, <<@magiccookie::size(32), 1, 2, 3, 4, 5, 6, 7, 8, 9, 0>>}},
            %Exfuse.Server{
              mount_point: "/tmp/testfs",
              fs_mod: TestFs,
              phase: :ready,
              port: self(),
              port_os_pid: 12345
            }
          )
        end)

      assert log =~ "unrecognised data"
    end

    test "does not die when receiving unknown port requests", %{fs_pid: fs_pid} do
      capture_log(fn ->
        Exfuse.Server.handle_info(
          {self(), {:data, <<@magiccookie::size(32), 1, 2, 3, 4, 5, 6, 7, 8, 9, 0>>}},
          %Exfuse.Server{
            mount_point: "/tmp/testfs",
            fs_mod: TestFs,
            phase: :ready,
            port: self(),
            port_os_pid: 12345
          }
        )

        Process.sleep(200)
        assert Process.alive?(fs_pid)
      end)
    end

    test "logs error when receiving a bad port request (without correct magic cookie)" do
      log =
        capture_log(fn ->
          Exfuse.Server.handle_info(
            {self(), {:data, <<123, @magiccookie::size(32), 1, 2, 3, 4, 5, 6, 7, 8, 9, 0>>}},
            %Exfuse.Server{
              mount_point: "/tmp/testfs",
              fs_mod: TestFs,
              phase: :ready,
              port: self(),
              port_os_pid: nil
            }
          )

          assert_receive {:slow_stop, _reason}, 200
        end)

      assert log =~ "received without correct cookie"
    end

    test "dies when receiving a bad port request (without correct magic cookie)", %{
      fs_pid: fs_pid
    } do
      capture_log(fn ->
        port = :sys.get_state(fs_pid).port

        send(
          fs_pid,
          {port, {:data, <<123, @magiccookie::size(32), 1, 2, 3, 4, 5, 6, 7, 8, 9, 0>>}}
        )

        Process.sleep(300)
        refute Process.alive?(fs_pid)
      end)
    end

    test "dies and respawns when receiving an unhandled message (normal crash)", %{
      fs_pid: fs_pid,
      mp: mp
    } do
      capture_log(fn ->
        send(fs_pid, :evil_msg)
        Process.sleep(300)
        refute Process.alive?(fs_pid)
        [{next_fs_pid, {^mp, TestFs, {^mp, _fs_state}, _port_os_pid}}] = Exfuse.list()
        assert Process.alive?(next_fs_pid)
      end)
    end
  end

  defp tmp_mount(prefix) do
    Path.join(
      "/tmp/exfuse-runs",
      "#{prefix}-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive, :monotonic])}"
    )
  end

  defp cleanup_mount(mp) do
    Exfuse.umount(mp)
    wait_until(fn -> not mounted?(mp) end)

    if mounted?(mp) do
      force_unmount(mp)
    end

    File.rmdir(mp)
    :ok
  end

  defp force_unmount(mp) do
    System.cmd("umount", [mp], stderr_to_stdout: true)

    if mounted?(mp) do
      with diskutil when is_binary(diskutil) <- System.find_executable("diskutil") do
        System.cmd(diskutil, ["unmount", "force", mp], stderr_to_stdout: true)
      end
    end
  end

  defp port_alive?(pid) do
    case System.cmd("kill", ["-0", "#{pid}"], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp mounted?(mp) do
    paths = [mp, realpath(mp)] |> Enum.reject(&is_nil/1)

    case System.cmd("mount", [], stderr_to_stdout: true) do
      {mounts, 0} -> Enum.any?(paths, &String.contains?(mounts, " on #{&1} "))
      _ -> false
    end
  end

  defp realpath(path) do
    case :file.read_link_all(String.to_charlist(path)) do
      {:ok, path} -> List.to_string(path)
      {:error, _reason} -> nil
    end
  end

  defp assert_eventually(fun), do: assert(wait_until(fun))

  defp wait_until(fun) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    wait_until(fun, deadline)
  end

  defp wait_until(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(20)
        wait_until(fun, deadline)

      true ->
        false
    end
  end
end
