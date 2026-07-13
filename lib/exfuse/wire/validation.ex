defmodule Exfuse.Wire.Validation do
  @moduledoc false

  def path(path) when is_binary(path) do
    cond do
      path == "" -> {:error, :einval}
      not String.valid?(path) -> {:error, :einval}
      :binary.first(path) != ?/ -> {:error, :einval}
      :binary.match(path, <<0>>) != :nomatch -> {:error, :einval}
      true -> :ok
    end
  end

  def path(_path), do: {:error, :einval}

  def name(name) when is_binary(name) do
    cond do
      name in ["", ".", ".."] -> {:error, :einval}
      byte_size(name) > 255 -> {:error, :einval}
      not String.valid?(name) -> {:error, :einval}
      :binary.match(name, ["/", <<0>>]) != :nomatch -> {:error, :einval}
      true -> :ok
    end
  end

  def name(_name), do: {:error, :einval}
end
