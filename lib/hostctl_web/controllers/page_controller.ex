defmodule HostctlWeb.PageController do
  use HostctlWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
