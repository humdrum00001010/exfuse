defmodule Exfuse.Fs.Path do
  @moduledoc false

  @spec canonical(term()) ::
          {:ok, String.t()} | {:error, :invalid_path | :path_traversal}
  def canonical(path) when is_binary(path) do
    if String.contains?(path, <<0>>) do
      {:error, :invalid_path}
    else
      segments =
        path
        |> String.split("/", trim: true)
        |> Enum.reject(&(&1 == "."))

      if Enum.any?(segments, &(&1 == "..")) do
        {:error, :path_traversal}
      else
        {:ok, "/" <> Enum.join(segments, "/")}
      end
    end
  end

  def canonical(_path), do: {:error, :invalid_path}

  @doc """
  Resolve every symlinked ANCESTOR of `path`, not just its last segment.

  `:file.read_link/1` on the leaf answers `{:error, :einval}` whenever the leaf
  is a real directory, so a leaf-only resolver never notices that `/tmp` is a
  symlink to `/private/tmp`. Two separate bugs came from that: the watcher
  dropped every event (`Fs.Real.event_path/2`, `/var` -> `/private/var`), and
  `Exfuse.mount/3` tore down good mounts as `:mount_not_visible` because
  `mount(8)` reported a path the candidate list did not contain.

  Uses `:prim_file` so it is safe inside a filesystem callback — `File`/`:file`
  both route through `file_server_2`, which is what `Fs.Real` exists to avoid.
  """
  @spec resolve_ancestors(String.t()) :: String.t()
  def resolve_ancestors(path) when is_binary(path) do
    path
    |> Path.expand()
    |> Path.split()
    |> Enum.reduce("/", fn segment, acc ->
      joined = Path.join(acc, segment)

      case :prim_file.read_link(String.to_charlist(joined)) do
        {:ok, target} -> Path.expand(List.to_string(target), acc)
        _not_a_link -> joined
      end
    end)
  end
end
