defmodule Hostctl.MailServer do
  @moduledoc """
  Manages Postfix smarthost (relayhost) configuration.

  When a smarthost is enabled, this module writes the SASL credentials file,
  builds the hash database, and sets the required Postfix directives via
  `postconf -e`. When disabled, the smarthost directives are removed.

  All filesystem and process operations are run via `systemd-run` to escape the
  service's `ProtectSystem=strict` mount namespace, mirroring the same pattern
  used by `Hostctl.FeatureSetup`.

  Set `enabled: false` in config to skip all operations (test/dev):

      config :hostctl, :mail_server, enabled: false
  """

  require Logger

  @sasl_passwd_path "/etc/postfix/sasl_passwd"

  @sasl_directives ~w(
    smtp_sasl_auth_enable
    smtp_sasl_password_maps
    smtp_sasl_security_options
    smtp_tls_security_level
    relayhost
  )

  @doc """
  Applies the smarthost configuration to Postfix.

  If `setting.enabled` is true, writes credentials and configures Postfix.
  If false, removes the relayhost directives and reloads Postfix.

  Returns `:ok` or `{:error, reason}`.
  """
  def apply_smarthost(setting) do
    if enabled?() do
      if setting.enabled do
        configure_smarthost(setting)
      else
        remove_smarthost()
      end
    else
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Configuration
  # ---------------------------------------------------------------------------

  defp configure_smarthost(setting) do
    host_port = format_host_port(setting.host, setting.port)

    with :ok <- write_sasl_passwd(host_port, setting),
         :ok <- secure_sasl_passwd(),
         :ok <- run_postmap(),
         :ok <- set_postfix_directives(host_port, setting),
         :ok <- reload_postfix() do
      :ok
    end
  end

  defp remove_smarthost do
    with :ok <- clear_postfix_directives(),
         :ok <- reload_postfix() do
      :ok
    end
  end

  defp write_sasl_passwd(host_port, %{auth_required: true, username: username, password: password}) do
    content = "#{host_port} #{username}:#{password}\n"
    write_file(@sasl_passwd_path, content)
  end

  defp write_sasl_passwd(_host_port, _setting) do
    # No auth required — write an empty credentials file
    write_file(@sasl_passwd_path, "")
  end

  defp secure_sasl_passwd do
    case escaped_cmd("chmod", ["600", @sasl_passwd_path], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {output, code} ->
        Logger.error("[MailServer] chmod sasl_passwd failed (#{code}): #{output}")
        {:error, {:chmod_failed, code}}
    end
  end

  defp run_postmap do
    case escaped_cmd("postmap", [@sasl_passwd_path], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {output, code} ->
        Logger.error("[MailServer] postmap failed (#{code}): #{output}")
        {:error, {:postmap_failed, code}}
    end
  end

  defp set_postfix_directives(host_port, setting) do
    directives =
      [
        "relayhost=#{host_port}",
        "smtp_tls_security_level=may"
      ] ++
        if setting.auth_required do
          [
            "smtp_sasl_auth_enable=yes",
            "smtp_sasl_password_maps=hash:#{@sasl_passwd_path}",
            "smtp_sasl_security_options=noanonymous"
          ]
        else
          [
            "smtp_sasl_auth_enable=no"
          ]
        end

    Enum.reduce_while(directives, :ok, fn directive, :ok ->
      case escaped_cmd("postconf", ["-e", directive], stderr_to_stdout: true) do
        {_, 0} ->
          {:cont, :ok}

        {output, code} ->
          Logger.error("[MailServer] postconf -e #{directive} failed (#{code}): #{output}")
          {:halt, {:error, {:postconf_failed, code}}}
      end
    end)
  end

  defp clear_postfix_directives do
    case escaped_cmd("postconf", ["-X" | @sasl_directives], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {output, code} ->
        Logger.error("[MailServer] postconf -X failed (#{code}): #{output}")
        {:error, {:postconf_failed, code}}
    end
  end

  defp reload_postfix do
    case escaped_cmd("systemctl", ["reload", "postfix"], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {output, code} ->
        Logger.error("[MailServer] postfix reload failed (#{code}): #{output}")
        {:error, {:reload_failed, code}}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp format_host_port(host, port) do
    # Wrap bare hostnames in brackets (disables MX lookup, required for relay)
    # If the user already wrapped in brackets, leave as-is
    bracketed =
      if String.starts_with?(host, "[") do
        host
      else
        "[#{host}]"
      end

    "#{bracketed}:#{port}"
  end

  defp write_file(path, content) do
    encoded = Base.encode64(content)

    case System.cmd(
           "sh",
           [
             "-c",
             ~s(echo '#{encoded}' | base64 -d | sudo systemd-run --pipe --wait --collect --quiet tee -- "$1" > /dev/null),
             "--",
             path
           ],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      {output, code} ->
        Logger.error("[MailServer] Failed to write #{path} (#{code}): #{output}")
        {:error, {:write_failed, path}}
    end
  end

  defp escaped_cmd(cmd, args, opts) do
    System.cmd(
      "sudo",
      ["systemd-run", "--pipe", "--wait", "--collect", "--quiet", cmd | args],
      opts
    )
  end

  defp enabled? do
    Application.get_env(:hostctl, :mail_server, [])
    |> Keyword.get(:enabled, true)
  end
end
