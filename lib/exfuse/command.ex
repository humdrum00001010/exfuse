defmodule Exfuse.Command do
  @moduledoc false

  @shutdown_grace_ms 1_000

  @type result :: {binary(), non_neg_integer()} | {:timeout, binary()} | {:error, term()}

  @spec run(String.t(), [String.t()], non_neg_integer()) :: result()
  def run(command, args, timeout)
      when is_binary(command) and is_list(args) and is_integer(timeout) and timeout >= 0 do
    caller = self()
    reply_ref = make_ref()

    {worker, monitor} =
      spawn_monitor(fn ->
        run_worker(caller, reply_ref, command, args, timeout)
      end)

    receive do
      {^reply_ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^worker, reason} ->
        {:error, {:command_worker_exit, reason}}
    after
      timeout + @shutdown_grace_ms ->
        Process.exit(worker, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
        after
          100 -> Process.demonitor(monitor, [:flush])
        end

        flush_reply(reply_ref)
        {:timeout, ""}
    end
  end

  defp run_worker(caller, reply_ref, command, args, timeout) do
    caller_monitor = Process.monitor(caller)

    case run_owned(command, args, timeout, caller, caller_monitor) do
      :caller_down ->
        :ok

      result ->
        Process.demonitor(caller_monitor, [:flush])
        send(caller, {reply_ref, result})
    end
  end

  defp run_owned(command, args, timeout, caller, caller_monitor) do
    executable =
      case Path.type(command) do
        :absolute -> command
        _ -> System.find_executable(command) || command
      end

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, args}
      ])

    collect(port, [], System.monotonic_time(:millisecond) + timeout, caller, caller_monitor)
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp collect(port, chunks, deadline, caller, caller_monitor) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect(port, [data | chunks], deadline, caller, caller_monitor)

      {^port, {:exit_status, status}} ->
        {chunks |> Enum.reverse() |> IO.iodata_to_binary(), status}

      {:DOWN, ^caller_monitor, :process, ^caller, _reason} ->
        close(port)
        :caller_down
    after
      remaining ->
        close(port)
        {:timeout, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
    end
  end

  defp close(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        _ = System.cmd("kill", [Integer.to_string(pid)], stderr_to_stdout: true)

      _ ->
        :ok
    end

    Port.close(port)
  rescue
    ArgumentError -> :ok
  catch
    :error, :badarg -> :ok
  end

  defp flush_reply(reply_ref) do
    receive do
      {^reply_ref, _result} -> :ok
    after
      0 -> :ok
    end
  end
end
