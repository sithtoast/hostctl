defmodule Hostctl.Repo.Migrations.AddScopeToDomainS3Backends do
  use Ecto.Migration

  def change do
    alter table(:domain_s3_backends) do
      # Empty string = applies to the whole domain (existing behaviour).
      # Non-empty = applies to this subdomain only (e.g. "static" → static.example.com).
      add :subdomain, :string, null: false, default: ""

      # Empty string = applies to the entire domain/subdomain.
      # Non-empty = generates a location block for this URL path only (e.g. "/assets").
      add :url_path, :string, null: false, default: ""
    end

    # Replace the old per-domain unique constraint with one that allows multiple
    # backends per domain as long as their scope (subdomain + url_path) differs.
    drop index(:domain_s3_backends, [:domain_id])
    create unique_index(:domain_s3_backends, [:domain_id, :subdomain, :url_path])
  end
end
