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
