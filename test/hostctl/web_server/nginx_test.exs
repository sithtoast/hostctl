defmodule Hostctl.WebServer.NginxTest do
  use ExUnit.Case, async: true

  alias Hostctl.Hosting.Domain
  alias Hostctl.Hosting.SslCertificate
  alias Hostctl.WebServer.Nginx

  test "redirects HTTP to HTTPS by default when SSL is active" do
    config =
      Nginx.generate_config(
        %Domain{name: "example.com", ssl_enabled: true, allow_http_with_ssl: false},
        [],
        %SslCertificate{status: "active", cert_type: "custom"}
      )

    assert config =~ "return 301 https://$host$request_uri;"
    assert config =~ "listen 443 ssl http2;"
  end

  test "keeps HTTP enabled when configured alongside active SSL" do
    config =
      Nginx.generate_config(
        %Domain{name: "example.com", ssl_enabled: true, allow_http_with_ssl: true},
        [],
        %SslCertificate{status: "active", cert_type: "custom"}
      )

    refute config =~ "return 301 https://$host$request_uri;"
    assert config =~ "listen 80;"
    assert config =~ "listen 443 ssl http2;"
    assert length(Regex.scan(~r/server_name example\.com www\.example\.com;/, config)) == 2
  end
end
