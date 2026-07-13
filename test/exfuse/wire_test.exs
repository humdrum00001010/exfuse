defmodule Exfuse.WireTest do
  use ExUnit.Case, async: true

  alias Exfuse.Wire

  @magic 0xC021_55AC
  @v3 0x7633_0003

  test "v3 readdir encodes names and 64-bit attrs in bounded records" do
    request = request(7, 3, "/topics")
    assert {:ok, decoded, %{path: "/topics"}} = Wire.decode_request(request)

    entries = [
      {"page-00001", {0o0755, 1, 0}},
      {"large.bin", {0o0644, 2, 5_000_000_000, 1_720_000_000}}
    ]

    reply = Wire.encode_reply(decoded, {:reply, entries, %Exfuse.Socket{}})

    assert <<@magic::32, @v3::32, 3::32, 7::64, 0::32, 2::32, body::binary>> = reply
    assert <<10::32, "page-00001", 16::32, 0o0755::32, 1::32, 0::64, rest::binary>> = body

    assert <<9::32, "large.bin", 24::32, 0o0644::32, 2::32, 5_000_000_000::64, 1_720_000_000::64>> =
             rest
  end

  test "v2 and malformed directory names are rejected" do
    v2 = :binary.replace(request(1, 3, "/"), <<@v3::32>>, <<0x7632_0002::32>>)
    assert {:error, :eproto} = Wire.decode_request(v2)

    request = {1, :readdir, 3}
    reply = Wire.encode_reply(request, {:reply, [{"bad/name", {0o644, 2, 0}}], %Exfuse.Socket{}})
    assert <<@magic::32, @v3::32, 3::32, 1::64, 22::32>> = reply
  end

  defp request(id, operation, path) do
    <<@magic::32, @v3::32, operation::32, id::64, 501::32, 20::32, 123::32, 0o022::32,
      path::binary>>
  end
end
