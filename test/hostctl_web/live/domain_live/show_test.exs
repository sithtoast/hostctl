defmodule HostctlWeb.DomainLive.ShowTest do
  use HostctlWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Hostctl.Hosting
  import Hostctl.AccountsFixtures

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
