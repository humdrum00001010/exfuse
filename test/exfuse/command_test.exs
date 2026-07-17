defmodule Exfuse.CommandTest do
  use ExUnit.Case, async: true

  alias Exfuse.Command

  test "returns command output and exit status" do
    assert {"hello", 0} = Command.run("/bin/sh", ["-c", "printf hello"], 1_000)
  end

  test "timed out commands cannot leak raw port messages to their caller" do
    yes = System.find_executable("yes") || flunk("yes executable is required")

    for _attempt <- 1..5 do
      assert {:timeout, _output} = Command.run(yes, ["x"], 2)
    end

    refute_receive {_port, {:data, _data}}, 100
    refute_receive {_port, {:exit_status, _status}}, 100
  end

  test "the command and its worker stop when the caller dies" do
    pid_path =
      Path.join(
        System.tmp_dir!(),
        "exfuse-command-#{System.unique_integer([:positive, :monotonic])}.pid"
      )

    parent = self()

    caller =
      spawn(fn ->
        result =
          Command.run(
            "/bin/sh",
            ["-c", ~S|printf '%s' $$ > "$1"; exec sleep 10|, "exfuse-command", pid_path],
            15_000
          )

        send(parent, {:command_returned, result})
      end)

    assert {:ok, os_pid} = wait_for_os_pid(pid_path, 100)

    on_exit(fn ->
      _ = System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
      File.rm(pid_path)
    end)

    caller_monitor = Process.monitor(caller)
    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}, 1_000
    assert wait_until(fn -> not os_process_alive?(os_pid) end, 100)
    refute_receive {:command_returned, _result}
  end

  test "reports an executable launch failure" do
    assert {:error, _reason} = Command.run("/path/that/does/not/exist", [], 100)
  end

  defp wait_for_os_pid(_path, 0), do: {:error, :timeout}

  defp wait_for_os_pid(path, attempts) do
    case File.read(path) do
      {:ok, contents} ->
        case Integer.parse(String.trim(contents)) do
          {pid, ""} -> {:ok, pid}
          _other -> wait_and_retry(fn -> wait_for_os_pid(path, attempts - 1) end)
        end

      {:error, _reason} ->
        wait_and_retry(fn -> wait_for_os_pid(path, attempts - 1) end)
    end
  end

  defp wait_until(_condition, 0), do: false

  defp wait_until(condition, attempts) do
    if condition.() do
      true
    else
      wait_and_retry(fn -> wait_until(condition, attempts - 1) end)
    end
  end

  defp wait_and_retry(fun) do
    receive do
    after
      10 -> fun.()
    end
  end

  defp os_process_alive?(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end
end
