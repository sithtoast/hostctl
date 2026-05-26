defmodule Hostctl.Repo.Migrations.AddAutoindexToDomainsAndSubdomains do
  use Ecto.Migration

  def change do
    alter table(:domains) do
      add :autoindex, :boolean, null: false, default: false
    end

    alter table(:subdomains) do
      add :autoindex, :boolean, null: false, default: false
    end
  end
end
