defmodule Hostctl.Repo.Migrations.AddDirectoryListingToDomainS3Backends do
  use Ecto.Migration

  def change do
    alter table(:domain_s3_backends) do
      add :directory_listing, :boolean, null: false, default: false
    end
  end
end
