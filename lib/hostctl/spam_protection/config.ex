defmodule Hostctl.SpamProtection.Config do
  @moduledoc "Renders a recoverable, Junk-only Postfix/Rspamd/Dovecot 2.3 configuration."
  alias Hostctl.SpamProtection.MailboxPolicy

  @sieve_dir "/etc/dovecot/hostctl-spam"

  def bundle(setting, policies, signing_domains \\ []) do
    files = if setting.enabled, do: files(setting, policies, signing_domains), else: %{}
    payload = %{enabled: setting.enabled, learning: setting.learning, files: files}
    digest = :crypto.hash(:sha256, :erlang.term_to_binary(payload)) |> Base.encode16(case: :lower)
    Map.put(payload, :digest, digest)
  end

  defp files(setting, policies, signing_domains) do
    %{
      "/etc/rspamd/override.d/worker-proxy.inc" => """
      bind_socket = "127.0.0.1:11332";
      milter = true;
      timeout = 120s;
      upstream "local" {
        default = yes;
        self_scan = yes;
      }
      """,
      "/etc/rspamd/override.d/worker-normal.inc" => "bind_socket = \"127.0.0.1:11333\";\n",
      "/etc/rspamd/override.d/worker-controller.inc" => """
      bind_socket = "/run/rspamd/hostctl-controller.sock mode=0600 owner=vmail";
      """,
      "/etc/systemd/system/rspamd.service.d/hostctl.conf" => """
      [Unit]
      Wants=hostctl-spam-redis.service
      After=hostctl-spam-redis.service

      [Service]
      RuntimeDirectory=rspamd
      RuntimeDirectoryMode=0755
      """,
      "/etc/rspamd/override.d/redis.conf" =>
        "servers = \"/run/hostctl-spam-redis/redis.sock\";\n",
      "/etc/hostctl-spam-redis.conf" => """
      port 0
      unixsocket /run/hostctl-spam-redis/redis.sock
      unixsocketperm 600
      dir /var/lib/hostctl-spam-redis
      appendonly yes
      appendfsync everysec
      daemonize no
      """,
      "/etc/systemd/system/hostctl-spam-redis.service" => """
      [Unit]
      Description=Hostctl spam learning storage
      After=local-fs.target

      [Service]
      Type=simple
      User=_rspamd
      Group=_rspamd
      RuntimeDirectory=hostctl-spam-redis
      RuntimeDirectoryMode=0700
      StateDirectory=hostctl-spam-redis
      StateDirectoryMode=0700
      ExecStart=/usr/bin/redis-server /etc/hostctl-spam-redis.conf
      Restart=on-failure
      UMask=0077
      NoNewPrivileges=yes
      PrivateTmp=yes
      ProtectSystem=strict
      ProtectHome=yes

      [Install]
      WantedBy=multi-user.target
      """,
      "/etc/rspamd/override.d/dkim_signing.conf" => dkim(signing_domains),
      "/etc/rspamd/override.d/actions.conf" => """
      reject = null;
      greylist = null;
      rewrite_subject = null;
      add_header = 6;
      """,
      "/etc/rspamd/override.d/greylist.conf" => "enabled = false;\n",
      "/etc/rspamd/override.d/force_actions.conf" => "enabled = false;\n",
      "/etc/rspamd/override.d/classifier-bayes.conf" => """
      backend = "redis";
      autolearn = #{if setting.learning, do: "true", else: "false"};
      """,
      "/etc/rspamd/override.d/milter_headers.conf" => """
      use = ["remove-headers", "x-spam-level", "x-spamd-result", "authentication-results"];
      skip_local = false;
      skip_authenticated = false;
      routines {
        remove-headers {
          headers { "X-Hostctl-Spam-Level" = 0; }
        }
        x-spam-level {
          header = "X-Hostctl-Spam-Level";
          char = "*";
          remove = 0;
        }
        x-spamd-result { remove = 0; }
        authentication-results { remove = 0; }
      }
      """,
      "/etc/dovecot/conf.d/99-hostctl-spam.conf" => dovecot(setting),
      "#{@sieve_dir}/delivery.sieve" => delivery_sieve(setting, policies),
      "#{@sieve_dir}/learn-spam.sieve" => """
      require ["vnd.dovecot.pipe", "copy", "imapsieve", "environment"];
      if allof (environment :is "imap.cause" "COPY",
                not environment :is "imap.mailbox" "Trash") {
        pipe :copy "learn-spam";
      }
      """,
      "#{@sieve_dir}/learn-ham.sieve" => """
      require ["vnd.dovecot.pipe", "copy", "imapsieve", "environment"];
      if allof (environment :is "imap.cause" "COPY",
                environment :is "imap.mailbox" "INBOX") {
        pipe :copy "learn-ham";
      }
      """,
      "#{@sieve_dir}/bin/learn-spam" => learning_script("spam"),
      "#{@sieve_dir}/bin/learn-ham" => learning_script("ham")
    }
  end

  defp dkim([]), do: "enabled = false;\n"

  defp dkim(domains) do
    entries =
      Enum.map_join(domains, "\n", fn setting ->
        domain = setting.domain.name
        selector = setting.selector
        true = Hostctl.EmailDelivery.Setting.hostname?(domain)
        true = Regex.match?(~r/\Ahc[a-f0-9]{16}\z/, selector)

        "#{Jason.encode!(domain)} { selector = #{Jason.encode!(selector)}; path = #{Jason.encode!("/var/lib/hostctl/dkim/#{domain}/#{selector}.key")}; }"
      end)

    """
    enabled = true;
    sign_authenticated = true;
    sign_local = false;
    sign_inbound = false;
    allow_username_mismatch = false;
    allow_hdrfrom_mismatch = false;
    use_esld = false;
    try_fallback = false;
    domain {
      #{entries}
    }
    """
  end

  defp learning_script(kind) do
    """
    #!/bin/sh
    # Input comes only from Dovecot's global IMAPSieve hook.
    if /usr/bin/timeout 8 /usr/bin/rspamc -h /run/rspamd/hostctl-controller.sock learn_#{kind} >/dev/null 2>&1; then
      /usr/bin/logger -t hostctl-spam "learn_#{kind} completed"
    else
      /usr/bin/logger -t hostctl-spam "learn_#{kind} failed; check Rspamd and Redis"
    fi
    # A learning outage must not prevent the user's mailbox move.
    exit 0
    """
  end

  defp dovecot(setting) do
    feedback =
      if setting.learning do
        """
        imapsieve_mailbox1_name = Junk
        imapsieve_mailbox1_causes = COPY
        imapsieve_mailbox1_before = file:#{@sieve_dir}/learn-spam.sieve
        imapsieve_mailbox2_name = INBOX
        imapsieve_mailbox2_from = Junk
        imapsieve_mailbox2_causes = COPY
        imapsieve_mailbox2_before = file:#{@sieve_dir}/learn-ham.sieve
        """
      else
        ""
      end

    """
    # Managed by Hostctl Spam Protection. Dovecot 2.3 / Pigeonhole.
    protocols = $protocols lmtp
    protocol lmtp {
      mail_plugins = $mail_plugins sieve
      postmaster_address = postmaster@localhost
    }
    service lmtp {
      unix_listener /var/spool/postfix/private/hostctl-lmtp {
        mode = 0600
        user = postfix
        group = postfix
      }
    }
    protocol imap {
      mail_plugins = $mail_plugins imap_sieve
    }
    namespace inbox {
      mailbox Junk {
        auto = subscribe
        special_use = \\Junk
      }
    }
    plugin {
      sieve_before = #{@sieve_dir}/delivery.sieve
      sieve_extensions = +editheader
      sieve_plugins = sieve_imapsieve sieve_extprograms
      sieve_global_extensions = +vnd.dovecot.pipe
      sieve_pipe_bin_dir = #{@sieve_dir}/bin
      #{feedback}
    }
    """
  end

  def delivery_sieve(setting, policies) do
    overrides =
      Enum.map_join(policies, "\n", fn policy ->
        address = "#{policy.email_account.username}@#{policy.email_account.domain.name}"

        """
        if envelope :is "to" #{quote_sieve(address)} {
          #{sender_rule(policy.block_senders, :block)}
          #{sender_rule(policy.allow_senders, :allow)}
          #{score_rule(policy.junk_score || setting.junk_score)}
          keep;
          stop;
        }
        """
      end)

    """
    require ["fileinto", "mailbox", "envelope", "editheader"];
    # Discard untrusted explanations before adding our own.
    deleteheader "X-Hostctl-Junk-Reason";
    #{overrides}
    #{score_rule(setting.junk_score)}
    """
  end

  defp score_rule(score) when is_integer(score) and score in 1..20 do
    """
    if header :contains "X-Hostctl-Spam-Level" #{quote_sieve(String.duplicate("*", score))} {
      addheader "X-Hostctl-Junk-Reason" "Spam score reached mailbox threshold #{score}; see X-Spamd-Result";
      fileinto :create "Junk";
      stop;
    }
    """
  end

  defp sender_rule(value, action) do
    case MailboxPolicy.senders(value) do
      [] ->
        ""

      addresses ->
        result =
          if action == :block do
            "addheader \"X-Hostctl-Junk-Reason\" \"Mailbox blocked sender rule\"; fileinto :create \"Junk\";"
          else
            "keep;"
          end

        "if envelope :is \"from\" [#{Enum.map_join(addresses, ", ", &quote_sieve/1)}] { #{result} stop; }"
    end
  end

  defp quote_sieve(value) do
    "\"" <>
      (value
       |> String.replace("\\", "\\\\")
       |> String.replace("\"", "\\\"")
       |> String.replace("\r", "")
       |> String.replace("\n", "")) <> "\""
  end
end
