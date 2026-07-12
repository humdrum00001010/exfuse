defmodule Exfuse.FSKit.LegacyResourceCleanup do
  @moduledoc false

  require Logger

  @legacy_image ~r/^exfuse-\d+\.dmg$/

  def cleanup(opts \\ []) do
    os_type = Keyword.get(opts, :os_type, :os.type())
    runner = Keyword.get(opts, :runner, &run_command/2)
    temp_dir = opts |> Keyword.get(:temp_dir, System.tmp_dir!()) |> canonical_path()

    cond do
      os_type != {:unix, :darwin} ->
        {:ok, %{deleted: 0, detached: 0, kept: 0, skipped: :not_macos}}

      exfuse_mount_active?(runner) ->
        {:ok, %{deleted: 0, detached: 0, kept: 0, skipped: :active_mount}}

      true ->
        case attached_legacy_images(temp_dir, runner) do
          {:ok, attached} ->
            result = cleanup_legacy_images(temp_dir, attached, runner)

            if result.deleted > 0 or result.detached > 0 do
              Logger.info(
                "[Exfuse] cleaned #{result.deleted} legacy FSKit images " <>
                  "(#{result.detached} detached, #{result.kept} kept)"
              )
            end

            {:ok, Map.put(result, :skipped, nil)}

          {:error, _reason} ->
            {:ok, %{deleted: 0, detached: 0, kept: 0, skipped: :hdiutil_unavailable}}
        end
    end
  rescue
    error ->
      Logger.warning("[Exfuse] legacy FSKit cleanup failed: #{Exception.message(error)}")
      {:error, error}
  end

  defp cleanup_legacy_images(temp_dir, attached, runner) do
    files =
      temp_dir
      |> Path.join("exfuse-*.dmg")
      |> Path.wildcard()
      |> Enum.map(&canonical_path/1)
      |> Enum.filter(&legacy_image?(temp_dir, &1))

    candidates = Enum.uniq(files ++ Map.keys(attached))

    Enum.reduce(candidates, %{deleted: 0, detached: 0, kept: 0}, fn image, counts ->
      case Map.fetch(attached, image) do
        {:ok, device} ->
          case runner.("hdiutil", ["detach", device]) do
            {_output, 0} ->
              counts
              |> increment(:detached)
              |> delete_image(image)

            _failure ->
              increment(counts, :kept)
          end

        :error ->
          delete_image(counts, image)
      end
    end)
  end

  defp attached_legacy_images(temp_dir, runner) do
    case runner.("hdiutil", ["info"]) do
      {output, 0} -> {:ok, parse_attached_images(output, temp_dir)}
      failure -> {:error, failure}
    end
  end

  defp parse_attached_images(output, temp_dir) do
    {images, _current_image} =
      output
      |> String.split("\n")
      |> Enum.reduce({%{}, nil}, fn line, {images, current_image} ->
        cond do
          String.starts_with?(line, "image-path") ->
            image =
              line
              |> String.split(":", parts: 2)
              |> List.last()
              |> String.trim()
              |> canonical_path()

            {images, if(legacy_image?(temp_dir, image), do: image)}

          current_image && String.starts_with?(line, "/dev/disk") ->
            device = line |> String.split() |> List.first()
            {Map.put(images, current_image, device), current_image}

          true ->
            {images, current_image}
        end
      end)

    images
  end

  defp exfuse_mount_active?(runner) do
    case runner.("mount", []) do
      {output, 0} ->
        output
        |> String.split("\n")
        |> Enum.any?(fn line ->
          String.starts_with?(line, "exfuse") or
            String.contains?(line, "(exfuse,") or
            String.ends_with?(line, "(exfuse)")
        end)

      _failure ->
        true
    end
  end

  defp legacy_image?(temp_dir, image) do
    Path.dirname(image) == temp_dir and Path.basename(image) =~ @legacy_image
  end

  defp delete_image(counts, image) do
    case File.rm(image) do
      :ok -> increment(counts, :deleted)
      {:error, :enoent} -> counts
      {:error, _reason} -> increment(counts, :kept)
    end
  end

  defp increment(counts, key), do: Map.update!(counts, key, &(&1 + 1))

  defp canonical_path("/private/var/" <> rest), do: "/var/" <> rest
  defp canonical_path("/private/tmp/" <> rest), do: "/tmp/" <> rest
  defp canonical_path(path), do: Path.expand(path)

  defp run_command(command, args) do
    System.cmd(command, args, stderr_to_stdout: true)
  rescue
    error -> {:error, Exception.message(error)}
  end
end
