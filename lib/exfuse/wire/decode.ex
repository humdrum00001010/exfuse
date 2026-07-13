defmodule Exfuse.Wire.Decode do
  @moduledoc false

  alias Exfuse.Wire.Validation

  @magic 0xC021_55AC
  @protocol Exfuse.Wire.protocol()

  def request(
        <<@magic::32, @protocol::32, code::32, request_id::64, uid::32, gid::32, pid::32,
          umask::32, payload::binary>>
      ) do
    case Map.fetch(Exfuse.Wire.operations(), code) do
      {:ok, operation} ->
        request = {request_id, operation, code}

        case payload(operation, payload) do
          {:ok, fields} ->
            {:ok, request, Map.merge(fields, %{uid: uid, gid: gid, pid: pid, umask: umask})}

          {:error, reason} ->
            {:error, request, reason}
        end

      :error ->
        {:error, {request_id, :unknown, code}, :enosys}
    end
  end

  def request(_packet), do: {:error, :eproto}

  defp payload(operation, payload)
       when operation in [:readdir, :getattr, :readlink, :unlink, :rmdir],
       do: path_event(payload)

  defp payload(:read, <<flags::32, handle::64, offset::64, size::64, rest::binary>>) do
    with {:ok, path, <<>>} <- take_path(rest),
         do: {:ok, %{path: path, flags: flags, handle: handle, offset: offset, size: size}}
  end

  defp payload(:write, <<handle::64, offset::64, rest::binary>>) do
    with {:ok, path, data} <- take_path(rest),
         do: {:ok, %{path: path, handle: handle, offset: offset, data: data}}
  end

  defp payload(:open, <<flags::32, rest::binary>>) do
    with {:ok, path, <<>>} <- take_path(rest), do: {:ok, %{path: path, flags: flags}}
  end

  defp payload(:create, <<mode::32, flags::32, rest::binary>>) do
    with {:ok, path, <<>>} <- take_path(rest),
         do: {:ok, %{path: path, mode: mode, flags: flags}}
  end

  defp payload(:truncate, <<size::64, rest::binary>>) do
    with {:ok, path, <<>>} <- take_path(rest), do: {:ok, %{path: path, size: size}}
  end

  defp payload(:rename, <<_flags::32, rest::binary>>) do
    with {:ok, path, rest} <- take_path(rest),
         {:ok, target, <<>>} <- take_path(rest),
         do: {:ok, %{path: path, target: target}}
  end

  defp payload(operation, <<mode::32, rest::binary>>) when operation in [:mkdir, :chmod] do
    with {:ok, path, <<>>} <- take_path(rest), do: {:ok, %{path: path, mode: mode}}
  end

  defp payload(:chown, <<uid::32, gid::32, rest::binary>>) do
    with {:ok, path, <<>>} <- take_path(rest),
         do: {:ok, %{path: path, owner_uid: uid, owner_gid: gid}}
  end

  defp payload(operation, <<flags::32, handle::64, rest::binary>>)
       when operation in [:flush, :release] do
    with {:ok, path, <<>>} <- take_path(rest),
         do: {:ok, %{path: path, flags: flags, handle: handle}}
  end

  defp payload(:fsync, <<datasync::32, flags::32, handle::64, rest::binary>>) do
    with {:ok, path, <<>>} <- take_path(rest),
         do: {:ok, %{path: path, datasync: datasync != 0, flags: flags, handle: handle}}
  end

  defp payload(_operation, _payload), do: {:error, :einval}

  defp path_event(path) do
    with :ok <- Validation.path(path), do: {:ok, %{path: path}}
  end

  defp take_path(<<length::32, rest::binary>>) when byte_size(rest) >= length do
    <<path::binary-size(^length), tail::binary>> = rest
    with :ok <- Validation.path(path), do: {:ok, path, tail}
  end

  defp take_path(_payload), do: {:error, :einval}
end
