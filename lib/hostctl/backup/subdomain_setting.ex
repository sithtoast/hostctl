defmodule Hostctl.Backup.SubdomainSetting do
  use Ecto.Schema
  import Ecto.Changeset

  alias Hostctl.Hosting.Subdomain

  schema "subdomain_backup_settings" do
    field :include_files, :boolean, default: true

    belongs_to :subdomain, Subdomain

    timestamps(type: :utc_datetime)
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:include_files])
    |> validate_required([:include_files])
  end
end
