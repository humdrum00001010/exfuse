defmodule Exfuse.FSKit.SigningTest do
  use ExUnit.Case, async: true

  alias Exfuse.FSKit.Signing

  test "parses code-signing identities from security output" do
    output = """
      1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Apple Development: Ada Lovelace (TEAMID)"
      2) BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB "Developer ID Application: Example Corp (TEAMID)"
         2 valid identities found
    """

    assert Signing.identities_from_security_output(output) == [
             "Apple Development: Ada Lovelace (TEAMID)",
             "Developer ID Application: Example Corp (TEAMID)"
           ]
  end

  test "prefers Apple code-signing identities" do
    identities = [
      "Local Test Cert",
      "Apple Development: Ada Lovelace (TEAMID)",
      "Developer ID Application: Example Corp (TEAMID)"
    ]

    assert Signing.preferred_identity(identities) == "Apple Development: Ada Lovelace (TEAMID)"
  end

  test "does not auto-prefer arbitrary local certificates" do
    assert Signing.preferred_identity(["Local Test Cert"]) == nil
  end

  test "prefers Apple Development over Developer ID regardless of keychain order" do
    identities = [
      "Developer ID Application: Example Corp (TEAMID)",
      "Apple Development: Ada Lovelace (TEAMID)"
    ]

    assert Signing.preferred_identity(identities) == "Apple Development: Ada Lovelace (TEAMID)"
  end

  test "allow_adhoc uses ad-hoc identity when none is configured" do
    previous = System.get_env("EXFUSE_CODESIGN_IDENTITY")
    System.delete_env("EXFUSE_CODESIGN_IDENTITY")

    try do
      assert Signing.resolve_identity(nil, allow_adhoc: true) == {:ok, "-"}
    after
      if previous, do: System.put_env("EXFUSE_CODESIGN_IDENTITY", previous)
    end
  end
end
