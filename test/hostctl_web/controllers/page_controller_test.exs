defmodule HostctlWeb.PageControllerTest do
  use HostctlWeb.ConnCase

  test "GET / redirects to login when unauthenticated", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/users/log-in"
  end
end
