defmodule Hostctl.Repo.Migrations.AddS3ModeToDomainBackupSettings do
  use Ecto.Migration

  def change do
    alter table(:domain_backup_settings) do
      add :s3_mode, :string, null: true
    end

    alter table(:subdomain_backup_settings) do
      add :s3_mode, :string, null: true
    end
  end
end
