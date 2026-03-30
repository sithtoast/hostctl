defmodule Hostctl.Backup.DomainSetting do
  use Ecto.Schema
  import Ecto.Changeset

  alias Hostctl.Hosting.Domain

  schema "domain_backup_settings" do
    field :include_files, :boolean, default: true

    belongs_to :domain, Domain

    timestamps(type: :utc_datetime)
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:include_files])
    |> validate_required([:include_files])
  end
end
