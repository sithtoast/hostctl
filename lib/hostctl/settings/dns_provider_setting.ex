defmodule Hostctl.Settings.DnsProviderSetting do
  use Ecto.Schema
  import Ecto.Changeset

  @valid_providers ~w(local cloudflare digitalocean)

  schema "dns_provider_settings" do
    field :provider, :string, default: "local"
    field :cloudflare_api_token, Hostctl.EncryptedField, redact: true
    field :digitalocean_api_token, Hostctl.EncryptedField, redact: true
    field :clear_digitalocean_token, :boolean, virtual: true, default: false

    timestamps(type: :utc_datetime)
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [
      :provider,
      :cloudflare_api_token,
      :digitalocean_api_token,
      :clear_digitalocean_token
    ])
    |> preserve_token(:cloudflare_api_token)
    |> preserve_token(:digitalocean_api_token)
    |> clear_token()
    |> validate_required([:provider])
    |> validate_inclusion(:provider, @valid_providers,
      message: "must be one of: #{Enum.join(@valid_providers, ", ")}"
    )
  end

  defp preserve_token(changeset, field) do
    if get_change(changeset, field) in [nil, ""],
      do: delete_change(changeset, field),
      else: changeset
  end

  defp clear_token(changeset) do
    if get_field(changeset, :clear_digitalocean_token),
      do: put_change(changeset, :digitalocean_api_token, nil),
      else: changeset
  end

  def valid_providers, do: @valid_providers
end
