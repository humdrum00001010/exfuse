defmodule Exfuse.FSKit.Signing do
  @moduledoc false

  @preferred_identity_prefixes [
    "Developer ID Application:",
    "Apple Development:",
    "Mac Developer:"
  ]

  def resolve_identity(explicit_identity, opts \\ []) do
    allow_adhoc? = Keyword.get(opts, :allow_adhoc, false)
    identity = present(explicit_identity) || present(System.get_env("EXFUSE_CODESIGN_IDENTITY"))

    cond do
      identity == "-" and allow_adhoc? ->
        {:ok, "-"}

      identity == "-" ->
        {:error, :adhoc_not_allowed}

      is_binary(identity) ->
        {:ok, identity}

      allow_adhoc? ->
        {:ok, "-"}

      true ->
        auto_identity()
    end
  end

  def auto_identity do
    with {output, 0} <-
           System.cmd("security", ["find-identity", "-v", "-p", "codesigning"],
             stderr_to_stdout: true
           ) do
      identities = identities_from_security_output(output)

      case {identities, preferred_identity(identities)} do
        {[], _identity} -> {:error, :no_codesign_identity}
        {_identities, nil} -> {:error, :no_preferred_codesign_identity}
        {_identities, identity} -> {:ok, identity}
      end
    else
      {output, status} -> {:error, {:security_find_identity_failed, status, output}}
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  def identities_from_security_output(output) do
    ~r/^\s*\d+\)\s+[A-Fa-f0-9]+\s+"([^"]+)"/m
    |> Regex.scan(output)
    |> Enum.map(fn [_, identity] -> identity end)
  end

  def preferred_identity(identities) do
    Enum.find(identities, fn identity ->
      Enum.any?(@preferred_identity_prefixes, &String.starts_with?(identity, &1))
    end)
  end

  def signature(path) do
    case System.cmd("codesign", ["-dv", path], stderr_to_stdout: true) do
      {output, 0} ->
        if String.contains?(output, "Signature=adhoc") do
          {:ok, :adhoc}
        else
          {:ok, :signed}
        end

      {output, status} ->
        {:error, {status, output}}
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value), do: value
end
