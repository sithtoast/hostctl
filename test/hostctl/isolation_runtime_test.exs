defmodule Hostctl.IsolationRuntimeTest do
  use Hostctl.DataCase
  import Hostctl.AccountsFixtures
  alias Hostctl.Accounts.Scope
  alias Hostctl.Hosting
  alias Hostctl.Hosting.{Domain, FtpAccount, DomainS3Backend}
  alias Hostctl.Isolation
  alias Hostctl.Isolation.Runtime

  setup do
    old = Application.get_env(:hostctl, :isolation_adapter)
    Application.put_env(:hostctl, :isolation_adapter, Hostctl.IsolationTestAdapter)

    on_exit(fn ->
      if old,
        do: Application.put_env(:hostctl, :isolation_adapter, old),
        else: Application.delete_env(:hostctl, :isolation_adapter)
    end)

    %{scope: unconfirmed_user_fixture() |> Scope.for_user()}
  end

  test "matching empty admin owner enrolls without changing panel privileges", %{scope: scope} do
    user = Repo.update!(change(scope.user, role: "admin"))

    assert {:ok, %{state: :ready, user_id: owner_id}} =
             Runtime.prepare_import_owner(Scope.for_user(user))

    assert owner_id == user.id
    assert Repo.get!(Hostctl.Accounts.User, user.id).role == "admin"
    assert {:ok, %{state: :ready}} = Runtime.prepare_import_owner(Scope.for_user(user))
  end

  test "matching owner with domains preserves legacy hosting", %{scope: scope} do
    Repo.insert!(%Domain{user_id: scope.user.id, name: "existing-import.example.com"})
    assert {:ok, nil} = Runtime.prepare_import_owner(scope)
    assert Isolation.get_identity(scope) == nil
    refute_receive {:isolation_helper, _, _}
  end

  test "matching owner with FTP resources preserves legacy hosting", %{scope: scope} do
    Repo.insert!(%FtpAccount{
      user_id: scope.user.id,
      username: "existingimport",
      hashed_password: "unused-test-fixture",
      home_dir: "/var/www/existing.example.com"
    })

    assert {:ok, nil} = Runtime.prepare_import_owner(scope)
    refute_receive {:isolation_helper, _, _}
  end

  test "matching empty owner enrollment failure blocks hosting and retries", %{scope: scope} do
    Process.put(:isolation_fail, "enroll")
    assert {:error, :test_helper_failure} = Runtime.prepare_import_owner(scope)
    assert {:error, :account_isolation_not_ready} = Runtime.identity(scope.user.id)
    Process.delete(:isolation_fail)
    assert {:ok, %{state: :ready}} = Runtime.prepare_import_owner(scope)
  end

  test "Ubuntu 26.04 default selects PHP 8.5 without changing existing domains" do
    previous = Application.get_env(:hostctl, :default_php_version)
    Application.put_env(:hostctl, :default_php_version, "8.5")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:hostctl, :default_php_version, previous),
        else: Application.delete_env(:hostctl, :default_php_version)
    end)

    assert get_field(Domain.changeset(%Domain{}, %{name: "new.example.com"}), :php_version) ==
             "8.5"

    assert get_field(Domain.changeset(%Domain{id: 1, php_version: "8.3"}, %{}), :php_version) ==
             "8.3"

    assert get_field(Domain.changeset(%Domain{}, %{php_version: "8.2"}), :php_version) == "8.2"
  end

  test "Plesk owners are enrolled before receiving hosting resources" do
    assert {:ok, user} =
             Hostctl.Accounts.create_import_user(%{name: "Imported", email: unique_user_email()})

    scope = Scope.for_user(user)
    assert %{state: :ready} = Isolation.get_identity(scope)

    assert {:ok, domain} =
             Hosting.create_domain(scope, %{
               name: "imported.example.com",
               apply_dns_template: false
             })

    assert {:ok, destination} = Runtime.import_destination(domain.document_root)
    assert destination.username == "hc_#{user.id}"
    assert :ok = Runtime.import_tree(destination, "/tmp/hostctl-import-test")
    assert_receive {:isolation_helper, "import-tree", %{username: name}}
    assert name == destination.username
  end

  test "failed Plesk enrollment retains a blocked account and can be retried" do
    email = unique_user_email()
    Process.put(:isolation_fail, "enroll")

    assert {:error, changeset} =
             Hostctl.Accounts.create_import_user(%{name: "Imported", email: email})

    assert errors_on(changeset).base != []
    user = Hostctl.Accounts.get_user_by_email(email)
    assert {:error, :account_isolation_not_ready} = Runtime.identity(user.id)
    Process.delete(:isolation_fail)
    assert {:ok, %{state: :ready}} = Runtime.provision_identity(Scope.for_user(user))
  end

  test "import destinations fail closed for unavailable identities and unsafe paths", %{
    scope: scope
  } do
    {:ok, identity} = Runtime.provision_identity(scope)
    Repo.insert!(%Domain{user_id: scope.user.id, name: "import-target.example.com"})

    assert {:error, _} =
             Runtime.import_destination("/var/www/import-target.example.com/../escape")

    assert {:error, _} = Runtime.import_destination("/var/www")
    assert {:ok, nil} = Runtime.import_destination("/tmp/mail-stage")
    Repo.update!(change(identity, state: :failed))

    assert {:error, :account_isolation_not_ready} =
             Runtime.import_destination("/var/www/import-target.example.com/httpdocs")
  end

  test "enrollment activates an empty account and subsequent calls verify its identity", %{
    scope: scope
  } do
    assert {:ok, identity} = Runtime.provision_identity(scope)
    assert identity.state == :ready
    assert identity.uid > 0
    assert {:ok, ^identity} = Runtime.provision_identity(scope)
    assert_receive {:isolation_helper, "enroll", _}
    assert_receive {:isolation_helper, "verify", _}
    refute_receive {:isolation_helper, "enroll", _}
  end

  test "an existing hosting owner is refused before any OS operation", %{scope: scope} do
    Repo.insert!(%Domain{user_id: scope.user.id, name: "existing.example.com"})
    assert {:error, :existing_account_requires_migration} = Runtime.provision_identity(scope)
    refute_receive {:isolation_helper, _, _}
    assert Isolation.get_identity(scope) == nil
  end

  test "a failed enrollment cannot fall back to shared PHP or FTP and can be retried", %{
    scope: scope
  } do
    Process.put(:isolation_fail, "enroll")
    assert {:error, :test_helper_failure} = Runtime.provision_identity(scope)
    assert Isolation.get_identity(scope).state == :failed
    assert {:error, :account_isolation_not_ready} = Runtime.identity(scope.user.id)
    assert {:error, changeset} = Hosting.create_domain(scope, %{name: "blocked.example.com"})
    assert errors_on(changeset).base != []
    refute Repo.exists?(from d in Domain, where: d.user_id == ^scope.user.id)

    assert {:error, changeset} =
             Hosting.create_ftp_account(scope.user, %{
               username: "blocked",
               password: "testpassword!"
             })

    assert errors_on(changeset).base != []
    Process.delete(:isolation_fail)
    assert {:ok, %{state: :ready}} = Runtime.provision_identity(scope)
  end

  test "ready domains use a dedicated PHP socket and symlink policy", %{scope: scope} do
    {:ok, identity} = Runtime.provision_identity(scope)

    {:ok, domain} =
      Hosting.create_domain(scope, %{name: "isolated.example.com", apply_dns_template: false})

    {:ok, runtime} = Runtime.prepare_domain(domain)
    assert runtime[:isolated]
    assert runtime[:php_socket] == Runtime.php_socket(identity, "8.3")
    config = Hostctl.WebServer.Nginx.generate_config(domain, [], nil, [], [], runtime)
    assert config =~ "disable_symlinks on;"
    assert config =~ "fastcgi_pass unix:#{runtime[:php_socket]};"
    refute config =~ "unix:/run/php/php8.3-fpm.sock"

    assert_receive {:isolation_helper, "webroot",
                    %{path: "/var/www/isolated.example.com/httpdocs"}}
  end

  test "PHP provisioning failure is returned without a shared socket", %{scope: scope} do
    {:ok, _} = Runtime.provision_identity(scope)
    domain = Repo.insert!(%Domain{user_id: scope.user.id, name: "php-failed.example.com"})
    Process.put(:isolation_fail, "php")
    assert {:error, :test_helper_failure} = Runtime.prepare_domain(domain)
  end

  test "custom roots and S3 FTP mounts cannot activate a shared runtime", %{scope: scope} do
    {:ok, _} = Runtime.provision_identity(scope)

    domain =
      Repo.insert!(%Domain{
        user_id: scope.user.id,
        name: "custom.example.com",
        document_root: "/srv/custom"
      })

    assert {:error, :unsupported_isolated_webroot_or_mount} = Runtime.prepare_domain(domain)
    domain = Repo.update!(change(domain, document_root: "/var/www/custom.example.com/httpdocs"))

    Repo.insert!(%DomainS3Backend{
      domain_id: domain.id,
      endpoint_url: "https://s3.example.com",
      bucket: "test-bucket",
      ftp_mount_enabled: true
    })

    assert {:error, :unsupported_isolated_webroot_or_mount} = Runtime.prepare_domain(domain)
  end

  test "FTP maps to the owner without shared ownership and rejects another account's root", %{
    scope: scope
  } do
    {:ok, identity} = Runtime.provision_identity(scope)
    Repo.insert!(%Domain{user_id: scope.user.id, name: "ftp.example.com"})

    account = %FtpAccount{
      user_id: scope.user.id,
      username: "siteftp",
      home_dir: "/var/www/ftp.example.com/httpdocs"
    }

    assert {:ok, ^identity} = Runtime.ftp_identity(account)
    config = Hostctl.FtpServer.user_config(account, identity)
    assert config =~ "guest_username=#{identity.username}\n"
    assert config =~ "chmod_enable=NO\n"
    refute config =~ "www-data"

    assert {:error, :ftp_path_not_owned} =
             Runtime.ftp_identity(%{account | home_dir: "/var/www/other.example.com"})

    assert {:error, :isolated_bind_mounts_require_migration} =
             Runtime.ftp_identity(%{
               account
               | mounts: [%{"name" => "x", "path" => account.home_dir}]
             })
  end

  test "legacy chown, FTP and restore paths cannot touch isolated boundaries", %{scope: scope} do
    {:ok, _} = Runtime.provision_identity(scope)
    Repo.insert!(%Domain{user_id: scope.user.id, name: "protected.example.com"})
    assert Runtime.protected_path?("/var/www/protected.example.com/httpdocs")
    assert Runtime.protected_path?("/var/www")
    refute Runtime.protected_path?("/var/www/protected.example.com-other")
    assert {:error, _} = Hostctl.WebServer.chown_to_www_data("/var/www/protected.example.com")
    legacy = unconfirmed_user_fixture()
    account = %FtpAccount{user_id: legacy.id, home_dir: "/var/www/protected.example.com"}
    assert {:error, :isolated_path} = Runtime.ftp_identity(account)

    assert {:error, _} =
             Hostctl.Backup.restore_raw_s3_domain("protected.example.com", account.home_dir)

    assert {:error, _} = Hostctl.Backup.restore_s3_prefix_to_dir("prefix", account.home_dir)
  end
end
