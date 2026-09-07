defmodule HostctlWeb.DockerInterfaceTest do
  use HostctlWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Hostctl.AccountsFixtures

  test "unavailable Docker keeps navigation and refresh usable", %{conn: conn} do
    previous = Application.get_env(:hostctl, :docker)
    Application.put_env(:hostctl, :docker, command: [System.find_executable("false")])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:hostctl, :docker, previous),
        else: Application.delete_env(:hostctl, :docker)
    end)

    admin = admin_user_fixture()

    {:ok, domain} =
      Hostctl.Hosting.create_domain(user_scope_fixture(admin), %{
        name: "docker-view.example",
        apply_dns_template: false
      })

    proxy =
      Hostctl.Repo.insert!(%Hostctl.Hosting.DomainProxy{
        domain_id: domain.id,
        path: "/",
        container_name: "example-app",
        upstream_port: 8080
      })

    {:ok, view, _} = live(log_in_user(conn, admin), "/panel/docker")
    render_async(view)
    assert has_element?(view, "#docker-unavailable")
    assert has_element?(view, "#docker-refresh-btn:not([disabled])")
    view |> element("#docker-tab-proxies") |> render_click()
    assert has_element?(view, "#docker-tab-proxies[aria-pressed=true]")
    view |> element("#docker-tab-images") |> render_click()
    assert has_element?(view, "#docker-tab-images[aria-pressed=true]")
    view |> element("#docker-tab-proxies") |> render_click()
    assert has_element?(view, "#proxies-#{proxy.id}")
    view |> element("#docker-tab-containers") |> render_click()

    view
    |> form("#docker-container-filters", %{query: "missing", state: "running"})
    |> render_change()

    assert has_element?(view, "#docker-containers-empty")
  end
end
