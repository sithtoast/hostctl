defmodule Hostctl.DockerProxyTest do
  use Hostctl.DataCase, async: false
  import Hostctl.AccountsFixtures
  alias Hostctl.{Hosting, Repo}
  alias Hostctl.Hosting.{DomainProxy, DomainS3Backend, Subdomain}

  setup do
    admin = user_scope_fixture(admin_user_fixture())

    {:ok, domain} =
      Hosting.create_domain(admin, %{name: "docker-proxy.test", apply_dns_template: false})

    %{
      admin: admin,
      domain: domain,
      attrs: %{
        domain_id: domain.id,
        subdomain: "app",
        path: "/",
        container_name: "app",
        upstream_port: 8080
      }
    }
  end

  test "same path can serve different hostnames; duplicate hostname paths are rejected", %{
    admin: admin,
    attrs: attrs
  } do
    assert {:ok, proxy} = Hosting.create_domain_proxy(admin, Map.put(attrs, :subdomain, " APP "))
    assert DomainProxy.hostname(proxy) == "app.docker-proxy.test"
    assert proxy.websocket_enabled
    assert {:ok, _} = Hosting.create_domain_proxy(admin, %{attrs | subdomain: ""})
    assert {:ok, _} = Hosting.create_domain_proxy(admin, %{attrs | subdomain: "other"})
    assert {:error, changeset} = Hosting.create_domain_proxy(admin, attrs)
    assert %{path: ["has already been taken"]} = errors_on(changeset)
  end

  test "supports local HTTPS and persistent WebSocket switching", %{admin: admin, attrs: attrs} do
    assert {:ok, proxy} =
             Hosting.create_domain_proxy(
               admin,
               Map.merge(attrs, %{upstream_scheme: "https", websocket_enabled: false})
             )

    assert proxy.upstream_scheme == "https"
    refute proxy.websocket_enabled
    assert {:ok, updated} = Hosting.set_domain_proxy_websocket(admin, proxy, true)
    assert updated.websocket_enabled
    assert Repo.get!(DomainProxy, proxy.id).websocket_enabled
  end

  test "rejects unsafe hostnames, schemes and reserved www alias", %{admin: admin, attrs: attrs} do
    for subdomain <- [
          "www",
          "a.b",
          "../app",
          "app;include /tmp/evil",
          "app\nroot /",
          String.duplicate("a", 64)
        ] do
      assert {:error, changeset} =
               Hosting.create_domain_proxy(admin, %{attrs | subdomain: subdomain})

      assert errors_on(changeset).subdomain
    end

    assert {:error, changeset} =
             Hosting.create_domain_proxy(admin, Map.put(attrs, :upstream_scheme, "file"))

    assert errors_on(changeset).upstream_scheme
  end

  test "requires admin context even without the router", %{admin: admin, attrs: attrs} do
    customer = user_scope_fixture()
    assert {:error, _} = Hosting.create_domain_proxy(customer, attrs)
    assert {:ok, proxy} = Hosting.create_domain_proxy(admin, attrs)
    assert {:error, _} = Hosting.set_domain_proxy_websocket(customer, proxy, false)
    assert {:error, _} = Hosting.delete_domain_proxy(customer, proxy)
    assert Repo.get!(DomainProxy, proxy.id).websocket_enabled
  end

  test "rejects suspended subdomains and existing whole-host S3 backends", %{
    admin: admin,
    domain: domain,
    attrs: attrs
  } do
    sub = Repo.insert!(%Subdomain{domain_id: domain.id, name: "app", status: "suspended"})
    assert {:error, changeset} = Hosting.create_domain_proxy(admin, attrs)
    assert errors_on(changeset).subdomain == ["is suspended"]
    Repo.delete!(sub)

    Repo.insert!(%DomainS3Backend{
      domain_id: domain.id,
      subdomain: "app",
      url_path: "",
      endpoint_url: "https://s3.example.com",
      bucket: "bucket",
      access_key_id: "key",
      secret_access_key: "secret"
    })

    assert {:error, changeset} = Hosting.create_domain_proxy(admin, attrs)
    assert errors_on(changeset).path == ["conflicts with an enabled S3 mapping"]
  end

  test "rejects disabled web hosting and independently hosted hostname collisions", %{
    admin: admin,
    domain: domain,
    attrs: attrs
  } do
    Repo.insert!(%Hostctl.Hosting.Domain{name: "app.docker-proxy.test", user_id: admin.user.id})
    assert {:error, changeset} = Hosting.create_domain_proxy(admin, attrs)
    assert errors_on(changeset).subdomain
    Repo.update!(Ecto.Changeset.change(domain, web_enabled: false))
    assert {:error, changeset} = Hosting.create_domain_proxy(admin, %{attrs | subdomain: "other"})
    assert errors_on(changeset).domain_id == ["requires active web hosting"]
  end

  test "failed web provisioning retains the mapping and reports apply failure", %{
    admin: admin,
    attrs: attrs
  } do
    identity =
      Repo.get_by(Hostctl.Isolation.SystemIdentity, user_id: admin.user.id) ||
        Repo.insert!(Hostctl.Isolation.SystemIdentity.reservation_changeset(admin.user))

    Repo.update!(Ecto.Changeset.change(identity, state: :failed))
    previous = Application.get_env(:hostctl, :web_server)
    Application.put_env(:hostctl, :web_server, Keyword.put(previous, :enabled, true))
    on_exit(fn -> Application.put_env(:hostctl, :web_server, previous) end)

    assert {:ok, proxy, :sync_failed} = Hosting.create_domain_proxy(admin, attrs)
    assert Repo.get!(DomainProxy, proxy.id).subdomain == "app"
    assert {:ok, updated, :sync_failed} = Hosting.set_domain_proxy_websocket(admin, proxy, false)
    refute updated.websocket_enabled
    assert {:ok, _, :sync_failed} = Hosting.delete_domain_proxy(admin, updated)
    refute Repo.get(DomainProxy, proxy.id)
  end
end
