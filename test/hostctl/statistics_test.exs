defmodule Hostctl.StatisticsTest do
  use Hostctl.DataCase, async: false
  import Hostctl.AccountsFixtures
  alias Hostctl.Statistics

  setup do
    old = Application.get_env(:hostctl, Statistics)
    temp = if :os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()
    root = Path.join(temp, "hostctl-stats-#{Ecto.UUID.generate()}")
    Application.put_env(:hostctl, Statistics, root: root, goaccess: "true")

    on_exit(fn ->
      File.rm_rf!(root)

      if old,
        do: Application.put_env(:hostctl, Statistics, old),
        else: Application.delete_env(:hostctl, Statistics)
    end)

    scope = user_scope_fixture()
    domain = Repo.insert!(%Hostctl.Hosting.Domain{name: "stats.test", user_id: scope.user.id})
    %{scope: scope, domain: domain, root: root}
  end

  test "owner and administrator can read reports; another tenant cannot", %{
    scope: scope,
    domain: domain,
    root: root
  } do
    generation = "g-" <> String.duplicate("a", 32)
    folder = Path.join([root, to_string(domain.id), generation])
    File.mkdir_p!(folder)
    File.write!(Path.join(folder, "report.html"), "private stats")

    File.write!(
      Path.join([root, to_string(domain.id), "live.json"]),
      Jason.encode!(%{generation: generation})
    )

    assert {:ok, "private stats", :goaccess} = Statistics.read_report(scope, domain.id, "live")
    admin = Hostctl.Accounts.Scope.for_user(admin_user_fixture())
    assert {:ok, _, _} = Statistics.read_report(admin, domain.id, "live")
    other = user_scope_fixture()
    assert_raise Ecto.NoResultsError, fn -> Statistics.snapshot(other, domain.id) end
    assert_raise Ecto.NoResultsError, fn -> Statistics.refresh(other, domain.id) end
    assert_raise Ecto.NoResultsError, fn -> Statistics.read_report(other, domain.id, "live") end

    assert {:error, :not_found} =
             Statistics.read_report(scope, domain.id, "live", "../../etc/passwd")

    File.rm!(Path.join(folder, "report.html"))
    File.ln_s!("/etc/passwd", Path.join(folder, "report.html"))
    assert {:error, :not_found} = Statistics.read_report(scope, domain.id, "live")
  end

  test "overview reads only the selected private snapshot and bounds ranked rows", %{
    scope: scope,
    domain: domain,
    root: root
  } do
    base = Path.join(root, to_string(domain.id))
    live_gen = "g-" <> String.duplicate("d", 32)
    history_gen = "g-" <> String.duplicate("e", 32)

    for {kind, generation} <- [{"live", live_gen}, {"history", history_gen}] do
      File.mkdir_p!(Path.join(base, generation))
      File.write!(Path.join(base, kind <> ".json"), Jason.encode!(%{generation: generation}))
    end

    rows = for n <- 1..8, do: %{data: "/page#{n}", hits: %{count: n}}
    live_path = Path.join([base, live_gen, "report.json"])

    File.write!(
      live_path,
      Jason.encode!(%{requests: %{data: rows ++ [%{data: "bad", hits: nil}]}})
    )

    File.write!(
      Path.join([base, history_gen, "report.json"]),
      Jason.encode!(%{requests: %{data: [%{data: "/old", hits: %{count: 42}}]}})
    )

    overview = Statistics.snapshot(scope, domain.id).overview
    assert length(overview.pages) == 5
    assert hd(overview.pages).label == "/page8"
    assert overview.sources == []
    assert hd(Statistics.snapshot(scope, domain.id, "history").overview.pages).label == "/old"
    File.write!(live_path, "invalid JSON")
    assert Statistics.snapshot(scope, domain.id).overview == nil
    File.rm!(live_path)
    File.ln_s!("/etc/passwd", live_path)
    assert Statistics.snapshot(scope, domain.id).overview == nil
  end

  test "existing and new domains collect without a report, with a persistent owner opt-out", %{
    scope: scope,
    domain: domain
  } do
    assert domain.statistics_enabled
    assert domain.id in Statistics.enabled_ids()
    assert Statistics.snapshot(scope, domain.id).live == nil
    {:ok, _} = Statistics.set_enabled(scope, domain.id, false)
    refute domain.id in Statistics.enabled_ids()
    assert {:error, _} = Statistics.refresh(scope, domain.id)
    refute Statistics.snapshot(scope, domain.id).domain.statistics_enabled
    other = user_scope_fixture()
    assert_raise Ecto.NoResultsError, fn -> Statistics.set_enabled(other, domain.id, true) end
    admin = Hostctl.Accounts.Scope.for_user(admin_user_fixture())
    {:ok, _} = Statistics.set_enabled(admin, domain.id, true)
    assert domain.id in Statistics.enabled_ids()
  end

  test "collection uses only persisted domain and subdomain log names", %{
    scope: scope,
    domain: domain,
    root: root
  } do
    Repo.insert!(%Hostctl.Hosting.Subdomain{domain_id: domain.id, name: "shop"})
    parent = self()

    runner = fn _cmd, args, _opts ->
      send(parent, {:args, args})
      {"{}", 0}
    end

    Application.put_env(:hostctl, Statistics, root: root, runner: runner)
    assert {:ok, %{}} = Statistics.refresh(scope, domain.id)
    assert_receive {:args, args}
    assert "stats.test" in args
    assert "shop.stats.test" in args
    refute "--source" in args
  end
end
