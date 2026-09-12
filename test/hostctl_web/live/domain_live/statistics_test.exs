defmodule HostctlWeb.DomainLive.StatisticsTest do
  use HostctlWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Hostctl.AccountsFixtures
  alias Hostctl.Statistics

  setup %{conn: conn} do
    previous = Application.get_env(:hostctl, Statistics)
    temp = if :os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()
    root = Path.join(temp, "hostctl-stats-ui-#{Ecto.UUID.generate()}")
    user = user_fixture()
    domain = Hostctl.Repo.insert!(%Hostctl.Hosting.Domain{name: "stats.test", user_id: user.id})
    generation = "g-" <> String.duplicate("b", 32)
    base = Path.join([root, to_string(domain.id)])
    folder = Path.join(base, generation)
    archive = String.duplicate("c", 64)
    File.mkdir_p!(Path.join(folder, "archive"))
    File.write!(Path.join(folder, "report.html"), "<h1>Traffic report</h1>")

    File.write!(
      Path.join(folder, "report.json"),
      Jason.encode!(%{
        requests: %{data: [%{data: "/articles", method: "GET", hits: %{count: 12}}]},
        referring_sites: %{data: [%{data: "search.example", hits: %{count: 8}}]}
      })
    )

    File.write!(
      Path.join(folder, "archive/" <> archive),
      "<h1>Old report</h1><script>alert(1)</script><img src=x onerror=alert(1)>"
    )

    data = %{
      generation: generation,
      updated_at: 1_789_200_000,
      summary: %{valid_requests: 12, unique_visitors: 3, bandwidth: 2048},
      reports: [%{id: archive, name: "2026-08/awstats.html", html: true}]
    }

    File.write!(Path.join(base, "live.json"), Jason.encode!(data))
    File.write!(Path.join(base, "history.json"), Jason.encode!(data))
    Application.put_env(:hostctl, Statistics, root: root, goaccess: "true")

    on_exit(fn ->
      File.rm_rf!(root)

      if previous,
        do: Application.put_env(:hostctl, Statistics, previous),
        else: Application.delete_env(:hostctl, Statistics)
    end)

    %{conn: log_in_user(conn, user), domain: domain, archive: archive}
  end

  test "domain report navigation and historical reports stay private", %{
    conn: conn,
    domain: domain,
    archive: archive
  } do
    {:ok, view, _} = live(conn, ~p"/domains/#{domain.id}/statistics")

    assert has_element?(
             view,
             "#statistics-report-link[target='_blank'][rel='noopener noreferrer']"
           )

    refute has_element?(view, "iframe")
    assert has_element?(view, "#statistics-top-pages", "GET /articles")
    assert has_element?(view, "#statistics-top-sources", "search.example")
    assert has_element?(view, "#statistics-updated")
    view |> element("#statistics-history") |> render_click()
    assert has_element?(view, "#statistics-history-reports a", "awstats.html")
    report = get(conn, ~p"/domains/#{domain.id}/statistics/report/live")
    assert html_response(report, 200) =~ "Traffic report"
    [csp] = get_resp_header(report, "content-security-policy")
    assert csp =~ "sandbox allow-scripts"
    assert csp =~ "script-src 'unsafe-inline' 'unsafe-eval'"
    refute csp =~ "allow-same-origin"
    assert get_resp_header(report, "cache-control") == ["private, no-store"]
    historical = get(conn, ~p"/domains/#{domain.id}/statistics/report/history?archive=#{archive}")
    body = html_response(historical, 200)
    assert body =~ "Old report"
    refute body =~ "<script"
    refute body =~ "onerror"
    assert [historical_csp] = get_resp_header(historical, "content-security-policy")
    assert String.ends_with?(historical_csp, "sandbox")
    assert historical_csp =~ "script-src 'none'"
  end

  test "owner can opt out and re-enable collection without losing reports", %{
    conn: conn,
    domain: domain
  } do
    {:ok, view, _} = live(conn, ~p"/domains/#{domain.id}/statistics")
    assert has_element?(view, "#toggle-statistics[phx-value-enabled='false']")
    view |> element("#toggle-statistics") |> render_click()
    assert has_element?(view, "#statistics-collection", "Automatic collection is off")
    assert has_element?(view, "#refresh-statistics[disabled]")
    assert has_element?(view, "#statistics-report-link")
    refute Hostctl.Repo.reload!(domain).statistics_enabled
    view |> element("#toggle-statistics") |> render_click()
    assert Hostctl.Repo.reload!(domain).statistics_enabled
    refute has_element?(view, "#refresh-statistics[disabled]")
  end

  test "report endpoints enforce login and domain ownership", %{domain: domain} do
    anonymous = get(build_conn(), ~p"/domains/#{domain.id}/statistics/report/live")
    assert redirected_to(anonymous) == "/users/log-in"
    other = build_conn() |> log_in_user(user_fixture())
    assert_error_sent 404, fn -> get(other, ~p"/domains/#{domain.id}/statistics/report/live") end
  end
end
