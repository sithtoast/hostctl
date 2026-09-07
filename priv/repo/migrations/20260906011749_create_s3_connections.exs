defmodule Hostctl.Repo.Migrations.CreateS3Connections do
  use Ecto.Migration

  def change do
    create table(:s3_connections) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :endpoint_url, :string, null: false
      add :region, :string, null: false, default: "us-east-1"
      add :access_key_id, :text, null: false
      add :secret_access_key, :text, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:s3_connections, [:user_id, :name])
  end
end
