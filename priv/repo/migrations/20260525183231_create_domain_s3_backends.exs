defmodule Hostctl.Repo.Migrations.CreateDomainS3Backends do
  use Ecto.Migration

  def change do
    create table(:domain_s3_backends) do
      add :endpoint_url, :string, null: false
      add :bucket, :string, null: false
      add :path_prefix, :string, null: false, default: ""
      add :enabled, :boolean, null: false, default: true
      add :domain_id, references(:domains, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:domain_s3_backends, [:domain_id])
  end
end
