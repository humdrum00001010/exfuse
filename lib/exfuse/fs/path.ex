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
end
