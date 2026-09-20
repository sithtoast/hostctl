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
    render_async(view, 5_000)
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

  test "creates a subdomain mapping, preserves a chosen port, and toggles WebSockets", %{
    conn: conn
  } do
    command = Path.join(System.tmp_dir!(), "hostctl-docker-#{Ecto.UUID.generate()}")

    File.write!(command, """
    #!/bin/sh
    case "$1" in
      version) echo 'test' ;;
      ps) echo '{"ID":"123","Names":"sample-app","Image":"sample:latest","Status":"Up 1 hour","Ports":"127.0.0.1:8080->80/tcp, 127.0.0.1:9443->443/tcp"}' ;;
      compose) echo '[]' ;;
    esac
    """)

    File.chmod!(command, 0o700)
    previous = Application.get_env(:hostctl, :docker)
    Application.put_env(:hostctl, :docker, command: [command])

    on_exit(fn ->
      File.rm(command)

      if previous,
        do: Application.put_env(:hostctl, :docker, previous),
        else: Application.delete_env(:hostctl, :docker)
    end)

    admin = admin_user_fixture()

    {:ok, domain} =
      Hostctl.Hosting.create_domain(user_scope_fixture(admin), %{
        name: "proxy-ui.example",
        apply_dns_template: false
      })

    {:ok, view, _} = live(log_in_user(conn, admin), "/panel/docker")
    render_async(view, 5_000)
    view |> element("#docker-tab-proxies") |> render_click()
    assert has_element?(view, "#domain_proxy_websocket_enabled[checked]")

    params = %{
      domain_id: domain.id,
      subdomain: "app",
      path: "/",
      container_name: "sample-app",
      upstream_port: "9443",
      upstream_scheme: "https",
      websocket_enabled: false,
      enabled: true
    }

    view |> form("#docker-proxy-form", domain_proxy: params) |> render_change()
    assert has_element?(view, "#domain_proxy_upstream_port[value='9443']")
    view |> form("#docker-proxy-form", domain_proxy: params) |> render_submit()
    [proxy] = Hostctl.Hosting.list_domain_proxies(domain)
    assert proxy.subdomain == "app"
    assert proxy.upstream_scheme == "https"
    assert proxy.upstream_port == 9443
    refute proxy.websocket_enabled
    assert has_element?(view, "#proxies-#{proxy.id}", "app.proxy-ui.example/")
    assert has_element?(view, "#toggle-proxy-websocket-#{proxy.id}[aria-checked=false]")
    view |> element("#toggle-proxy-websocket-#{proxy.id}") |> render_click()
    assert has_element?(view, "#toggle-proxy-websocket-#{proxy.id}[aria-checked=true]")
    assert Hostctl.Repo.get!(Hostctl.Hosting.DomainProxy, proxy.id).websocket_enabled
    view |> element("#delete-domain-proxy-#{proxy.id}") |> render_click()
    refute has_element?(view, "#proxies-#{proxy.id}")
  end

  test "customers cannot open the server Docker controls", %{conn: conn} do
    customer = user_fixture()
    assert {:error, {:redirect, _}} = live(log_in_user(conn, customer), "/panel/docker")
  end
end
