defmodule Hostctl.ResourcesTest do
  use Hostctl.DataCase
  import Hostctl.ResourceFixtures
  alias Hostctl.Resources
  alias Hostctl.Resources.{CLI, ProcessReader}
  alias Hostctl.Accounts.Scope

  setup do
    resource_fixture()
  end

  test "maps processes to their actual owner and domains, preserving shared services", %{
    admin: admin,
    owner: owner
  } do
    assert {:ok, result} = Resources.snapshot(Scope.for_user(admin))
    assert result.total == 3 and result.attributed == 2
    [busy, _, shared] = result.processes
    assert busy.owner.user_id == owner.id
    assert busy.owner.domains == ["cedar.example", "shop.cedar.example"]
    assert busy.cpu == 96.4
    assert shared.attribution == :shared and is_nil(shared.owner)
    refute Map.has_key?(busy.owner, :hashed_password)
    refute Map.has_key?(busy, :args)
  end

  test "non-admin callers cannot inspect or look up other accounts", %{owner: owner} do
    for scope <- [nil, Scope.for_user(owner), Scope.for_user(%{owner | role: "reseller"})] do
      assert {:error, :forbidden} = Resources.snapshot(scope)
      assert {:error, :forbidden} = Resources.lookup(scope, :uid, 12001)
    end
  end

  test "searches account, domain, identity, PID and UID", %{admin: admin, identity: identity} do
    for query <- ["CEDAR", "shop.cedar.example", identity.username, "410", "12001"] do
      assert {:ok, %{processes: [%{pid: 410}]}} = Resources.snapshot(Scope.for_user(admin), query)
    end

    assert {:ok, %{matching: 0, processes: []}} =
             Resources.snapshot(Scope.for_user(admin), "missing")
  end

  test "UID, username and live PID lookup agree", %{admin: admin, identity: identity} do
    scope = Scope.for_user(admin)
    assert {:ok, by_uid} = Resources.lookup(scope, :uid, identity.uid)
    assert {:ok, ^by_uid} = Resources.lookup(scope, :username, identity.username)
    assert {:ok, %{owner: ^by_uid}} = Resources.lookup(scope, :pid, 410)
    assert {:error, :process_not_found} = Resources.lookup(scope, :pid, 99999)
    assert {:error, :identity_not_found} = Resources.lookup(scope, :uid, 99999)
    assert {:error, :invalid_lookup} = Resources.lookup(scope, :pid, -1)
  end

  test "UID/name mismatches are not attributed to a customer", %{
    admin: admin,
    processes: [process | _]
  } do
    set_processes({:ok, [%{process | linux_user: "unexpected"}]})

    assert {:ok, %{attributed: 0, processes: [%{owner: nil, attribution: :identity_mismatch}]}} =
             Resources.snapshot(Scope.for_user(admin))
  end

  test "retained identities survive deleted logins without stealing another owner", %{
    admin: admin,
    owner: owner,
    identity: identity
  } do
    Repo.delete!(owner)
    assert {:ok, retained} = Resources.lookup(Scope.for_user(admin), :uid, identity.uid)
    assert retained.user_id == nil
    assert retained.original_user_id == owner.id
    assert retained.domains == []
  end

  test "failed process reads do not become zero-usage snapshots", %{admin: admin} do
    set_processes({:error, :linux_required})
    assert {:error, :linux_required} = Resources.snapshot(Scope.for_user(admin))
  end

  test "strict parser preserves spaced process names and rejects malformed numbers" do
    assert {:ok, [%{pid: 12, uid: 1001, cpu: 0.4, rss_kb: 2048, command: "php-fpm: pool hc_1"}]} =
             ProcessReader.parse(" 12 1001 hc_1 0.4 2048 php-fpm: pool hc_1\n")

    assert {:error, :invalid_process_snapshot} =
             ProcessReader.parse("12 1001 hc_1 bogus 2048 php")

    assert {:error, :invalid_process_snapshot} = ProcessReader.parse("12 1001 hc_1 1.0 -2 php")
  end

  test "operator arguments are parsed as data, never evaluated" do
    assert {:ok, :uid, 0} = CLI.parse("uid", "0")
    assert {:ok, :pid, 123} = CLI.parse("pid", "123")
    assert {:error, :invalid_lookup} = CLI.parse("pid", "123; id")
    assert {:error, :invalid_lookup} = CLI.parse("pid", "0")
    assert {:error, :invalid_lookup} = CLI.parse("unknown", "10")
  end
end
