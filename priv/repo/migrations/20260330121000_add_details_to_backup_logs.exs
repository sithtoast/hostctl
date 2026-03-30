defmodule Hostctl.Repo.Migrations.AddDetailsToBackupLogs do
  use Ecto.Migration

  def change do
    alter table(:backup_logs) do
      add :details, :map
    end
  end
end
