defmodule HostctlWeb.SSLExclusions do
  @moduledoc false

  @doc """
  Returns true for request paths that should bypass `Plug.SSL` redirects.
  """
  def exclude_force_ssl?(conn) do
    case conn.path_info do
      ["_s3_proxy" | _rest] -> true
      _ -> false
    end
  end
end
