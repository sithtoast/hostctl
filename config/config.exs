# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

import Config

config :hostctl, :scopes,
  user: [
    default: true,
    module: Hostctl.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: Hostctl.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :mime, :types, %{
  "text/yaml" => ["yml", "yaml"]
}

config :hostctl,
  ecto_repos: [Hostctl.Repo],
  generators: [timestamp_type: :utc_datetime]

# Web server (Nginx) integration
# Each domain gets a vhost file written to `nginx_sites_available_dir` and
# symlinked into `nginx_sites_enabled_dir`. The main nginx.conf should already
# contain: include /etc/nginx/sites-enabled/*;
#
# The `hostctl` service user needs write access to both sites-available and
# sites-enabled, and a sudoers rule to run `systemctl reload nginx`.
# The install.sh script sets this up automatically.
config :hostctl, :web_server,
  enabled: true,
  nginx_sites_available_dir: "/etc/nginx/sites-available",
  nginx_sites_enabled_dir: "/etc/nginx/sites-enabled",
  # Requires: hostctl ALL=(root) NOPASSWD: /usr/bin/systemctl reload nginx
  nginx_reload_cmd: ["sudo", "systemctl", "reload", "nginx"],
  # Directory for custom SSL certs (Let's Encrypt certs stay under /etc/letsencrypt)
  ssl_dir: "/etc/ssl/hostctl",
  # Ubuntu/Debian path; {version} is replaced with the domain's php_version
  php_fpm_socket_pattern: "/run/php/php{version}-fpm.sock",
  # Used to validate config syntax before reloading (nginx -t)
  nginx_validate_cmd: ["nginx", "-t"]

# FTP server (vsftpd) integration
# Virtual users are stored in a Berkeley DB file built from a plaintext list.
# vsftpd must be configured with PAM (`pam_userdb`) pointing at `virtual_users_db`.
# The per-user config directory (`vsftpd_user_conf_dir`) must be referenced in
# vsftpd.conf via `user_config_dir=<dir>`.
#
# The `hostctl` service user needs write access to the vsftpd config directories
# and `db_load` (from the `db-util` / `db5.3-util` package) must be installed.
# A sudoers rule is required to reload vsftpd:
#   hostctl ALL=(root) NOPASSWD: /usr/bin/systemctl reload vsftpd
config :hostctl, :ftp_server,
  enabled: true,
  vsftpd_user_conf_dir: "/etc/vsftpd/vsftpd_user_conf",
  virtual_users_file: "/etc/vsftpd/virtual_users.txt",
  # Path WITHOUT the .db extension – PAM and db_load append it automatically.
  virtual_users_db: "/etc/vsftpd/virtual_users",
  db_load_cmd: "db_load"

# Let's Encrypt / Certbot integration
# When Cloudflare is configured as the DNS provider the certbot-dns-cloudflare
# plugin is used automatically (DNS-01 challenge). Otherwise HTTP-01 webroot
# is used. The certbot binary and certbot-dns-cloudflare package must be
# installed on the host (e.g. apt install certbot python3-certbot-dns-cloudflare).
#
# Certbot is run as the hostctl service user (no sudo required). Certificates
# are stored in `letsencrypt_dir`, which must be owned and writable by the
# service user. The install.sh script creates this directory automatically.
#
# Set the account email via the CERTBOT_EMAIL environment variable or the
# :email key below. Without an email, --register-unsafely-without-email is
# passed to certbot.
config :hostctl, :certbot,
  enabled: true,
  certbot_cmd: "certbot",
  letsencrypt_dir: "/var/lib/hostctl/letsencrypt",
  # Seconds to wait for DNS TXT record propagation (DNS-01 challenge only).
  # Increase if Let's Encrypt reports the DNS record is not yet visible.
  dns_propagation_seconds: 60,
  email: nil

# MySQL database server integration
# Hostctl connects to the MySQL server with root-level credentials to
# create/drop databases and manage users for hosted applications (e.g.
# WordPress). The MySQL server itself should be installed on the host
# (e.g. apt install mysql-server) or run via Docker.
config :hostctl, :database_server,
  enabled: true,
  hostname: "localhost",
  port: 3306,
  username: "root",
  password: ""

# PostgreSQL server integration
# Hostctl connects to the PostgreSQL server with superuser credentials to
# create/drop databases and manage users for hosted applications.
config :hostctl, :postgres_server,
  enabled: true,
  hostname: "localhost",
  port: 5432,
  username: "postgres",
  password: "postgres"

# Configure the endpoint
config :hostctl, HostctlWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: HostctlWeb.ErrorHTML, json: HostctlWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Hostctl.PubSub,
  live_view: [signing_salt: "e37warzn"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :hostctl, Hostctl.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  hostctl: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  hostctl: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
