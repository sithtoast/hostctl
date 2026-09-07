defmodule Hostctl.Plesk.S3ImportTest do
  use ExUnit.Case, async: true
  alias Hostctl.Plesk.S3Import
  alias Hostctl.S3Client

  @opts %{
    endpoint: "s3.wasabisys.com",
    bucket: "test-bucket",
    access_key_id: "test-key",
    secret_access_key: "test-secret",
    prefix: "/archive/",
    ftp_mount_enabled: true,
    directory_listing: true
  }

  test "bare endpoint is HTTPS and malformed endpoints are rejected" do
    assert {:ok, "https://s3.wasabisys.com"} = S3Client.normalize_endpoint(" s3.wasabisys.com/ ")
    assert {:ok, "http://localhost:9000"} = S3Client.normalize_endpoint("http://localhost:9000")

    for invalid <- [
          "",
          "https://",
          "ftp://s3.test",
          "https://key:secret@s3.test",
          "https://s3.test/bucket",
          "https://s3.test?key=secret"
        ] do
      assert {:error, _} = S3Client.normalize_endpoint(invalid)
    end
  end

  test "upload and serving share the exact normalized target prefix" do
    assert {:ok, targets} = S3Import.prepare(%{"deko" => @opts, "" => @opts}, "toastednet.org")
    assert targets["deko"].prefix == "archive/deko.toastednet.org"
    assert targets[""].prefix == "archive/httpdocs"
    attrs = S3Import.attributes(targets["deko"], "deko", "toastednet.org")
    assert attrs.path_prefix == targets["deko"].prefix
    assert attrs.ftp_mount_enabled
    assert attrs.directory_listing
    assert attrs.endpoint_url == "https://s3.wasabisys.com"
    assert {:ok, ^targets} = S3Import.prepare(targets, "toastednet.org")
  end

  test "existing backend prefixes are used verbatim" do
    opts = Map.merge(@opts, %{exact_prefix: true, prefix: "already/served"})

    assert {:ok, %{"deko" => %{prefix: "already/served"}}} =
             S3Import.prepare(%{"deko" => opts}, "toastednet.org")
  end

  test "invalid enabled destinations fail rather than silently using local disk" do
    for opts <- [
          nil,
          %{},
          Map.put(@opts, :bucket, "INVALID"),
          Map.put(@opts, :secret_access_key, "")
        ] do
      assert {:error, message} = S3Import.prepare(%{"deko" => opts}, "toastednet.org")
      assert message =~ "deko.toastednet.org"
      refute message =~ "test-secret"
    end
  end

  test "saved import choices roundtrip with encrypted secrets" do
    targets = %{
      "deko" => %{
        s3_import: true,
        s3_secret_key: "sensitive-value",
        s3_bucket: "a-bucket",
        ftp_enabled: true
      }
    }

    encoded = S3Import.encode_targets(targets)
    refute encoded["deko"]["s3_secret_key"] == "sensitive-value"
    assert S3Import.decode_targets(encoded) == targets
  end
end
