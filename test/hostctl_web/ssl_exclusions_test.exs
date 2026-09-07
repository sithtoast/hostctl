defmodule HostctlWeb.SSLExclusionsTest do
  use ExUnit.Case, async: true

  alias HostctlWeb.SSLExclusions

  test "excludes all _s3_proxy routes" do
    conn = Plug.Test.conn(:get, "/_s3_proxy/4/index.html")

    assert SSLExclusions.exclude_force_ssl?(conn)
  end

  test "does not exclude non s3 proxy routes" do
    conn = Plug.Test.conn(:get, "/users/log-in")

    refute SSLExclusions.exclude_force_ssl?(conn)
  end

  test "shared production and VM policy redirects panel HTTP but preserves S3 HTTP" do
    config = Config.Reader.read!("config/ssl.exs", env: :prod, target: :host)
    options = Plug.SSL.init(config[:hostctl][HostctlWeb.Endpoint][:force_ssl])

    proxy =
      :get
      |> Plug.Test.conn("http://panel.example.test/_s3_proxy/4/index.html")
      |> Plug.SSL.call(options)

    refute proxy.halted
    assert proxy.scheme == :http

    panel =
      :get
      |> Plug.Test.conn("http://panel.example.test/users/log-in")
      |> Plug.SSL.call(options)

    assert panel.status == 301

    assert Plug.Conn.get_resp_header(panel, "location") ==
             ["https://panel.example.test/users/log-in"]
  end
end
