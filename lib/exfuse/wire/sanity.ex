defmodule Exfuse.Wire.Sanity do
  @moduledoc false

  @max_frame_bytes 128 * 1024 * 1024
  @max_entries 1_000_000

  def max_body_bytes, do: @max_frame_bytes - 24
  def valid_entry_count?(count), do: count <= @max_entries
  def valid_body_size?(bytes), do: bytes <= max_body_bytes()
end
