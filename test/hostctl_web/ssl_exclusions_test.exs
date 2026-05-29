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
end
