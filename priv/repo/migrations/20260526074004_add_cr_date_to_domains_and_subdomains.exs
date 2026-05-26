defmodule Hostctl.Repo.Migrations.AddCrDateToDomainsAndSubdomains do
  use Ecto.Migration

  def change do
    alter table(:domains) do
      add :cr_date, :date, null: true
    end

    alter table(:subdomains) do
      add :cr_date, :date, null: true
    end
  end
end
