defmodule Hostctl.Settings.ServerIpSetting do
  use Ecto.Schema
  import Ecto.Changeset

  schema "server_ip_settings" do
    field :ip_address, :string
    field :interface, :string
    field :external_ip, :string
    field :label, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:ip_address, :interface, :external_ip, :label])
    |> validate_required([:ip_address])
    |> validate_format(:external_ip, ~r/^(\d{1,3}\.){3}\d{1,3}$|^[a-zA-Z0-9._-]+$|^$/,
      message: "must be a valid IP address or hostname"
    )
    |> unique_constraint(:ip_address)
  end
end
