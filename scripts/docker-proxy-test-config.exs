# Synthetic config for test/docker_proxy/integration.py; does not start Hostctl.
alias Hostctl.Hosting.{Domain, DomainProxy}

config = Hostctl.WebServer.Nginx.generate_config(%Domain{name: "example.test"}, [], nil, [
  %DomainProxy{subdomain: "app", path: "/", upstream_port: 18080},
  %DomainProxy{subdomain: "plain", path: "/", upstream_port: 18080, websocket_enabled: false},
  %DomainProxy{subdomain: "secure", path: "/", upstream_port: 18443, upstream_scheme: "https"},
  %DomainProxy{subdomain: "api", path: "/api", upstream_port: 18080}
])
File.write!("/tmp/hostctl-docker-proxy.conf", config)
