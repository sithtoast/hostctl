defmodule Hostctl.Backup.SubdomainSetting do
  use Ecto.Schema
  import Ecto.Changeset

  alias Hostctl.Hosting.Subdomain

  schema "subdomain_backup_settings" do
    field :include_files, :boolean, default: true
    field :excluded_dirs, {:array, :string}, default: []
    field :s3_mode, :string

    belongs_to :subdomain, Subdomain

    timestamps(type: :utc_datetime)
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:include_files, :excluded_dirs, :s3_mode])
    |> validate_required([:include_files])
    |> validate_inclusion(:s3_mode, ["archive", "stream", "raw", nil],
      message: "must be archive, stream, raw, or unset"
    )
    |> update_change(:excluded_dirs, &normalize_excluded_dirs/1)
  end

  defp normalize_excluded_dirs(nil), do: []

  defp normalize_excluded_dirs(dirs) when is_list(dirs) do
    dirs
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.trim_leading(&1, "/"))
    |> Enum.reject(&String.contains?(&1, ".."))
    |> Enum.uniq()
  end

  defp normalize_excluded_dirs(_), do: []
end
