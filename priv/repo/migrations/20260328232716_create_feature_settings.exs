defmodule Hostctl.Repo.Migrations.CreateFeatureSettings do
  use Ecto.Migration

  def change do
    create table(:feature_settings) do
      add :key, :string, null: false
      add :enabled, :boolean, default: false, null: false
      add :status, :string, default: "not_installed"
      add :status_message, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:feature_settings, [:key])
  end
end
