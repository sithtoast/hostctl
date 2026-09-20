defmodule HostctlWeb.PanelLive.PortainerTest do
  use HostctlWeb.ConnCase
  import Phoenix.LiveViewTest
  import Hostctl.AccountsFixtures
  alias Hostctl.Portainer.TestAdapter

  setup do
    previous = Application.get_env(:hostctl, :portainer_adapter)
    Application.put_env(:hostctl, :portainer_adapter, TestAdapter)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:hostctl, :portainer_adapter, previous),
        else: Application.delete_env(:hostctl, :portainer_adapter)
    end)

    start_supervised!(%{
      id: TestAdapter,
      start:
        {Agent, :start_link,
         [
           fn -> %{calls: [], agent: %{"installed" => false, "running" => false}} end,
           [name: TestAdapter]
         ]}
    })

    %{admin: admin_user_fixture()}
  end

  test "requires an administrator", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/panel/portainer")
    user = user_fixture()

    assert {:error, {:redirect, %{to: "/"}}} =
             conn |> log_in_user(user) |> live(~p"/panel/portainer")

    assert {:error, :forbidden} =
             Hostctl.Portainer.install(Hostctl.Accounts.Scope.for_user(user), %{})

    assert Agent.get(TestAdapter, & &1.calls) == []
  end

  test "admin installs and removes only through the typed operation", %{conn: conn, admin: admin} do
    {:ok, view, _} = conn |> log_in_user(admin) |> live(~p"/panel/portainer")
    render_async(view)
    assert has_element?(view, "#portainer-not-installed")

    view
    |> form("#portainer-install-form",
      agent: %{version: "2.39.0", bind_address: "10.0.0.5", agent_secret: "private-fixture"}
    )
    |> render_submit()

    render_async(view)
    assert has_element?(view, "#portainer-running")
    refute has_element?(view, "#agent_agent_secret[value='private-fixture']")

    assert [
             {"portainer-install",
              %{version: "2.39.0", bind_address: "10.0.0.5", agent_secret: "private-fixture"}}
             | _
           ] = Agent.get(TestAdapter, & &1.calls)

    view |> element("#remove-portainer") |> render_click()
    render_async(view)
    assert has_element?(view, "#portainer-not-installed")
  end

  test "invalid versions never reach the broker and role revocation takes effect", %{
    conn: conn,
    admin: admin
  } do
    {:ok, view, _} = conn |> log_in_user(admin) |> live(~p"/panel/portainer")
    render_async(view)

    view
    |> form("#portainer-install-form", agent: %{version: "latest; sh", bind_address: "0.0.0.0"})
    |> render_submit()

    assert has_element?(view, "#portainer-install-form p", "exact version")
    assert length(Agent.get(TestAdapter, & &1.calls)) == 1
    admin |> Ecto.Changeset.change(role: "client") |> Hostctl.Repo.update!()

    view
    |> form("#portainer-install-form", agent: %{version: "2.39.0", bind_address: "127.0.0.1"})
    |> render_submit()

    render_async(view)
    assert has_element?(view, "#portainer-error")
    assert length(Agent.get(TestAdapter, & &1.calls)) == 1
  end
end
