defmodule Hostctl.Repo.Migrations.CreateServerIpSettings do
  use Ecto.Migration

  def change do
    create table(:server_ip_settings) do
      add :ip_address, :string, null: false
      add :interface, :string
      add :external_ip, :string
      add :label, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:server_ip_settings, [:ip_address])
  end
end
