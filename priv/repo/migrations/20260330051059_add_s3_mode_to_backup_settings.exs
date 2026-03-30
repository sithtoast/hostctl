defmodule Hostctl.Repo.Migrations.AddS3ModeToBackupSettings do
  use Ecto.Migration

  def change do
    alter table(:backup_settings) do
      add :s3_mode, :string, default: "archive", null: false
    end
  end
end
