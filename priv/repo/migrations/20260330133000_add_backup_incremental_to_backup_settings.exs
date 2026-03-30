defmodule Hostctl.Repo.Migrations.AddBackupIncrementalToBackupSettings do
  use Ecto.Migration

  def change do
    alter table(:backup_settings) do
      add :backup_incremental, :boolean, default: false, null: false
    end
  end
end
