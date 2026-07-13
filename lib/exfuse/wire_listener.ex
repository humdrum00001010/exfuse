defmodule Exfuse.WireListener do
  @moduledoc """
  TCP transport for FSKit and other non-Port exfuse frontends.

  The wire format is the same one used by the Rust FUSE port over stdio: Erlang
  packet-4 framing, followed by the exfuse magic, request code, context, and
  request payload. Reusing that format keeps filesystem callbacks transport
  agnostic.
  """

  use GenServer

  @type dispatcher :: {module, atom, list}
  @type option :: {:port, :inet.port_number()} | {:dispatcher, dispatcher}

  @spec start_link([option]) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    dispatcher = Keyword.fetch!(opts, :dispatcher)
    port = Keyword.get(opts, :port, 35_368)

    listen_opts = [
      :binary,
      packet: 4,
      active: false,
      reuseaddr: true,
      ip: {127, 0, 0, 1}
    ]

    case :gen_tcp.listen(port, listen_opts) do
      {:ok, listen_socket} ->
        state = %{dispatcher: dispatcher, listen_socket: listen_socket, port: port}
        {:ok, state, {:continue, :accept}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:accept, state) do
    _ = Task.start_link(fn -> accept_loop(state.listen_socket, state.dispatcher) end)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    _ = :gen_tcp.close(state.listen_socket)
    :ok
  end

  defp accept_loop(listen_socket, dispatcher) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        _ = Task.start(fn -> serve(socket, dispatcher) end)
        accept_loop(listen_socket, dispatcher)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        Process.sleep(50)
        accept_loop(listen_socket, dispatcher)
    end
  end

  defp serve(socket, dispatcher) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, packet} ->
        case apply_dispatcher(dispatcher, packet) do
          reply when is_binary(reply) ->
            :ok = :gen_tcp.send(socket, reply)
            serve(socket, dispatcher)

          :close ->
            :gen_tcp.close(socket)
        end

      {:error, _reason} ->
        _ = :gen_tcp.close(socket)
        :ok
    end
  catch
    :exit, _reason ->
      _ = :gen_tcp.close(socket)
      :ok
  end

  defp apply_dispatcher({module, function, arguments}, packet),
    do: apply(module, function, arguments ++ [packet])
end
