defmodule Hostctl.Repo.Migrations.AddFtpMountToDomainS3Backends do
  use Ecto.Migration

  def change do
    alter table(:domain_s3_backends) do
      add :ftp_mount_enabled, :boolean, null: false, default: false
    end
  end
end
