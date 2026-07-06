defmodule Exfuse.FSKit.Provisioning do
  @moduledoc false

  # Provisioning-profile support for the FSKit app extension.
  #
  # `com.apple.developer.fskit.fsmodule` is a restricted entitlement: AMFI only
  # launches the extension when an embedded provisioning profile authorizes the
  # entitlement for the signing team ("Restricted entitlements not validated,
  # bailing out ... No matching profile found" otherwise). A trusted signature
  # alone is NOT enough. So a runnable bundle needs:
  #
  #   1. `Contents/embedded.provisionprofile` inside the appex, granting the
  #      FSKit entitlement to `<team>.<extension bundle id>`, and
  #   2. the appex signed with `com.apple.application-identifier` and
  #      `com.apple.developer.team-identifier` entitlements matching that
  #      profile (Xcode injects these automatically; manual codesign must too).
  #
  # `mix exfuse.fskit.provision` mints a matching development profile through
  # Xcode automatic provisioning; this module locates, validates, and embeds it.

  @fskit_entitlement "com.apple.developer.fskit.fsmodule"

  @type profile :: %{
          path: String.t(),
          name: String.t() | nil,
          application_identifier: String.t(),
          team_identifier: String.t(),
          expires_at: DateTime.t() | nil
        }

  @doc """
  Find a provisioning profile authorizing the FSKit entitlement for `bundle_id`.

  An explicit path (`:explicit` option or `EXFUSE_FSKIT_PROFILE`) is validated
  rather than trusted. Otherwise the local Xcode profile stores are scanned and
  the latest-expiring match wins.
  """
  def find_profile(bundle_id, opts \\ []) do
    case present(Keyword.get(opts, :explicit)) || present(System.get_env("EXFUSE_FSKIT_PROFILE")) do
      nil -> scan_profiles(bundle_id)
      path -> validate_explicit(path, bundle_id)
    end
  end

  @doc "Directories Xcode drops downloaded `.provisionprofile` files into."
  def profile_dirs do
    home = System.user_home!()

    [
      Path.join(home, "Library/Developer/Xcode/UserData/Provisioning Profiles"),
      Path.join(home, "Library/MobileDevice/Provisioning Profiles")
    ]
  end

  @doc "Decode one `.provisionprofile` (CMS-wrapped plist) into a profile map."
  def decode_profile(path) do
    with {:ok, plist} <- decode_cms(path),
         {:ok, app_id} <- extract(plist, entitlement_key_path("com.apple.application-identifier")),
         {:ok, team} <-
           extract(plist, entitlement_key_path("com.apple.developer.team-identifier")),
         {:ok, "true"} <- extract(plist, entitlement_key_path(@fskit_entitlement)) do
      {:ok,
       %{
         path: path,
         name:
           case extract(plist, "Name") do
             {:ok, name} -> name
             _ -> nil
           end,
         application_identifier: app_id,
         team_identifier: team,
         expires_at: expiration(plist)
       }}
    else
      {:ok, _not_true} -> {:error, :no_fskit_entitlement}
      {:error, reason} -> {:error, reason}
    end
  after
    File.rm(decoded_path(path))
  end

  @doc "Whether `profile` authorizes `bundle_id` and has not expired."
  def profile_matches?(profile, bundle_id, now \\ DateTime.utc_now()) do
    String.ends_with?(profile.application_identifier, "." <> bundle_id) and
      not expired?(profile, now)
  end

  @doc """
  The team id of a signing identity — the OU of its certificate, NOT the
  parenthesized id in an "Apple Development: Name (XXXXXXXXXX)" identity
  (that one is personal).
  """
  def team_identifier(identity) do
    pem_path = Path.join(System.tmp_dir!(), "exfuse-cert-#{:erlang.phash2(identity)}.pem")

    try do
      with {pem, 0} <-
             System.cmd("security", ["find-certificate", "-c", identity, "-p"],
               stderr_to_stdout: true
             ),
           :ok <- File.write(pem_path, pem),
           {subject, 0} <-
             System.cmd("openssl", ["x509", "-in", pem_path, "-noout", "-subject"],
               stderr_to_stdout: true
             ),
           [_, team] <- Regex.run(~r/OU\s*=\s*([A-Z0-9]+)/, subject) do
        {:ok, team}
      else
        _ -> {:error, :team_not_derivable}
      end
    after
      File.rm(pem_path)
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  @doc "Copy the profile to `Contents/embedded.provisionprofile` inside the appex."
  def embed(profile, appex_path) do
    destination = Path.join(appex_path, "Contents/embedded.provisionprofile")
    File.cp!(profile.path, destination)
    destination
  end

  @doc """
  Write the appex signing entitlements: the static `base_plist` plus the
  `application-identifier`/`team-identifier` pair the profile authorizes.
  """
  def signing_entitlements(profile, base_plist, output_path) do
    File.mkdir_p!(Path.dirname(output_path))
    File.cp!(base_plist, output_path)

    with :ok <-
           plutil_replace(
             output_path,
             escape_key("com.apple.application-identifier"),
             profile.application_identifier
           ),
         :ok <-
           plutil_replace(
             output_path,
             escape_key("com.apple.developer.team-identifier"),
             profile.team_identifier
           ) do
      {:ok, output_path}
    end
  end

  # ── helpers ───────────────────────────────────────────────────────

  defp scan_profiles(bundle_id) do
    profile_dirs()
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "*.provisionprofile")))
    |> Enum.flat_map(fn path ->
      case decode_profile(path) do
        {:ok, profile} -> [profile]
        {:error, _reason} -> []
      end
    end)
    |> Enum.filter(&profile_matches?(&1, bundle_id))
    |> Enum.sort_by(& &1.expires_at, &later?/2)
    |> case do
      [] -> {:error, :no_matching_profile}
      [profile | _rest] -> {:ok, profile}
    end
  end

  defp validate_explicit(path, bundle_id) do
    with {:ok, profile} <- decode_profile(path) do
      if profile_matches?(profile, bundle_id) do
        {:ok, profile}
      else
        {:error, {:profile_mismatch, profile.application_identifier, bundle_id}}
      end
    end
  end

  defp later?(nil, _b), do: false
  defp later?(_a, nil), do: true
  defp later?(a, b), do: DateTime.compare(a, b) != :lt

  defp expired?(%{expires_at: nil}, _now), do: false
  defp expired?(%{expires_at: expires_at}, now), do: DateTime.compare(expires_at, now) == :lt

  defp decode_cms(path) do
    decoded = decoded_path(path)

    case System.cmd("security", ["cms", "-D", "-i", path, "-o", decoded], stderr_to_stdout: true) do
      {_out, 0} -> {:ok, decoded}
      {out, status} -> {:error, {:cms_decode_failed, status, String.trim(out)}}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp decoded_path(path) do
    Path.join(
      System.tmp_dir!(),
      "exfuse-profile-#{:erlang.phash2(path)}.plist"
    )
  end

  defp extract(plist, key_path) do
    case System.cmd("plutil", ["-extract", key_path, "raw", "-o", "-", plist],
           stderr_to_stdout: true
         ) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, status} -> {:error, {:plutil_extract_failed, key_path, status, String.trim(out)}}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp expiration(plist) do
    with {:ok, raw} <- extract(plist, "ExpirationDate"),
         {:ok, datetime, _offset} <- DateTime.from_iso8601(raw) do
      datetime
    else
      _ -> nil
    end
  end

  defp entitlement_key_path(key), do: "Entitlements." <> escape_key(key)

  # plutil key paths split on ".", so literal dots in a key must be escaped.
  defp escape_key(key), do: String.replace(key, ".", "\\.")

  defp plutil_replace(plist, key_path, value) do
    case System.cmd("plutil", ["-replace", key_path, "-string", value, plist],
           stderr_to_stdout: true
         ) do
      {_out, 0} -> :ok
      {out, status} -> {:error, {:plutil_replace_failed, key_path, status, String.trim(out)}}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value), do: value
end
