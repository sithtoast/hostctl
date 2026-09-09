defmodule Hostctl.IsolationTest do
  use Hostctl.DataCase, async: true

  import Hostctl.AccountsFixtures

  alias Hostctl.Accounts.{Scope, User}
  alias Hostctl.Hosting.{CronJob, Domain, DomainS3Backend, FtpAccount, Subdomain, UploadJob}
  alias Hostctl.Isolation
  alias Hostctl.Isolation.SystemIdentity

  defp owner do
    user = unconfirmed_user_fixture()
    scope = Scope.for_user(user)

    domain =
      Repo.insert!(%Domain{
        user_id: user.id,
        name: "site#{user.id}.example.com",
        document_root: "/var/www/site#{user.id}.example.com/httpdocs"
      })

    {scope, domain}
  end

  defp ftp(scope, home_dir, attrs \\ %{}) do
    Repo.insert!(
      struct!(
        FtpAccount,
        Map.merge(
          %{
            user_id: scope.user.id,
            username: "ftp#{scope.user.id}",
            home_dir: home_dir,
            hashed_password: "not-for-the-report"
          },
          attrs
        )
      )
    )
  end

  defp finding?(plan, code, resource_id \\ nil) do
    Enum.any?(plan.findings, fn finding ->
      finding.code == code and (is_nil(resource_id) or finding.resource_id == resource_id)
    end)
  end

  test "planning is read-only and does not claim OS or service readiness" do
    {scope, domain} = owner()
    assert {:ok, plan} = Isolation.plan(scope)
    assert plan.phase == "database_inventory"
    refute plan.apply_supported

    assert plan.identity == %{
             username: "hc_#{scope.user.id}",
             state: "unreserved",
             uid: nil,
             gid: nil
           }

    assert [%{id: id}] = plan.domains
    assert id == domain.id
    assert plan.findings == []
    assert length(plan.required_live_checks) > 0
    assert Isolation.get_identity(scope) == nil
  end

  test "reservation is idempotent, pending, and independent of editable account details" do
    {scope, _} = owner()
    assert {:ok, identity} = Isolation.reserve_identity(scope)
    assert identity.state == :pending
    assert identity.uid == nil
    assert identity.gid == nil
    assert identity.username == "hc_#{scope.user.id}"

    Repo.update!(change(scope.user, email: "renamed@example.com", name: "Renamed"))
    assert {:ok, ^identity} = Isolation.reserve_identity(scope)
    assert Repo.aggregate(SystemIdentity, :count) == 1
    assert {:ok, %{identity: %{state: "pending"}}} = Isolation.plan(scope)
  end

  test "panel-only users need no reservation, but FTP-only owners do" do
    scope = unconfirmed_user_fixture() |> Scope.for_user()
    assert {:error, :no_hosting_resources} = Isolation.reserve_identity(scope)
    ftp(scope, "/var/www/external.example.com")
    assert {:ok, %{state: :pending}} = Isolation.reserve_identity(scope)
    assert {:ok, plan} = Isolation.plan(scope)
    assert finding?(plan, :ftp_path_not_owned)
  end

  test "managed customers receive independent identities and scoped inventories" do
    {manager, _} = owner()
    {customer, customer_domain} = owner()
    Repo.update!(change(customer.user, managed_by_id: manager.user.id))
    {:ok, manager_identity} = Isolation.reserve_identity(manager)
    {:ok, customer_identity} = Isolation.reserve_identity(customer)

    refute manager_identity.username == customer_identity.username
    assert Isolation.get_identity(customer).id == customer_identity.id
    assert {:ok, plan} = Isolation.plan(manager)
    refute Enum.any?(plan.domains, &(&1.id == customer_domain.id))
    refute Jason.encode!(plan) =~ customer_domain.name
  end

  test "deleting an owner retains the reservation and numeric IDs" do
    {scope, _} = owner()
    {:ok, identity} = Isolation.reserve_identity(scope)
    Repo.update!(change(identity, uid: 123_456, gid: 123_456, state: :provisioned))
    Repo.delete!(scope.user)

    retained = Repo.get!(SystemIdentity, identity.id)
    assert retained.user_id == nil
    assert retained.original_user_id == scope.user.id
    assert retained.uid == 123_456
    assert retained.gid == 123_456
    assert {:error, :account_not_found} = Isolation.reserve_identity(scope)
    assert {:error, :account_not_found} = Isolation.plan(scope)

    {new_scope, _} = owner()
    assert {:ok, replacement} = Isolation.reserve_identity(new_scope)
    refute retained.username == replacement.username

    # A retained numeric UID cannot be claimed by another account.
    changeset =
      replacement
      |> change(uid: 123_456, gid: 123_457)
      |> unique_constraint(:uid)

    assert {:error, changeset} = Repo.update(changeset, mode: :savepoint)
    assert "has already been taken" in errors_on(changeset).uid
  end

  test "the database rejects root IDs, incomplete numeric identities and ready-without-UID" do
    {scope, _} = owner()
    {:ok, identity} = Isolation.reserve_identity(scope)

    for attrs <- [%{uid: 0, gid: 0}, %{uid: 1000}, %{uid: -1, gid: 1000}] do
      changeset =
        identity
        |> change(attrs)
        |> check_constraint(:uid, name: :identity_numeric_ids)

      assert {:error, _} = Repo.update(changeset, mode: :savepoint)
    end

    changeset =
      identity
      |> change(state: :ready)
      |> check_constraint(:state, name: :identity_state)

    assert {:error, _} = Repo.update(changeset, mode: :savepoint)
  end

  test "an identity cannot be reassigned to another owner" do
    {scope, _} = owner()
    {other, _} = owner()
    {:ok, identity} = Isolation.reserve_identity(scope)

    changeset =
      identity
      |> change(user_id: other.user.id)
      |> check_constraint(:user_id, name: :identity_owner)

    assert {:error, _} = Repo.update(changeset, mode: :savepoint)
  end

  test "unknown owners return a structured error" do
    scope = Scope.for_user(%User{id: 9_223_372_036_854_775_000})
    assert {:error, :account_not_found} = Isolation.plan(scope)
    assert {:error, :account_not_found} = Isolation.reserve_identity(scope)
  end

  test "FTP paths and website roots detect cross-account overlap without exposing the other inventory" do
    {scope, domain} = owner()
    {other, other_domain} = owner()
    account = ftp(scope, other_domain.document_root)

    assert {:ok, plan} = Isolation.plan(scope)
    assert finding?(plan, :cross_account_path_overlap, account.id)
    assert finding?(plan, :ftp_path_not_owned, account.id)
    refute Enum.any?(plan.domains, &(&1.id == other_domain.id))

    # A foreign FTP account can also point back into this owner's tree.
    Repo.delete!(account)
    ftp(other, domain.document_root)
    assert {:ok, plan} = Isolation.plan(scope)
    assert finding?(plan, :cross_account_path_overlap, domain.id)
    assert plan.ftp_accounts == []
    refute Jason.encode!(plan) =~ other_domain.name
  end

  test "path containment uses directory boundaries, not string prefixes" do
    {scope, domain} = owner()
    ftp(scope, Path.dirname(domain.document_root) <> "-other/httpdocs")
    assert {:ok, plan} = Isolation.plan(scope)
    assert finding?(plan, :ftp_path_not_owned)
  end

  test "custom subdomain roots are inventoried and checked for foreign overlap" do
    {scope, domain} = owner()
    {_other, other_domain} = owner()

    sub =
      Repo.insert!(%Subdomain{
        domain_id: domain.id,
        name: "blog",
        document_root: other_domain.document_root
      })

    assert {:ok, plan} = Isolation.plan(scope)
    assert finding?(plan, :custom_document_root, sub.id)
    assert finding?(plan, :cross_account_path_overlap, sub.id)
    assert [%{id: id}] = plan.subdomains
    assert id == sub.id
  end

  test "unsafe paths cannot pass preflight, including missing FTP homes" do
    {scope, domain} = owner()
    account = ftp(scope, nil)

    for path <- [
          nil,
          "/",
          "/etc",
          "/var/www",
          "/var/www/a/../b",
          "/var/www/a/./b",
          "/var/www//a",
          "/var/www/a\nroot",
          "/var/www/a;cmd",
          "/var/www/a/"
        ] do
      Repo.update!(change(account, home_dir: path))
      assert {:ok, plan} = Isolation.plan(scope)
      assert finding?(plan, :unsafe_or_unsupported_path, account.id), inspect(path)
    end

    Repo.update!(change(account, home_dir: domain.document_root))
    assert {:ok, plan} = Isolation.plan(scope)
    refute finding?(plan, :unsafe_or_unsupported_path)
    refute finding?(plan, :ftp_path_not_owned)
  end

  test "unvalidated foreign paths require review without disclosing them" do
    {scope, _domain} = owner()
    {other, _other_domain} = owner()
    ftp(other, "/var/www/private/../target")
    assert {:ok, plan} = Isolation.plan(scope)
    assert finding?(plan, :unvalidated_foreign_paths)
    refute Jason.encode!(plan) =~ "private"
  end

  test "bind mounts require review and reject traversal or duplicate mount names" do
    {scope, domain} = owner()

    account =
      ftp(scope, nil, %{
        mounts: [
          %{"name" => "site", "path" => domain.document_root, "ignored_secret" => "hidden"}
        ]
      })

    assert {:ok, plan} = Isolation.plan(scope)
    assert finding?(plan, :ftp_bind_mounts)
    refute finding?(plan, :ftp_path_not_owned)
    refute finding?(plan, :invalid_ftp_mount_names)
    refute Jason.encode!(plan) =~ "hidden"

    for names <- [[".."], ["../outside"], ["site", "site"], ["bad\nname"]] do
      mounts = Enum.map(names, &%{"name" => &1, "path" => domain.document_root})
      Repo.update!(change(account, mounts: mounts))
      assert {:ok, plan} = Isolation.plan(scope)
      assert finding?(plan, :invalid_ftp_mount_names)
    end
  end

  test "inventory identifies S3 mounts and unfinished writers without loading credentials or commands" do
    {scope, domain} = owner()
    ftp(scope, domain.document_root)

    backend =
      Repo.insert!(%DomainS3Backend{
        domain_id: domain.id,
        endpoint_url: "https://s3.example.com",
        bucket: "private-bucket",
        access_key_id: "private-access-key",
        secret_access_key: "private-secret-key",
        ftp_mount_enabled: true
      })

    cron =
      Repo.insert!(%CronJob{
        domain_id: domain.id,
        schedule: "* * * * *",
        command: "curl https://example.com/?token=private-token"
      })

    job =
      Repo.insert!(%UploadJob{
        user_id: scope.user.id,
        domain_id: domain.id,
        status: "paused",
        job_type: "local_to_s3",
        source_path: domain.document_root,
        s3_endpoint: "https://s3.example.com",
        s3_bucket: "private-bucket",
        s3_access_key_id: "private-access-key",
        s3_secret_access_key: "private-secret-key",
        metadata: %{"password" => "private-metadata"}
      })

    assert {:ok, plan} = Isolation.plan(scope)
    assert finding?(plan, :s3_mount_permissions, backend.id)
    assert finding?(plan, :scheduled_job_identity, cron.id)
    assert finding?(plan, :unfinished_upload, job.id)
    json = Jason.encode!(plan)
    refute json =~ "private-"
    refute json =~ "not-for-the-report"

    Repo.update!(change(job, status: "completed"))
    Repo.update!(change(cron, enabled: false))
    assert {:ok, plan} = Isolation.plan(scope)
    refute finding?(plan, :unfinished_upload)
    refute finding?(plan, :scheduled_job_identity)
  end
end
