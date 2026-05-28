defmodule Hostctl.Repo.Migrations.AddAccessHostToDbUsers do
  use Ecto.Migration

  def change do
    alter table(:db_users) do
      add :access_host, :string, null: false, default: "localhost"
    end
  end
end
