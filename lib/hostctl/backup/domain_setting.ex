defmodule Hostctl.Backup.DomainSetting do
  use Ecto.Schema
  import Ecto.Changeset

  alias Hostctl.Hosting.Domain

  schema "domain_backup_settings" do
    field :include_files, :boolean, default: true
    field :include_mail, :boolean, default: true
    field :s3_mode, :string

    belongs_to :domain, Domain

    timestamps(type: :utc_datetime)
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:include_files, :include_mail, :s3_mode])
    |> validate_required([:include_files, :include_mail])
    |> validate_inclusion(:s3_mode, ["archive", "stream", nil],
      message: "must be archive, stream, or unset"
    )
  end
end
