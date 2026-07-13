defmodule Exfuse.Wire do
  @moduledoc false

  @protocol_v3 0x7633_0003
  @operations %{
    3 => :readdir,
    4 => :getattr,
    5 => :readlink,
    6 => :read,
    7 => :write,
    8 => :open,
    9 => :create,
    10 => :truncate,
    11 => :unlink,
    12 => :rename,
    13 => :mkdir,
    14 => :rmdir,
    15 => :chmod,
    16 => :chown,
    17 => :flush,
    18 => :release,
    19 => :fsync
  }
  @codes Map.new(@operations, fn {code, operation} -> {operation, code} end)

  @type request :: {non_neg_integer, atom, non_neg_integer}

  def protocol, do: @protocol_v3
  def operations, do: @operations
  def operation_code(operation), do: Map.get(@codes, operation)

  defdelegate decode_request(packet), to: Exfuse.Wire.Decode, as: :request
  defdelegate encode_reply(request, result), to: Exfuse.Wire.Encode, as: :reply
  defdelegate error_reply(request, reason), to: Exfuse.Wire.Encode, as: :error

  def encode_reply_for(result, request), do: encode_reply(request, result)
end
