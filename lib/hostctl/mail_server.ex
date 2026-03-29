defmodule Hostctl.MailServer do
  @moduledoc """
  Manages Postfix smarthost (relayhost) configuration — both server-wide and
  per-domain.

  ## Server-wide smarthost

  `apply_smarthost/1` writes `/etc/postfix/sasl_passwd`, runs `postmap`,
  configures `relayhost` and related SASL directives via `postconf -e`, and
  reloads Postfix. Disabling removes all those directives.

  ## Per-domain smarthost

  Per-domain overrides use Postfix's `sender_dependent_relayhost_maps` mechanism.
  `apply_domain_smarthost/2` rebuilds two hash maps from the full set of enabled
  domain settings stored in the database:

    - `/etc/postfix/domain_relay`         — maps `@domain.com` → relay host:port
    - `/etc/postfix/domain_relay_secrets` — maps relay host:port → user:pass

  It also sets the required baseline `main.cf` directives
  (`smtp_sender_dependent_authentication`, `sender_dependent_relayhost_maps`) and
  reloads Postfix. Domain-level settings take priority over the server-wide relay.

  All filesystem/process operations run via `sudo systemd-run --pipe --wait` to
  escape `ProtectSystem=strict`.

  Set `enabled: false` in config to skip all operations (test/dev):

      config :hostctl, :mail_server, enabled: false
  """

  require Logger

  alias Hostctl.Hosting

  @sasl_passwd_path "/etc/postfix/sasl_passwd"
  @domain_relay_path "/etc/postfix/domain_relay"
  @domain_relay_secrets_path "/etc/postfix/domain_relay_secrets"

  @sasl_directives ~w(
    smtp_sasl_auth_enable
    smtp_sasl_password_maps
    smtp_sasl_security_options
    smtp_tls_security_level
    relayhost
  )

  # ---------------------------------------------------------------------------
  # Server-wide smarthost
  # ---------------------------------------------------------------------------

  @doc """
  Applies the server-wide smarthost configuration to Postfix.

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

  defp configure_smarthost(setting) do
    host_port = format_host_port(setting.host, setting.port)

    with :ok <- write_sasl_passwd(host_port, setting),
         :ok <- secure_file(@sasl_passwd_path),
         :ok <- run_postmap(@sasl_passwd_path),
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
    write_file(@sasl_passwd_path, "")
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
          ["smtp_sasl_auth_enable=no"]
        end

    run_postconf_e(directives)
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

  # ---------------------------------------------------------------------------
  # Per-domain smarthost
  # ---------------------------------------------------------------------------

  @doc """
  Applies per-domain relay configuration for the given domain.

  Rebuilds the full `domain_relay` and `domain_relay_secrets` hash maps from
  all enabled domain smarthost settings in the database (including the one just
  saved), sets the required Postfix baseline directives, and reloads Postfix.

  Pass `domain` as the `%Domain{}` whose setting was just changed so the
  caller's context is clear, but the rebuild is always from the full DB state.

  Returns `:ok` or `{:error, reason}`.
  """
  def apply_domain_smarthost(_domain) do
    if enabled?() do
      rebuild_domain_relay_maps()
    else
      :ok
    end
  end

  defp rebuild_domain_relay_maps do
    settings = Hosting.list_enabled_domain_smarthost_settings()

    relay_entries =
      Enum.map(settings, fn s ->
        host_port = format_host_port(s.host, s.port)
        "@#{s.domain.name} #{host_port}"
      end)

    secrets_entries =
      settings
      |> Enum.filter(& &1.auth_required)
      |> Enum.map(fn s ->
        host_port = format_host_port(s.host, s.port)
        "#{host_port} #{s.username}:#{s.password}"
      end)
      |> Enum.uniq()

    with :ok <- write_file(@domain_relay_path, Enum.join(relay_entries, "\n") <> "\n"),
         :ok <- write_file(@domain_relay_secrets_path, Enum.join(secrets_entries, "\n") <> "\n"),
         :ok <- secure_file(@domain_relay_secrets_path),
         :ok <- run_postmap(@domain_relay_path),
         :ok <- run_postmap(@domain_relay_secrets_path),
         :ok <- set_domain_relay_directives(),
         :ok <- reload_postfix() do
      :ok
    end
  end

  defp set_domain_relay_directives do
    directives = [
      "smtp_sender_dependent_authentication=yes",
      "sender_dependent_relayhost_maps=hash:#{@domain_relay_path}"
    ]

    run_postconf_e(directives)
  end

  # ---------------------------------------------------------------------------
  # Shared helpers
  # ---------------------------------------------------------------------------

  defp run_postconf_e(directives) do
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

  defp secure_file(path) do
    case escaped_cmd("chmod", ["600", path], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {output, code} ->
        Logger.error("[MailServer] chmod #{path} failed (#{code}): #{output}")
        {:error, {:chmod_failed, code}}
    end
  end

  defp run_postmap(path) do
    case escaped_cmd("postmap", [path], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {output, code} ->
        Logger.error("[MailServer] postmap #{path} failed (#{code}): #{output}")
        {:error, {:postmap_failed, code}}
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

  defp format_host_port(host, port) do
    bracketed =
      if String.starts_with?(host, "["), do: host, else: "[#{host}]"

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
