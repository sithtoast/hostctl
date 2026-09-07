import Config

# Ecto query parameters can include decrypted import credentials.
config :hostctl, Hostctl.Repo, log: false
config :logger, level: :info

# Opt in only on a provisioned test VM. Keep dev code reloading and watchers.
config :hostctl, :web_server, enabled: true
config :hostctl, :ftp_server, enabled: true
config :hostctl, :database_server, enabled: true
config :hostctl, :postgres_server, enabled: true
config :hostctl, Hostctl.Backup.Runner, enabled: false

# Reproduce production redirects while developing, including the S3 exception.
import_config "ssl.exs"
