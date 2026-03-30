defmodule HostctlWeb.UpdatesLiveTest do
  use HostctlWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Hostctl.AccountsFixtures

  setup do
    original_repo = Application.get_env(:hostctl, :github_repo)
    original_prereleases = Application.get_env(:hostctl, :github_prereleases)

    Application.delete_env(:hostctl, :github_repo)
    Application.put_env(:hostctl, :github_prereleases, false)

    on_exit(fn ->
      restore_env(:github_repo, original_repo)
      restore_env(:github_prereleases, original_prereleases)
    end)

    :ok
  end

  test "uses the configured prerelease default", %{conn: conn} do
    Application.put_env(:hostctl, :github_prereleases, true)

    {:ok, lv, _html} =
      conn
      |> log_in_user(user_fixture())
      |> live(~p"/updates")

    assert has_element?(lv, "#prerelease-toggle[aria-checked='true']")
  end

  test "query params override the configured prerelease default", %{conn: conn} do
    Application.put_env(:hostctl, :github_prereleases, true)

    {:ok, lv, _html} =
      conn
      |> log_in_user(user_fixture())
      |> live(~p"/updates?prereleases=false")

    assert has_element?(lv, "#prerelease-toggle[aria-checked='false']")
  end

  test "toggle patches the updates URL and flips the switch state", %{conn: conn} do
    {:ok, lv, _html} =
      conn
      |> log_in_user(user_fixture())
      |> live(~p"/updates")

    assert has_element?(lv, "#prerelease-toggle[aria-checked='false']")

    lv
    |> element("#prerelease-toggle")
    |> render_click()

    assert_patch(lv, "/updates?prereleases=true")
    assert has_element?(lv, "#prerelease-toggle[aria-checked='true']")

    lv
    |> element("#prerelease-toggle")
    |> render_click()

    assert_patch(lv, "/updates?prereleases=false")
    assert has_element?(lv, "#prerelease-toggle[aria-checked='false']")
  end

  defp restore_env(key, nil), do: Application.delete_env(:hostctl, key)
  defp restore_env(key, value), do: Application.put_env(:hostctl, key, value)
end
