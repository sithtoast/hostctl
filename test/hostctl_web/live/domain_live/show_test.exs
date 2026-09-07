defmodule HostctlWeb.DomainLive.ShowTest do
  use HostctlWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Hostctl.Hosting
  import Hostctl.AccountsFixtures

  describe "S3 subdomain directory listings" do
    setup %{conn: conn} do
      user = user_fixture()

      {:ok, domain} =
        Hosting.create_domain(user_scope_fixture(user), %{
          name: "s3-listings-example.com",
          apply_dns_template: false
        })

      {:ok, subdomain} =
        Hosting.create_subdomain(domain, %{name: "files"}, skip_dns_records: true)

      %{conn: log_in_user(conn, user), domain: domain, subdomain: subdomain}
    end

    test "uses the S3 setting and updates it from either tab", %{
      conn: conn,
      domain: domain,
      subdomain: sub
    } do
      {:ok, backend} =
        Hosting.create_s3_backend(domain, %{
          endpoint_url: "https://s3.example.com",
          bucket: "test-bucket",
          subdomain: sub.name,
          directory_listing: true
        })

      {:ok, view, _} = live(conn, ~p"/domains/#{domain.id}?section=subdomains")
      selector = "#subdomain-listings-#{sub.id}"
      assert has_element?(view, selector <> "[aria-pressed=true]")

      view |> element(selector) |> render_click()
      refute Hosting.get_s3_backend_by_id!(backend.id).directory_listing
      assert has_element?(view, selector <> "[aria-pressed=false]")

      render_patch(view, ~p"/domains/#{domain.id}?section=s3")

      view
      |> element("button[phx-click=edit_s3_backend][phx-value-id='#{backend.id}']")
      |> render_click()

      view
      |> form("#s3-backend-form", domain_s3_backend: %{directory_listing: true})
      |> render_submit()

      render_patch(view, ~p"/domains/#{domain.id}?section=subdomains")
      assert has_element?(view, selector <> "[aria-pressed=true]")
    end

    test "disabled and path-only shares keep the filesystem listing setting", %{
      conn: conn,
      domain: domain,
      subdomain: sub
    } do
      for attrs <- [%{enabled: false}, %{url_path: "/assets"}] do
        {:ok, _} =
          Hosting.create_s3_backend(
            domain,
            Map.merge(
              %{
                endpoint_url: "https://s3.example.com",
                bucket: "test-bucket",
                subdomain: sub.name,
                directory_listing: true
              },
              attrs
            )
          )
      end

      {:ok, view, _} = live(conn, ~p"/domains/#{domain.id}?section=subdomains")
      selector = "#subdomain-listings-#{sub.id}"
      assert has_element?(view, selector <> "[aria-pressed=false]")
      view |> element(selector) |> render_click()
      assert has_element?(view, selector <> "[aria-pressed=true]")
      assert Enum.find(Hosting.list_subdomains(domain), &(&1.id == sub.id)).autoindex
    end
  end

  describe "ssl reissue" do
    setup %{conn: conn} do
      user = user_fixture()
      scope = user_scope_fixture(user)

      {:ok, domain} =
        Hosting.create_domain(scope, %{
          name: "ssl-liveview-example.com",
          apply_dns_template: false
        })

      {:ok, _ssl_cert} =
        Hosting.create_ssl_certificate(domain, %{
          cert_type: "custom",
          status: "active",
          certificate: "existing-cert",
          private_key: "existing-key",
          email: user.email
        })

      %{
        conn: log_in_user(conn, user),
        user: user,
        domain: domain
      }
    end

    test "renders immediate certbot audit lines when requesting ssl", %{
      conn: conn,
      domain: domain,
      user: user
    } do
      {:ok, lv, _html} = live(conn, ~p"/domains/#{domain.id}?section=ssl")

      assert has_element?(lv, "#ssl-reissue-form")

      form =
        form(lv, "#ssl-reissue-form", %{
          "ssl_certificate" => %{
            "email" => user.email,
            "covers_wildcard_subdomains" => "false"
          },
          "allow_http_with_ssl" => "true"
        })

      html = render_submit(form)

      assert html =~ "Request accepted at"
      assert html =~ "Preparing SSL provisioning task"
      assert html =~ "SSL certificate reissue initiated for"
    end
  end
end
