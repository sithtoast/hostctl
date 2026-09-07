defmodule HostctlWeb.StaticAssetsTest do
  use ExUnit.Case, async: true
  alias HostctlWeb.StaticAssets

  test "development URLs change with asset content and remain stable otherwise" do
    path = "/assets/cache-test-#{System.unique_integer([:positive])}.css"
    file = Application.app_dir(:hostctl, "priv/static") <> path
    File.mkdir_p!(Path.dirname(file))
    on_exit(fn -> File.rm(file) end)
    File.write!(file, ".card { display: block; }")
    first = StaticAssets.path(path, true)
    assert first =~ "?v="
    assert StaticAssets.path(path, true) == first
    File.write!(file, ".card { display: grid; }")
    refute StaticAssets.path(path, true) == first

    assert StaticAssets.path(path, false) ==
             Phoenix.VerifiedRoutes.static_path(HostctlWeb.Endpoint, path)
  end

  test "missing development assets retain the normal path while watchers build" do
    path = "/assets/missing-#{System.unique_integer([:positive])}.css"

    assert StaticAssets.path(path, true) ==
             Phoenix.VerifiedRoutes.static_path(HostctlWeb.Endpoint, path)
  end
end
