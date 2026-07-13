defmodule Exfuse.Wire.Encode do
  @moduledoc false

  alias Exfuse.Wire.{Attr, Readdir}

  @magic 0xC021_55AC
  @protocol Exfuse.Wire.protocol()

  def reply(request, {:noreply, _socket}), do: success(request, <<>>)

  def reply(request, {:reply, value, _socket}) do
    case payload(request, value) do
      {:ok, encoded} -> success(request, encoded)
      {:error, reason} -> error(request, reason)
    end
  end

  def reply(request, {:error, reason, _socket}), do: error(request, reason)
  def reply(request, _invalid), do: error(request, :eio)

  def error({request_id, _operation, code}, reason) do
    <<@magic::32, @protocol::32, code::32, request_id::64, errno(reason)::32>>
  end

  defp success({request_id, _operation, code}, payload) do
    <<@magic::32, @protocol::32, code::32, request_id::64, 0::32, payload::binary>>
  end

  defp payload({_id, :readdir, _code}, entries), do: Readdir.encode(entries)
  defp payload({_id, :getattr, _code}, attributes), do: Attr.encode(attributes)

  defp payload({_id, :readlink, _code}, target) when is_binary(target),
    do: {:ok, <<target::binary, 0>>}

  defp payload({_id, :read, _code}, data) when is_binary(data), do: {:ok, data}

  defp payload({_id, :write, _code}, written)
       when is_integer(written) and written >= 0 and written <= 0xFFFF_FFFF,
       do: {:ok, <<written::32>>}

  defp payload({_id, operation, _code}, handle)
       when operation in [:open, :create] and is_integer(handle) and handle >= 0,
       do: {:ok, <<handle::64>>}

  defp payload({_id, operation, _code}, value)
       when operation in [:open, :create] and value in [nil, :ok],
       do: {:ok, <<>>}

  defp payload({_id, operation, _code}, _value)
       when operation in [
              :truncate,
              :unlink,
              :rename,
              :mkdir,
              :rmdir,
              :chmod,
              :chown,
              :flush,
              :release,
              :fsync
            ],
       do: {:ok, <<>>}

  defp payload(_request, _value), do: {:error, :einval}

  defp errno(reason) when is_integer(reason) and reason >= 0, do: reason
  defp errno(:enoent), do: 2
  defp errno(:eio), do: 5
  defp errno(:e2big), do: 7
  defp errno(:eagain), do: 11
  defp errno(:ebusy), do: 16
  defp errno(:einval), do: 22
  defp errno(:erofs), do: 30
  defp errno(:enosys), do: 38
  defp errno(_reason), do: 5
end
