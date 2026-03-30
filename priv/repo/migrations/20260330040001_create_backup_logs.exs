defmodule Hostctl.Repo.Migrations.CreateBackupLogs do
  use Ecto.Migration

  def change do
    create table(:backup_logs) do
      add :status, :string, default: "pending", null: false
      add :trigger, :string, default: "manual", null: false
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :file_size_bytes, :integer
      add :destination, :string
      add :local_path, :string
      add :s3_key, :string
      add :error_message, :text

      timestamps(type: :utc_datetime)
    end
  end
end
