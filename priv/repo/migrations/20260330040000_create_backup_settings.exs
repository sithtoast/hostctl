defmodule Hostctl.Repo.Migrations.CreateBackupSettings do
  use Ecto.Migration

  def change do
    create table(:backup_settings) do
      add :local_enabled, :boolean, default: false, null: false
      add :local_path, :string, default: "/var/backups/hostctl"
      add :local_retention_days, :integer, default: 7

      add :s3_enabled, :boolean, default: false, null: false
      add :s3_endpoint, :string
      add :s3_region, :string, default: "us-east-1"
      add :s3_bucket, :string
      add :s3_access_key_id, :string
      add :s3_secret_access_key, :string
      add :s3_path_prefix, :string, default: "hostctl-backups"
      add :s3_retention_days, :integer, default: 30

      add :schedule_enabled, :boolean, default: false, null: false
      add :schedule_frequency, :string, default: "daily"
      add :schedule_hour, :integer, default: 2
      add :schedule_minute, :integer, default: 0
      add :schedule_day_of_week, :integer, default: 1

      add :backup_database, :boolean, default: true, null: false
      add :backup_files, :boolean, default: false, null: false

      timestamps(type: :utc_datetime)
    end
  end
end
