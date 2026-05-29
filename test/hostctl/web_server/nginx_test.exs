defmodule Hostctl.WebServer.NginxTest do
  use ExUnit.Case, async: true

  alias Hostctl.Hosting.Domain
  alias Hostctl.Hosting.DomainS3Backend
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

  test "emits ssl for whole-subdomain s3 backends" do
    config =
      Nginx.generate_config(
        %Domain{name: "example.com", ssl_enabled: true, allow_http_with_ssl: true},
        [],
        %SslCertificate{status: "active", cert_type: "custom"},
        [],
        [
          %DomainS3Backend{
            id: 4,
            subdomain: "static",
            endpoint_url: "https://s3.example.com",
            bucket: "static-assets",
            access_key_id: "key",
            secret_access_key: "secret"
          }
        ]
      )

    assert config =~ "server_name static.example.com;"
    assert config =~ "listen 443 ssl http2;"
    assert config =~ "proxy_pass http://127.0.0.1:4000/_s3_proxy/4/;"
  end
end
