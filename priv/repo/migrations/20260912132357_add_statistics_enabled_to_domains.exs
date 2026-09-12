defmodule Hostctl.Repo.Migrations.AddStatisticsEnabledToDomains do
  use Ecto.Migration

  def change do
    alter table(:domains) do
      add :statistics_enabled, :boolean, default: true, null: false
    end
  end
end
