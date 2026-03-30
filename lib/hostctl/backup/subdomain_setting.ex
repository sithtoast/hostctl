defmodule Hostctl.Backup.SubdomainSetting do
  use Ecto.Schema
  import Ecto.Changeset

  alias Hostctl.Hosting.Subdomain

  schema "subdomain_backup_settings" do
    field :include_files, :boolean, default: true
    field :s3_mode, :string

    belongs_to :subdomain, Subdomain

    timestamps(type: :utc_datetime)
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:include_files, :s3_mode])
    |> validate_required([:include_files])
    |> validate_inclusion(:s3_mode, ["archive", "stream", nil],
      message: "must be archive, stream, or unset"
    )
  end
end
