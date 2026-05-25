defmodule Hostctl.Repo.Migrations.AddCredentialsToDomainS3Backends do
  use Ecto.Migration

  def change do
    alter table(:domain_s3_backends) do
      add :access_key_id, :string
      add :secret_access_key, :string
      add :region, :string
    end
  end
end
