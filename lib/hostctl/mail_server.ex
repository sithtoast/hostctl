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
      "sender_dependent_relayhost_maps=hash:#{@domain_relay_path}",
      "smtp_sasl_auth_enable=yes",
      "smtp_sasl_password_maps=hash:#{@domain_relay_secrets_path}",
      "smtp_sasl_security_options=noanonymous",
      "smtp_tls_security_level=may"
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

  # ---------------------------------------------------------------------------
  # Dovecot passwd-file sync
  # ---------------------------------------------------------------------------

  @dovecot_passwd_path "/etc/dovecot/passwd"

  @doc """
  Regenerates `/etc/dovecot/passwd` from all email accounts in the database
  and restarts Dovecot.

  Uses the Dovecot passwd-file format:
    username@domain:{BLF-CRYPT}hash:uid:gid::home::

  Called after every email account create/update/delete.
  Returns `:ok` or `{:error, reason}`.
  """
  def sync_dovecot_passwd do
    if enabled?() do
      do_sync_dovecot_passwd()
    else
      :ok
    end
  end

  defp do_sync_dovecot_passwd do
    accounts =
      Hosting.list_all_email_accounts_with_domains()

    content =
      accounts
      |> Enum.map(fn {username, domain_name, hashed_password} ->
        home = "/var/mail/vhosts/#{domain_name}/#{username}"
        "#{username}@#{domain_name}:{BLF-CRYPT}#{hashed_password}:5000:5000::#{home}::"
      end)
      |> Enum.join("\n")

    content = if content == "", do: "", else: content <> "\n"

    with :ok <- write_file(@dovecot_passwd_path, content),
         {_, 0} <-
           escaped_cmd("chown", ["root:dovecot", @dovecot_passwd_path], stderr_to_stdout: true),
         {_, 0} <- escaped_cmd("chmod", ["640", @dovecot_passwd_path], stderr_to_stdout: true),
         {_, 0} <-
           escaped_cmd("systemctl", ["reload-or-restart", "dovecot"], stderr_to_stdout: true) do
      :ok
    else
      {:error, _} = err ->
        err

      {output, code} ->
        Logger.error("[MailServer] Failed to sync Dovecot passwd (#{code}): #{output}")
        {:error, :sync_failed}
    end
  end

  # ---------------------------------------------------------------------------
  # Postfix virtual mailbox sync
  # ---------------------------------------------------------------------------

  @virtual_domains_path "/etc/postfix/virtual_domains"
  @virtual_mailbox_path "/etc/postfix/virtual_mailbox"

  @doc """
  Rebuilds Postfix virtual mailbox tables from all email accounts in the database
  and reloads Postfix so inbound mail is accepted and delivered to the right maildir.

  Called after every email account create/delete.
  Returns `:ok` or `{:error, reason}`.
  """
  def sync_virtual_mailboxes do
    if enabled?() do
      do_sync_virtual_mailboxes()
    else
      :ok
    end
  end

  defp do_sync_virtual_mailboxes do
    accounts = Hosting.list_all_email_accounts_with_domains()

    domains =
      accounts
      |> Enum.map(fn {_username, domain_name, _pw} -> domain_name end)
      |> Enum.uniq()
      |> Enum.map(&"#{&1} OK")
      |> Enum.join("\n")

    mailboxes =
      accounts
      |> Enum.map(fn {username, domain_name, _pw} ->
        "#{username}@#{domain_name} #{domain_name}/#{username}/Maildir/"
      end)
      |> Enum.join("\n")

    domains_content = if domains == "", do: "", else: domains <> "\n"
    mailboxes_content = if mailboxes == "", do: "", else: mailboxes <> "\n"

    with :ok <- write_file(@virtual_domains_path, domains_content),
         :ok <- write_file(@virtual_mailbox_path, mailboxes_content),
         :ok <- run_postmap(@virtual_domains_path),
         :ok <- run_postmap(@virtual_mailbox_path),
         :ok <- set_virtual_mailbox_directives(),
         :ok <- reload_postfix() do
      :ok
    end
  end

  defp set_virtual_mailbox_directives do
    directives = [
      "virtual_mailbox_domains=hash:#{@virtual_domains_path}",
      "virtual_mailbox_base=/var/mail/vhosts",
      "virtual_mailbox_maps=hash:#{@virtual_mailbox_path}",
      "virtual_minimum_uid=5000",
      "virtual_uid_maps=static:5000",
      "virtual_gid_maps=static:5000"
    ]

    run_postconf_e(directives)
  end
end
