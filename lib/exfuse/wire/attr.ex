defmodule Exfuse.Wire.Attr do
  @moduledoc false

  @max_u32 0xFFFF_FFFF
  @max_u64 0xFFFF_FFFF_FFFF_FFFF

  @spec encode(term) :: {:ok, binary} | {:error, :einval}
  def encode({mode, type, size})
      when is_integer(mode) and mode >= 0 and mode <= @max_u32 and
             type in [1, 2, 3] and
             is_integer(size) and size >= 0 and size <= @max_u64 do
    {:ok, <<mode::32, type::32, size::64>>}
  end

  def encode({mode, type, size, mtime})
      when is_integer(mtime) and mtime >= 0 and mtime <= @max_u64 do
    with {:ok, base} <- encode({mode, type, size}) do
      {:ok, <<base::binary, mtime::64>>}
    end
  end

  def encode(_attributes), do: {:error, :einval}
end
