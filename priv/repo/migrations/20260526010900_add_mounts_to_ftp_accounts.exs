defmodule Hostctl.Repo.Migrations.AddMountsToFtpAccounts do
  use Ecto.Migration

  def change do
    alter table(:ftp_accounts) do
      add :mounts, {:array, :map}, default: []
    end
  end
end
