defmodule Hostctl.Repo.Migrations.AddCrDateToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :cr_date, :date, null: true
    end
  end
end
