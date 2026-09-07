import Config

config :hostctl, HostctlWeb.Endpoint,
  force_ssl: [
    rewrite_on: [:x_forwarded_proto],
    exclude: [
      hosts: ["localhost", "127.0.0.1"],
      conn: {HostctlWeb.SSLExclusions, :exclude_force_ssl?, []}
    ]
  ]
