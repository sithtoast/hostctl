defmodule Hostctl.UploadWorkerTest do
  use Hostctl.DataCase
  import Hostctl.AccountsFixtures

  test "a malformed legacy endpoint becomes a visible failed job rather than a crashed running job" do
    scope = user_scope_fixture()

    {:ok, domain} =
      Hostctl.Hosting.create_domain(scope, %{name: "worker.test", apply_dns_template: false})

    {:ok, job} =
      Hostctl.Hosting.create_upload_job(%{
        domain_id: domain.id,
        user_id: scope.user.id,
        job_type: "plesk_import",
        source_path: "/unused",
        s3_endpoint: "ftp://bad-endpoint",
        s3_bucket: "some-bucket",
        s3_access_key_id: "key",
        s3_secret_access_key: "secret"
      })

    Phoenix.PubSub.subscribe(Hostctl.PubSub, "upload_jobs")
    start_supervised!({Hostctl.UploadWorker, job.id})
    id = job.id
    assert_receive {:upload_progress, %{id: ^id, status: "failed"}}, 5_000
    assert Hostctl.Hosting.get_upload_job!(id).status == "failed"
  end
end
