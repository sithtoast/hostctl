defmodule Hostctl.S3ClientTest do
  use ExUnit.Case, async: true
  alias Hostctl.S3Client

  @opts %{
    endpoint: "s3.example.test",
    access_key_id: "key",
    secret_access_key: "secret",
    region: "us-east-1"
  }

  test "lists signed buckets and follows pagination" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert ["AWS4-HMAC-SHA256 " <> _] = Plug.Conn.get_req_header(conn, "authorization")

      if conn.query_string == "" do
        Plug.Conn.send_resp(
          conn,
          200,
          "<ListAllMyBucketsResult><Buckets><Bucket><CreationDate>2026-01-01</CreationDate><Name>first-bucket</Name></Bucket></Buckets><ContinuationToken>next</ContinuationToken></ListAllMyBucketsResult>"
        )
      else
        assert conn.query_string == "continuation-token=next"

        Plug.Conn.send_resp(
          conn,
          200,
          "<ListAllMyBucketsResult><Buckets><Bucket><Name>second-bucket</Name></Bucket></Buckets></ListAllMyBucketsResult>"
        )
      end
    end)

    assert {:ok, ["first-bucket", "second-bucket"]} =
             S3Client.list_buckets(@opts, plug: {Req.Test, __MODULE__})
  end

  test "bucket creation uses region configuration and never retries a failed create" do
    Req.Test.stub(__MODULE__, fn conn ->
      if conn.method == "HEAD" do
        Plug.Conn.send_resp(conn, 404, "")
      else
        assert conn.method == "PUT"
        assert conn.request_path == "/new-bucket"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body =~ "<LocationConstraint>eu-west-1</LocationConstraint>"
        Plug.Conn.send_resp(conn, 200, "")
      end
    end)

    assert :ok =
             S3Client.create_bucket(%{@opts | region: "eu-west-1"}, "new-bucket",
               plug: {Req.Test, __MODULE__}
             )
  end

  test "default region creation has no location constraint and permission errors do not expose response bodies" do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, "", conn} = Plug.Conn.read_body(conn)
      Plug.Conn.send_resp(conn, 403, "secret response body")
    end)

    assert {:error, message} =
             S3Client.create_bucket(@opts, "new-bucket", plug: {Req.Test, __MODULE__})

    assert message =~ "403"
    refute message =~ "secret response"
  end

  test "creating an existing bucket never sends a PUT that could reset its ACL" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "HEAD"
      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert {:error, message} =
             S3Client.create_bucket(@opts, "existing-bucket", plug: {Req.Test, __MODULE__})

    assert message =~ "already exists"
  end
end
