defmodule Hostctl.Repo.Migrations.AlterDnsRecordsValueToText do
  use Ecto.Migration

  def change do
    alter table(:dns_records) do
      modify :value, :text, null: false, from: {:string, null: false}
    end
  end
end
