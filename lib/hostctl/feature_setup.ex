defmodule Hostctl.FeatureSetup do
  @moduledoc """
  Registry of optional panel features and their server-side setup routines.

  Each feature is defined with:
    - `:key` — unique identifier stored in `feature_settings`
    - `:label` — human-readable name
    - `:description` — what the feature provides
    - `:icon` — heroicon name for the UI
    - `:packages` — apt packages to install
    - `:services` — systemd services to enable/start
    - `:setup_fn` — optional extra setup (write config files, etc.)

  Setup is performed asynchronously so the admin can watch progress in real-time
  via PubSub. The install runs on the server via `System.cmd/3`.
  """

  require Logger

  alias Hostctl.Settings
  alias Hostctl.MailServer

  @features [
    %{
      key: "ftp",
      label: "FTP Server",
      description:
        "Virtual FTP hosting with vsftpd. Enables per-domain FTP accounts with chroot isolation.",
      icon: "hero-folder",
      packages: ["vsftpd", "db-util"],
      services: ["vsftpd"],
      setup_fn: :setup_vsftpd
    },
    %{
      key: "email",
      label: "Email Server",
      description:
        "Email hosting with Postfix and Dovecot. Enables per-domain email accounts with IMAP/SMTP.",
      icon: "hero-envelope",
      packages: ["postfix", "dovecot-imapd", "dovecot-pop3d"],
      services: ["postfix", "dovecot"],
      setup_fn: :setup_postfix
    },
    %{
      key: "cron",
      label: "Cron Jobs",
      description:
        "Scheduled task management. Write user crontabs for domain-level scheduled commands.",
      icon: "hero-clock",
      packages: [],
      services: ["cron"],
      setup_fn: nil
    },
    %{
      key: "docker",
      label: "Docker",
      description:
        "Container platform for running isolated applications. Enables proxy mapping of containers to domain paths and compose stack management.",
      icon: "hero-cube",
      packages: ["docker.io"],
      services: ["docker"],
      setup_fn: nil
    },
    %{
      key: "roundcube",
      label: "Roundcube Webmail",
      description:
        "Feature-rich webmail client with full IMAP support, address book, and plugin system. Accessible at /roundcube.",
      icon: "hero-inbox-stack",
      packages: [
        "roundcube",
        "roundcube-core",
        "roundcube-sqlite3",
        "roundcube-plugins",
        "apache2",
        "libapache2-mod-php",
        "php-sqlite3",
        "php-mbstring",
        "php-xml",
        "php-intl",
        "php-zip"
      ],
      services: [],
      setup_fn: :setup_roundcube
    },
    %{
      key: "snappymail",
      label: "SnappyMail",
      description:
        "Lightweight, modern webmail client (successor to RainLoop). Fast, mobile-friendly UI accessible at /snappymail.",
      icon: "hero-bolt",
      packages: [
        "apache2",
        "libapache2-mod-php",
        "php-curl",
        "php-xml",
        "php-mbstring",
        "php-json",
        "unzip"
      ],
      services: [],
      setup_fn: :setup_snappymail
    },
    %{
      key: "mysql",
      label: "MySQL Server",
      description:
        "MySQL database server for hosted applications like WordPress. Enables per-domain MySQL database and user management.",
      icon: "hero-circle-stack",
      packages: ["mysql-server", "mysql-client"],
      services: ["mysql"],
      setup_fn: :setup_mysql,
      conflicts: ["mariadb"]
    },
    %{
      key: "mariadb",
      label: "MariaDB Server",
      description:
        "MariaDB database server — a fully open-source MySQL drop-in replacement and the default on Debian. Enables per-domain database and user management.",
      icon: "hero-circle-stack",
      packages: ["mariadb-server", "mariadb-client"],
      services: ["mariadb"],
      setup_fn: :setup_mariadb,
      conflicts: ["mysql"]
    }
  ]

  @doc "Returns the list of all available feature definitions."
  def available_features, do: @features

  @doc "Returns the feature definition map for a given key, or nil."
  def get_feature(key) do
    Enum.find(@features, &(&1.key == key))
  end

  @doc """
  Reconciles each feature's DB state with the actual running system.

  For service-based features that are recorded as `not_installed` but whose
  systemd services are all currently active, this marks them as `installed`.
  This handles features that were installed outside the panel (e.g. via
  `install.sh`) without a prior panel interaction.
  """
  def reconcile_installed_features do
    for feature <- @features, feature.services != [] do
      setting = Settings.get_feature_setting(feature.key)

      if setting.status == "not_installed" and services_active?(feature.services) do
        Settings.save_feature_setting(feature.key, %{
          enabled: true,
          status: "installed",
          status_message: nil
        })
      end
    end

    :ok
  end

  defp services_active?(services) do
    Enum.all?(services, fn service ->
      case System.cmd("systemctl", ["is-active", "--quiet", service], stderr_to_stdout: true) do
        {_, 0} -> true
        _ -> false
      end
    end)
  end

  @doc """
  Installs a feature asynchronously. Broadcasts progress to
  `"feature_setup:<key>"` via PubSub.

  Performs: apt install → systemd enable/start → custom setup → mark installed.
  """
  def install(key) do
    feature = get_feature(key)

    if feature do
      Task.start(fn -> do_install(feature) end)
      :ok
    else
      {:error, :unknown_feature}
    end
  end

  @doc """
  Uninstalls a feature: stops services and marks it as not_installed.
  Does NOT remove packages (that's destructive and could affect other services).
  """
  def uninstall(key) do
    feature = get_feature(key)

    if feature do
      Task.start(fn -> do_uninstall(feature) end)
      :ok
    else
      {:error, :unknown_feature}
    end
  end

  # ---------------------------------------------------------------------------
  # Install pipeline
  # ---------------------------------------------------------------------------

  defp do_install(feature) do
    broadcast(feature.key, :log, "Starting installation of #{feature.label}...")

    Settings.save_feature_setting(feature.key, %{
      status: "installing",
      status_message: "Installing..."
    })

    broadcast(feature.key, :status_changed, "installing")

    with :ok <- check_sudo_access(feature),
         :ok <- resolve_conflicts(feature),
         :ok <- install_packages(feature),
         :ok <- enable_services(feature),
         :ok <- run_setup(feature) do
      Settings.save_feature_setting(feature.key, %{
        enabled: true,
        status: "installed",
        status_message: nil
      })

      broadcast(feature.key, :log, "#{feature.label} installed successfully.")
      broadcast(feature.key, :status_changed, "installed")
    else
      {:error, reason} ->
        message = "Installation failed: #{inspect(reason)}"

        Settings.save_feature_setting(feature.key, %{
          enabled: false,
          status: "failed",
          status_message: message
        })

        broadcast(feature.key, :log, message)
        broadcast(feature.key, :status_changed, "failed")
    end
  end

  defp do_uninstall(feature) do
    broadcast(feature.key, :log, "Disabling #{feature.label}...")

    Settings.save_feature_setting(feature.key, %{
      status: "installing",
      status_message: "Disabling..."
    })

    broadcast(feature.key, :status_changed, "installing")

    Enum.each(feature.services, fn service ->
      broadcast(feature.key, :log, "Stopping #{service}...")
      escaped_cmd("systemctl", ["stop", service], stderr_to_stdout: true)
      escaped_cmd("systemctl", ["disable", service], stderr_to_stdout: true)
    end)

    Settings.save_feature_setting(feature.key, %{
      enabled: false,
      status: "not_installed",
      status_message: nil
    })

    broadcast(feature.key, :log, "#{feature.label} disabled.")
    broadcast(feature.key, :status_changed, "not_installed")
  end

  # ---------------------------------------------------------------------------
  # Steps
  # ---------------------------------------------------------------------------

  # Verify the service user can run sudo without a password prompt.
  # Uses /usr/bin/true which is explicitly allowed in the hostctl-features sudoers file.
  defp check_sudo_access(%{key: key}) do
    broadcast(key, :log, "Checking sudo access...")

    case System.cmd("sudo", ["-n", "/usr/bin/true"], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {output, _code} ->
        message =
          "sudo is not available without a password. " <>
            "Run 'sudo /opt/hostctl/bin/repair' on the server to fix permissions, " <>
            "then restart the hostctl service."

        broadcast(key, :log, message)

        for line <- String.split(output, "\n", trim: true) do
          broadcast(key, :log, line)
        end

        {:error, :sudo_not_configured}
    end
  end

  defp install_packages(%{packages: []}), do: :ok

  defp install_packages(%{key: key} = feature) do
    :ok = preseed_debconf(feature)

    packages = feature.packages
    broadcast(key, :log, "Installing packages: #{Enum.join(packages, ", ")}...")

    args = ["install", "-y", "--no-install-recommends"] ++ packages

    case escaped_cmd("apt-get", args,
           env: [{"DEBIAN_FRONTEND", "noninteractive"}],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        for line <- String.split(output, "\n", trim: true) do
          broadcast(key, :log, line)
        end

        :ok

      {output, code} ->
        broadcast(key, :log, "apt-get failed (exit #{code})")

        for line <- String.split(output, "\n", trim: true) do
          broadcast(key, :log, line)
        end

        {:error, {:apt_failed, code}}
    end
  end

  # Pre-seed debconf selections to avoid interactive prompts during apt install.
  # Override Roundcube's default MySQL backend with SQLite.
  defp preseed_debconf(%{key: "roundcube"} = feature) do
    broadcast(feature.key, :log, "Pre-seeding debconf for Roundcube (SQLite backend)...")

    selections = """
    roundcube-core roundcube/dbconfig-install boolean true
    roundcube-core roundcube/database-type select sqlite3
    """

    case escaped_cmd(
           "sh",
           ["-c", "echo '#{Base.encode64(selections)}' | base64 -d | debconf-set-selections"],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      {output, code} ->
        broadcast(feature.key, :log, "debconf pre-seed failed (exit #{code}): #{output}")
        :ok
    end
  end

  defp preseed_debconf(_feature), do: :ok

  defp enable_services(%{services: []}), do: :ok

  defp enable_services(%{key: key, services: services}) do
    Enum.reduce_while(services, :ok, fn service, :ok ->
      broadcast(key, :log, "Enabling and starting #{service}...")

      case escaped_cmd("systemctl", ["enable", "--now", service], stderr_to_stdout: true) do
        {_, 0} ->
          {:cont, :ok}

        {output, code} ->
          broadcast(key, :log, "Failed to enable #{service} (exit #{code}): #{output}")
          {:halt, {:error, {:service_failed, service, code}}}
      end
    end)
  end

  defp run_setup(%{setup_fn: nil}), do: :ok
  defp run_setup(%{setup_fn: func} = feature), do: apply(__MODULE__, func, [feature.key])

  defp resolve_conflicts(%{key: key} = feature) do
    conflicts = Map.get(feature, :conflicts, [])

    Enum.reduce_while(conflicts, :ok, fn conflict_key, :ok ->
      setting = Settings.get_feature_setting(conflict_key)

      if setting.enabled and setting.status == "installed" do
        conflict = get_feature(conflict_key)

        broadcast(
          key,
          :log,
          "#{conflict.label} is installed and conflicts — disabling it first..."
        )

        Enum.each(conflict.services, fn service ->
          broadcast(key, :log, "Stopping #{service}...")
          escaped_cmd("systemctl", ["stop", service], stderr_to_stdout: true)
          escaped_cmd("systemctl", ["disable", service], stderr_to_stdout: true)
        end)

        Settings.save_feature_setting(conflict_key, %{
          enabled: false,
          status: "not_installed",
          status_message: nil
        })

        Phoenix.PubSub.broadcast(
          Hostctl.PubSub,
          "feature_setup:#{conflict_key}",
          {:status_changed, "not_installed"}
        )

        broadcast(key, :log, "#{conflict.label} disabled.")
      end

      {:cont, :ok}
    end)
  end

  # ---------------------------------------------------------------------------
  # Feature-specific setup
  # ---------------------------------------------------------------------------

  @doc false
  def setup_postfix(key) do
    broadcast(key, :log, "Applying Postfix configuration...")

    with :ok <- configure_dovecot_virtual_users(key),
         :ok <- MailServer.sync_virtual_mailboxes() do
      smarthost = Settings.get_smarthost_setting()

      if smarthost.enabled do
        broadcast(key, :log, "Smarthost is configured — applying relay settings to Postfix...")

        case MailServer.apply_smarthost(smarthost) do
          :ok ->
            broadcast(key, :log, "Smarthost configured successfully.")
            :ok

          {:error, reason} ->
            broadcast(key, :log, "Smarthost configuration failed: #{inspect(reason)}")
            {:error, reason}
        end
      else
        broadcast(key, :log, "No smarthost configured — skipping relay setup.")
        :ok
      end
    end
  end

  defp configure_dovecot_virtual_users(key) do
    broadcast(key, :log, "Configuring Dovecot for virtual mail users...")

    with :ok <- run_cmd(key, "groupadd", ["-f", "-g", "5000", "vmail"]),
         :ok <- ensure_vmail_user(key),
         :ok <- run_cmd(key, "mkdir", ["-p", "/var/mail/vhosts"]),
         :ok <- run_cmd(key, "chown", ["-R", "vmail:vmail", "/var/mail/vhosts"]),
         :ok <- write_dovecot_passwd_file(key),
         :ok <- write_dovecot_hostctl_conf(key),
         :ok <- disable_dovecot_system_auth(key),
         :ok <- run_cmd(key, "systemctl", ["restart", "dovecot"]) do
      broadcast(key, :log, "Dovecot virtual user configuration complete.")
      :ok
    end
  end

  defp ensure_vmail_user(key) do
    case escaped_cmd("id", ["vmail"], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      _ ->
        run_cmd(key, "useradd", [
          "-g",
          "vmail",
          "-u",
          "5000",
          "-d",
          "/var/mail",
          "-M",
          "-s",
          "/usr/sbin/nologin",
          "vmail"
        ])
    end
  end

  defp write_dovecot_passwd_file(key) do
    broadcast(key, :log, "Creating /etc/dovecot/passwd...")

    with :ok <- write_file_via_sudo(key, "/etc/dovecot/passwd", ""),
         :ok <- run_cmd(key, "chown", ["root:dovecot", "/etc/dovecot/passwd"]) do
      run_cmd(key, "chmod", ["640", "/etc/dovecot/passwd"])
    end
  end

  defp write_dovecot_hostctl_conf(key) do
    broadcast(key, :log, "Writing /etc/dovecot/conf.d/99-hostctl.conf...")

    conf = """
    # Managed by hostctl — virtual mail user configuration

    mail_location = maildir:~/Maildir

    passdb {
      driver = passwd-file
      args = scheme=BLF-CRYPT username_format=%u /etc/dovecot/passwd
    }

    userdb {
      driver = passwd-file
      args = username_format=%u /etc/dovecot/passwd
      default_fields = uid=5000 gid=5000 home=/var/mail/vhosts/%d/%n
    }
    """

    write_file_via_sudo(key, "/etc/dovecot/conf.d/99-hostctl.conf", conf)
  end

  defp disable_dovecot_system_auth(key) do
    broadcast(key, :log, "Disabling Dovecot system auth in 10-auth.conf...")

    auth_conf = "/etc/dovecot/conf.d/10-auth.conf"

    case escaped_cmd(
           "sed",
           [
             "-i",
             "s|^!include auth-system\\.conf\\.ext|# !include auth-system.conf.ext|",
             auth_conf
           ],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      {output, code} ->
        broadcast(key, :log, "Warning: could not update 10-auth.conf (exit #{code}): #{output}")
        :ok
    end
  end

  @doc false
  def setup_vsftpd(key) do
    broadcast(key, :log, "Configuring vsftpd for virtual users...")

    conf_dir = "/etc/vsftpd/vsftpd_user_conf"
    users_file = "/etc/vsftpd/virtual_users.txt"

    with :ok <- run_cmd(key, "mkdir", ["-p", conf_dir]),
         :ok <- run_cmd(key, "touch", [users_file]),
         :ok <- run_cmd(key, "chmod", ["600", users_file]),
         :ok <- write_vsftpd_pam(key),
         :ok <- write_vsftpd_conf(key) do
      broadcast(key, :log, "vsftpd configuration complete.")
      :ok
    end
  end

  defp write_vsftpd_pam(key) do
    broadcast(key, :log, "Writing PAM config for vsftpd virtual users...")

    pam_content = """
    auth required pam_userdb.so db=/etc/vsftpd/virtual_users
    account required pam_userdb.so db=/etc/vsftpd/virtual_users
    """

    write_file_via_sudo(key, "/etc/pam.d/vsftpd.virtual", pam_content)
  end

  defp write_vsftpd_conf(key) do
    broadcast(key, :log, "Writing vsftpd.conf...")

    conf = """
    listen=YES
    listen_ipv6=NO
    anonymous_enable=NO
    local_enable=YES
    write_enable=YES
    local_umask=022
    dirmessage_enable=YES
    use_localtime=YES
    xferlog_enable=YES
    connect_from_port_20=YES
    chroot_local_user=YES
    allow_writeable_chroot=YES
    secure_chroot_dir=/var/run/vsftpd/empty
    pam_service_name=vsftpd.virtual
    guest_enable=YES
    guest_username=www-data
    user_sub_token=$USER
    local_root=/var/www
    user_config_dir=/etc/vsftpd/vsftpd_user_conf
    virtual_use_local_privs=YES
    hide_ids=YES
    pasv_min_port=30000
    pasv_max_port=31000
    """

    write_file_via_sudo(key, "/etc/vsftpd.conf", conf)
  end

  @doc false
  def setup_roundcube(key) do
    broadcast(key, :log, "Configuring Roundcube Webmail...")

    config = """
    <?php
    $config['db_dsnw'] = 'sqlite:////var/lib/roundcube/roundcube.db?mode=0640';
    $config['imap_host'] = 'localhost:143';
    $config['smtp_host'] = 'localhost:25';
    $config['smtp_user'] = '';
    $config['smtp_pass'] = '';
    $config['product_name'] = 'hostctl Webmail';
    $config['des_key'] = '#{random_des_key()}';
    $config['plugins'] = ['archive', 'zipdownload'];
    $config['skin'] = 'elastic';
    """

    with :ok <- setup_apache_port(key),
         :ok <- uncomment_roundcube_alias(key),
         :ok <- run_cmd(key, "mkdir", ["-p", "/var/lib/roundcube"]),
         :ok <- run_cmd(key, "chown", ["www-data:www-data", "/var/lib/roundcube"]),
         :ok <- write_file_via_sudo(key, "/etc/roundcube/config.inc.php", config),
         :ok <- enable_apache_conf(key, "roundcube") do
      broadcast(key, :log, "Roundcube configuration complete.")
      broadcast(key, :log, "Webmail is available at /roundcube")
      :ok
    end
  end

  @doc false
  def setup_snappymail(key) do
    broadcast(key, :log, "Installing SnappyMail...")

    install_dir = "/var/www/snappymail"

    with :ok <- setup_apache_port(key),
         :ok <- run_cmd(key, "mkdir", ["-p", install_dir]),
         :ok <- download_snappymail(key, install_dir),
         :ok <- run_cmd(key, "chown", ["-R", "www-data:www-data", install_dir]),
         :ok <- write_snappymail_apache_conf(key),
         :ok <- enable_apache_conf(key, "snappymail") do
      broadcast(key, :log, "SnappyMail configuration complete.")
      broadcast(key, :log, "Webmail is available at /snappymail")

      broadcast(
        key,
        :log,
        "Admin panel: /snappymail/?admin (default password: 12345)"
      )

      :ok
    end
  end

  @doc false
  def setup_mysql(key) do
    broadcast(key, :log, "Securing MySQL installation...")

    password = mysql_root_password()

    with :ok <- secure_mysql(key, password),
         :ok <- update_mysql_env(key, password) do
      broadcast(key, :log, "MySQL configuration complete.")
      broadcast(key, :log, "Root password has been written to the hostctl env file.")
      :ok
    end
  end

  @doc false
  def setup_mariadb(key) do
    broadcast(key, :log, "Securing MariaDB installation...")

    password = mysql_root_password()

    with :ok <- secure_mysql(key, password),
         :ok <- update_mysql_env(key, password) do
      broadcast(key, :log, "MariaDB configuration complete.")
      broadcast(key, :log, "Root password has been written to the hostctl env file.")
      :ok
    end
  end

  defp secure_mysql(key, password) do
    broadcast(key, :log, "Setting MySQL root password and removing defaults...")

    # Compatible with MySQL 8.0 and MariaDB (avoids deprecated mysql_native_password)
    sql = """
    ALTER USER 'root'@'localhost' IDENTIFIED BY '#{password}';
    DELETE FROM mysql.user WHERE User='';
    DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
    DROP DATABASE IF EXISTS test;
    DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
    FLUSH PRIVILEGES;
    """

    encoded = Base.encode64(sql)

    # Fresh installs use auth_socket/unix_socket (no password). If that fails,
    # debconf may have set a root password — fall back to authenticating with it.
    {output, code} =
      case escaped_cmd("sh", ["-c", "echo '#{encoded}' | base64 -d | mysql -u root"],
             stderr_to_stdout: true
           ) do
        {_, 0} = ok ->
          ok

        {_, _} ->
          broadcast(key, :log, "Socket auth failed — trying password auth...")

          escaped_cmd(
            "sh",
            ["-c", "echo '#{encoded}' | base64 -d | mysql -u root -p'#{password}'"],
            stderr_to_stdout: true
          )
      end

    case code do
      0 ->
        :ok

      _ ->
        broadcast(key, :log, "MySQL secure setup failed (exit #{code}): #{output}")
        {:error, {:mysql_secure_failed, code}}
    end
  end

  defp update_mysql_env(key, password) do
    broadcast(key, :log, "Writing MYSQL_ROOT_URL to env file...")

    env_file = "/etc/hostctl/env"
    url = "mysql://root:#{password}@localhost:3306/mysql"

    # Remove any existing MYSQL_ROOT_URL line, then append the new one
    case escaped_cmd(
           "sh",
           [
             "-c",
             "grep -v '^MYSQL_ROOT_URL=' '#{env_file}' > '#{env_file}.tmp' 2>/dev/null; " <>
               "echo 'MYSQL_ROOT_URL=#{url}' >> '#{env_file}.tmp'; " <>
               "mv '#{env_file}.tmp' '#{env_file}'"
           ],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        broadcast(key, :log, "Restart hostctl to pick up the new MySQL configuration.")
        :ok

      {output, code} ->
        broadcast(key, :log, "Failed to update env file (exit #{code}): #{output}")
        {:error, {:env_update_failed, code}}
    end
  end

  defp mysql_root_password do
    # Re-use existing password from config, or generate a new one
    db_config = Application.get_env(:hostctl, :database_server, [])

    case Keyword.get(db_config, :password) do
      pw when is_binary(pw) and pw != "" -> pw
      _ -> :crypto.strong_rand_bytes(24) |> Base.url_encode64() |> binary_part(0, 32)
    end
  end

  defp download_snappymail(key, install_dir) do
    broadcast(key, :log, "Downloading latest SnappyMail release...")

    url = "https://snappymail.eu/repository/latest.tar.gz"

    case escaped_cmd(
           "sh",
           ["-c", "curl -fsSL '#{url}' | tar xz -C '#{install_dir}'"],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        broadcast(key, :log, "SnappyMail downloaded and extracted.")
        :ok

      {output, code} ->
        broadcast(key, :log, "Download failed (exit #{code}): #{output}")
        {:error, {:download_failed, code}}
    end
  end

  defp write_snappymail_apache_conf(key) do
    broadcast(key, :log, "Writing Apache config for SnappyMail...")

    conf = """
    Alias /snappymail /var/www/snappymail

    <Directory /var/www/snappymail>
        Options -Indexes
        AllowOverride All
        Require all granted

        <FilesMatch "\\.php$">
            SetHandler application/x-httpd-php
        </FilesMatch>
    </Directory>

    <Directory /var/www/snappymail/data>
        Require all denied
    </Directory>
    """

    write_file_via_sudo(key, "/etc/apache2/conf-available/snappymail.conf", conf)
  end

  defp setup_apache_port(key) do
    broadcast(key, :log, "Configuring Apache to listen on 127.0.0.1:8080...")

    ports_conf = """
    Listen 127.0.0.1:8080
    """

    server_conf = """
    ServerName localhost
    """

    with :ok <- write_file_via_sudo(key, "/etc/apache2/ports.conf", ports_conf),
         :ok <-
           write_file_via_sudo(key, "/etc/apache2/conf-available/servername.conf", server_conf),
         {_, 0} <- escaped_cmd("a2enconf", ["servername"], stderr_to_stdout: true),
         :ok <- fix_default_vhost(key) do
      :ok
    else
      {output, code} ->
        broadcast(key, :log, "Failed to configure Apache port (exit #{code}): #{output}")
        {:error, {:apache_port_failed, code}}
    end
  end

  # Update the default VirtualHost to match port 8080 instead of 80
  defp fix_default_vhost(key) do
    broadcast(key, :log, "Updating default VirtualHost to port 8080...")

    case escaped_cmd(
           "sed",
           [
             "-i",
             "s/<VirtualHost \\*:80>/<VirtualHost *:8080>/",
             "/etc/apache2/sites-available/000-default.conf"
           ],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      {_, _} ->
        # File may not exist on minimal installs — not fatal
        broadcast(key, :log, "No default VirtualHost to update (OK)")
        :ok
    end
  end

  # Debian's roundcube.conf ships with the Alias line commented out by default.
  # Uncomment it so /roundcube actually maps to the Roundcube public_html dir.
  defp uncomment_roundcube_alias(key) do
    broadcast(key, :log, "Ensuring Roundcube Alias is enabled...")

    conf = "/etc/apache2/conf-available/roundcube.conf"

    case escaped_cmd(
           "sed",
           ["-i", ~s(s|^#[[:space:]]*Alias /roundcube|Alias /roundcube|), conf],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {_, _} -> :ok
    end
  end

  defp enable_apache_conf(key, conf_name) do
    broadcast(key, :log, "Enabling Apache config for #{conf_name}...")

    with {_, 0} <- escaped_cmd("a2enconf", [conf_name], stderr_to_stdout: true),
         :ok <- restart_apache(key) do
      :ok
    else
      {output, code} ->
        broadcast(key, :log, "Failed to enable Apache config (exit #{code}): #{output}")
        {:error, {:apache_conf_failed, code}}
    end
  end

  defp restart_apache(key) do
    broadcast(key, :log, "Restarting Apache...")

    # Enable and start (or restart) Apache — handles both fresh installs and reconfigs
    case escaped_cmd("systemctl", ["enable", "--now", "apache2"], stderr_to_stdout: true) do
      {_, 0} ->
        # If already running, a restart ensures config is picked up
        escaped_cmd("systemctl", ["restart", "apache2"], stderr_to_stdout: true)
        :ok

      {output, code} ->
        broadcast(key, :log, "Failed to start Apache (exit #{code}): #{output}")
        {:error, {:apache_start_failed, code}}
    end
  end

  defp random_des_key do
    :crypto.strong_rand_bytes(24) |> Base.encode64() |> binary_part(0, 24)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Run a command outside the service's ProtectSystem=strict mount namespace.
  # systemd-run creates a transient unit that talks to PID 1 over D-Bus,
  # so the spawned process has a clean, unrestricted filesystem view.
  defp escaped_cmd(cmd, args, opts) do
    {env_vars, cmd_opts} = Keyword.pop(opts, :env, [])

    env_args =
      Enum.flat_map(env_vars, fn {k, v} ->
        ["--property", "Environment=#{k}=#{v}"]
      end)

    systemd_args = ["systemd-run", "--pipe", "--wait", "--collect", "--quiet"] ++ env_args

    System.cmd("sudo", systemd_args ++ [cmd | args], cmd_opts)
  end

  defp run_cmd(key, cmd, args) do
    case escaped_cmd(cmd, args, stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {output, code} ->
        broadcast(key, :log, "Command failed: #{cmd} #{Enum.join(args, " ")} (exit #{code})")
        broadcast(key, :log, output)
        {:error, {:cmd_failed, cmd, code}}
    end
  end

  defp write_file_via_sudo(key, path, content) do
    # Pipe base64-encoded content through systemd-run tee.
    # systemd-run creates a transient unit with a clean mount namespace,
    # so we can't use temp files (they wouldn't be visible across namespaces).
    # Path is always a hardcoded config path from our code, never user input.
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
        case escaped_cmd("chmod", ["644", path], stderr_to_stdout: true) do
          {_, 0} ->
            :ok

          {output, code} ->
            broadcast(key, :log, "Failed to chmod #{path} (exit #{code}): #{output}")
            {:error, {:write_failed, path}}
        end

      {output, code} ->
        broadcast(key, :log, "Failed to write #{path} (exit #{code}): #{output}")
        {:error, {:write_failed, path}}
    end
  end

  defp broadcast(key, event, data) do
    Phoenix.PubSub.broadcast(Hostctl.PubSub, "feature_setup:#{key}", {event, data})
  end
end
