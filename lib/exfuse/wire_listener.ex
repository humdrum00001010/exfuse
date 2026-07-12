defmodule Exfuse.WireListener do
  @moduledoc """
  TCP transport for FSKit and other non-Port exfuse frontends.

  The wire format is the same one used by the Rust FUSE port over stdio: Erlang
  packet-4 framing, followed by the exfuse magic, request code, context, and
  request payload. Reusing that format keeps filesystem callbacks transport
  agnostic.
  """

  use GenServer

  @type option :: {:port, :inet.port_number()} | {:server, pid}

  @spec start_link([option]) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    server = Keyword.fetch!(opts, :server)
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
        state = %{server: server, listen_socket: listen_socket, port: port}
        {:ok, state, {:continue, :accept}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:accept, state) do
    _ = Task.start_link(fn -> accept_loop(state.listen_socket, state.server) end)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    _ = :gen_tcp.close(state.listen_socket)
    :ok
  end

  defp accept_loop(listen_socket, server) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        _ = Task.start(fn -> serve(socket, server) end)
        accept_loop(listen_socket, server)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        Process.sleep(50)
        accept_loop(listen_socket, server)
    end
  end

  defp serve(socket, server) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, packet} ->
        _ =
          Task.start(fn ->
            reply = Exfuse.Server.dispatch(server, packet, :infinity)
            :ok = :gen_tcp.send(socket, reply)
          end)

        serve(socket, server)

      {:error, _reason} ->
        _ = :gen_tcp.close(socket)
        :ok
    end
  catch
    :exit, _reason ->
      _ = :gen_tcp.close(socket)
      :ok
  end
end
