defmodule Exfuse.File do
  @moduledoc """
  Persistent callback process for one filesystem or `plug` declaration.

  Read operations execute concurrently from an immutable socket snapshot.
  Stateful operations execute in arrival order after earlier reads finish.
  """

  use GenServer
  require Logger

  alias Exfuse.Socket

  @read_operations [:readdir, :getattr, :readlink, :read]

  defstruct key: nil,
            module: nil,
            socket: nil,
            max_concurrency: 8,
            queue_limit: 128,
            active: %{},
            writer: nil,
            queue: :queue.new(),
            queue_size: 0

  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @spec dispatch(pid, Exfuse.Fs.operation(), map) :: Exfuse.Fs.event_result()
  def dispatch(file, operation, event) do
    GenServer.call(file, {:dispatch, operation, event}, :infinity)
  end

  def dispatch_request({_id, operation, _code}, file, event),
    do: dispatch(file, operation, event)

  @spec snapshot(pid) :: Socket.t()
  def snapshot(file), do: GenServer.call(file, :snapshot)

  @impl true
  def init(options) do
    module = Keyword.fetch!(options, :module)
    init_arg = Keyword.fetch!(options, :init_arg)
    runtime = Keyword.fetch!(options, :runtime)

    with {:ok, callback_state} <- initialize(module, init_arg) do
      max_concurrency = positive_option(options, :max_concurrency, System.schedulers_online())
      queue_limit = positive_option(options, :queue_limit, max_concurrency * 16)

      {:ok,
       %__MODULE__{
         key: Keyword.fetch!(options, :key),
         module: module,
         socket: Socket.new(runtime, callback_state),
         max_concurrency: max_concurrency,
         queue_limit: queue_limit
       }}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state.socket, state}

  def handle_call({:dispatch, operation, event}, from, state) do
    kind = if operation in @read_operations, do: :read, else: :write
    request = %{from: from, operation: operation, event: event, kind: kind}

    cond do
      runnable?(state, request) ->
        {:noreply, start_request(state, request)}

      state.queue_size < state.queue_limit ->
        {:noreply,
         %{state | queue: :queue.in(request, state.queue), queue_size: state.queue_size + 1}}

      true ->
        {:reply, {:error, :ebusy, state.socket}, state}
    end
  end

  @impl true
  def handle_info({reference, result}, state) when is_reference(reference) do
    case Map.pop(state.active, reference) do
      {nil, _active} ->
        {:noreply, state}

      {request, active} ->
        Process.demonitor(reference, [:flush])
        state = %{state | active: active, writer: clear_writer(state.writer, reference)}
        state = complete_request(state, request, result)
        {:noreply, drain(state)}
    end
  end

  def handle_info({:DOWN, reference, :process, _pid, reason}, state) do
    case Map.pop(state.active, reference) do
      {nil, _active} ->
        {:noreply, state}

      {request, active} ->
        Logger.error("Exfuse File callback crashed",
          operation: request.operation,
          reason: inspect(reason)
        )

        GenServer.reply(request.from, {:error, :eio, state.socket})

        state = %{state | active: active, writer: clear_writer(state.writer, reference)}
        {:noreply, drain(state)}
    end
  end

  defp initialize(module, init_arg) do
    if function_exported?(module, :exfuse_init, 1) do
      case module.exfuse_init(init_arg) do
        {:ok, state} -> {:ok, state}
        {:error, _reason} = error -> error
        other -> {:error, {:bad_init_return, other}}
      end
    else
      {:ok, init_arg}
    end
  end

  defp runnable?(state, %{kind: :read}) do
    is_nil(state.writer) and state.queue_size == 0 and
      map_size(state.active) < state.max_concurrency
  end

  defp runnable?(state, %{kind: :write}) do
    is_nil(state.writer) and state.queue_size == 0 and map_size(state.active) == 0
  end

  defp start_request(state, request) do
    module = state.module
    socket = state.socket

    task =
      Task.Supervisor.async_nolink(Exfuse.RequestSupervisor, fn ->
        Exfuse.Fs.Dsl.normalize_event_result(
          request.operation,
          module.handle_event(request.operation, request.event, socket),
          socket
        )
      end)

    request = Map.merge(request, %{base_socket: socket, pid: task.pid})
    writer = if request.kind == :write, do: task.ref, else: state.writer
    %{state | active: Map.put(state.active, task.ref, request), writer: writer}
  end

  defp complete_request(state, %{kind: :read, base_socket: base, from: from}, result) do
    if result_socket(result) == base do
      GenServer.reply(from, result)
    else
      GenServer.reply(from, {:error, :eio, state.socket})
    end

    state
  end

  defp complete_request(state, %{kind: :write, from: from}, result) do
    socket = result_socket(result)
    GenServer.reply(from, result)
    %{state | socket: socket}
  end

  defp drain(state) do
    case :queue.out(state.queue) do
      {:empty, _queue} ->
        state

      {{:value, request}, queue} ->
        candidate = %{state | queue: queue, queue_size: state.queue_size - 1}

        if runnable_after_pop?(candidate, request) do
          candidate
          |> start_request(request)
          |> drain()
        else
          state
        end
    end
  end

  defp runnable_after_pop?(state, %{kind: :read}) do
    is_nil(state.writer) and map_size(state.active) < state.max_concurrency
  end

  defp runnable_after_pop?(state, %{kind: :write}) do
    is_nil(state.writer) and map_size(state.active) == 0
  end

  defp result_socket({:noreply, %Socket{} = socket}), do: socket
  defp result_socket({:reply, _value, %Socket{} = socket}), do: socket
  defp result_socket({:error, _reason, %Socket{} = socket}), do: socket

  defp clear_writer(reference, reference), do: nil
  defp clear_writer(writer, _reference), do: writer

  defp positive_option(options, key, default) do
    case Keyword.get(options, key, default) do
      value when is_integer(value) and value > 0 -> value
      value -> raise ArgumentError, "#{key} must be a positive integer, got: #{inspect(value)}"
    end
  end
end
