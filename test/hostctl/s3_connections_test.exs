defmodule Hostctl.S3ConnectionsTest do
  use Hostctl.DataCase, async: true
  import Hostctl.AccountsFixtures
  alias Hostctl.{S3Connections, Repo}

  @attrs %{
    name: "Wasabi",
    endpoint_url: "s3.wasabisys.com",
    region: "us-east-1",
    access_key_id: "test-key",
    secret_access_key: "secret-value"
  }

  test "connections are scoped and store encrypted secrets" do
    scope = user_scope_fixture()
    other = user_scope_fixture()
    assert {:ok, connection} = S3Connections.save(scope, Map.put(@attrs, :user_id, other.user.id))
    assert connection.user_id == scope.user.id
    assert connection.endpoint_url == "https://s3.wasabisys.com"
    assert S3Connections.get(scope, connection.id).secret_access_key == "secret-value"
    assert S3Connections.get(other, connection.id) == nil
    assert S3Connections.list(other) == []

    %{rows: [[stored]]} =
      Repo.query!("SELECT secret_access_key FROM s3_connections WHERE id = $1", [connection.id])

    refute stored == "secret-value"
    refute inspect(connection) =~ "secret-value"
  end

  test "saved names are unique per user and invalid connections do not persist" do
    scope = user_scope_fixture()
    assert {:ok, _} = S3Connections.save(scope, @attrs)
    assert {:error, _} = S3Connections.save(scope, @attrs)
    assert {:ok, _} = S3Connections.save(user_scope_fixture(), @attrs)

    assert {:error, _} =
             S3Connections.save(scope, %{@attrs | endpoint_url: "https://s3.test/bucket"})
  end

  test "persisted import mappings use upload prefixes and preserve scoped options" do
    scope = user_scope_fixture()

    {:ok, domain} =
      Hostctl.Hosting.create_domain(scope, %{name: "s3-import.test", apply_dns_template: false})

    opts = %{
      endpoint: "s3.wasabisys.com",
      bucket: "test-bucket",
      access_key_id: "key",
      secret_access_key: "secret",
      directory_listing: true,
      prefix: "archive"
    }

    assert {:ok, prepared} = Hostctl.Plesk.S3Import.prepare(%{"static" => opts}, domain.name)
    assert :ok = Hostctl.Plesk.S3Import.persist(domain, prepared)
    assert [backend] = Hostctl.Hosting.list_s3_backends(domain)
    assert backend.path_prefix == prepared["static"].prefix
    assert backend.directory_listing
    assert backend.subdomain == "static"
    assert :ok = Hostctl.Plesk.S3Import.persist(domain, prepared)
    assert length(Hostctl.Hosting.list_s3_backends(domain)) == 1
  end
end
