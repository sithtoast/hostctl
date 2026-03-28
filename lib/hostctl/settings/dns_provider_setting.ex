defmodule Hostctl.Settings.DnsProviderSetting do
  use Ecto.Schema
  import Ecto.Changeset

  @valid_providers ~w(local cloudflare)

  schema "dns_provider_settings" do
    field :provider, :string, default: "local"
    field :cloudflare_api_token, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:provider, :cloudflare_api_token])
    |> validate_required([:provider])
    |> validate_inclusion(:provider, @valid_providers,
      message: "must be one of: #{Enum.join(@valid_providers, ", ")}"
    )
  end

  def valid_providers, do: @valid_providers
end
