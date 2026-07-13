defmodule Exfuse.Wire.Readdir do
  @moduledoc false

  alias Exfuse.Wire.{Attr, Sanity, Validation}

  @spec encode(term) :: {:ok, binary} | {:error, :einval | :e2big}
  def encode(entries) when is_list(entries) do
    with {:ok, count, bytes, records} <- encode_entries(entries),
         true <- Sanity.valid_entry_count?(count),
         true <- Sanity.valid_body_size?(bytes + 4) do
      {:ok, IO.iodata_to_binary([<<count::32>>, Enum.reverse(records)])}
    else
      false -> {:error, :e2big}
      {:error, _reason} = error -> error
    end
  end

  def encode(_entries), do: {:error, :einval}

  defp encode_entries(entries) do
    Enum.reduce_while(entries, {:ok, 0, 0, []}, fn entry, {:ok, count, bytes, records} ->
      case encode_entry(entry) do
        {:ok, record, record_bytes} ->
          next_count = count + 1
          next_bytes = bytes + record_bytes

          if Sanity.valid_entry_count?(next_count) and Sanity.valid_body_size?(next_bytes + 4) do
            {:cont, {:ok, next_count, next_bytes, [record | records]}}
          else
            {:halt, {:error, :e2big}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp encode_entry({name, attributes}) when is_binary(name) do
    with :ok <- Validation.name(name),
         {:ok, encoded_attr} <- Attr.encode(attributes) do
      record = [<<byte_size(name)::32>>, name, <<byte_size(encoded_attr)::32>>, encoded_attr]
      {:ok, record, byte_size(name) + byte_size(encoded_attr) + 8}
    end
  end

  defp encode_entry(_entry), do: {:error, :einval}
end
