defmodule Hostctl.Repo.Migrations.CreateSmarthostSettings do
  use Ecto.Migration

  def change do
    create table(:smarthost_settings) do
      add :enabled, :boolean, default: false, null: false
      add :host, :string
      add :port, :integer, default: 587
      add :auth_required, :boolean, default: true, null: false
      add :username, :string
      add :password, :string

      timestamps(type: :utc_datetime)
    end
  end
end
