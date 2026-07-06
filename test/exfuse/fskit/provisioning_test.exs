defmodule Exfuse.FSKit.ProvisioningTest do
  use ExUnit.Case, async: true

  alias Exfuse.FSKit.Provisioning

  @bundle_id "org.exfuse.fskit.extension"

  defp profile(overrides \\ %{}) do
    Map.merge(
      %{
        path: "/tmp/example.provisionprofile",
        name: "Mac Team Provisioning Profile: #{@bundle_id}",
        application_identifier: "TEAMID.#{@bundle_id}",
        team_identifier: "TEAMID",
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      },
      overrides
    )
  end

  test "matches a profile whose application identifier covers the bundle id" do
    assert Provisioning.profile_matches?(profile(), @bundle_id)
  end

  test "rejects a profile for a different bundle id" do
    refute Provisioning.profile_matches?(
             profile(%{application_identifier: "TEAMID.org.other.app"}),
             @bundle_id
           )
  end

  test "rejects an expired profile" do
    expired = profile(%{expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)})
    refute Provisioning.profile_matches?(expired, @bundle_id)
  end

  test "a profile without an expiration date still matches" do
    assert Provisioning.profile_matches?(profile(%{expires_at: nil}), @bundle_id)
  end

  if :os.type() == {:unix, :darwin} do
    test "signing entitlements gain the profile's identifier pair" do
      base = Path.join(System.tmp_dir!(), "exfuse-test-base-entitlements.plist")
      output = Path.join(System.tmp_dir!(), "exfuse-test-signing-entitlements.plist")

      File.write!(base, """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>com.apple.developer.fskit.fsmodule</key>
        <true/>
      </dict>
      </plist>
      """)

      on_exit(fn ->
        File.rm(base)
        File.rm(output)
      end)

      assert {:ok, ^output} = Provisioning.signing_entitlements(profile(), base, output)

      {json, 0} = System.cmd("plutil", ["-convert", "json", "-o", "-", output])

      assert json =~ ~s("com.apple.application-identifier":"TEAMID.#{@bundle_id}")
      assert json =~ ~s("com.apple.developer.team-identifier":"TEAMID")
      assert json =~ ~s("com.apple.developer.fskit.fsmodule":true)
    end
  end
end
