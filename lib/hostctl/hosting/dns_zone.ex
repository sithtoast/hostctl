defmodule Hostctl.Hosting.DnsZone do
  use Ecto.Schema
  import Ecto.Changeset

  alias Hostctl.Hosting.{Domain, DnsRecord}

  schema "dns_zones" do
    field :ttl, :integer, default: 3600
    field :status, :string, default: "active"
    field :cloudflare_zone_id, :string

    field :provider, :string, default: "inherit"
    field :cloudflare_api_token, Hostctl.EncryptedField, redact: true
    field :clear_cloudflare_token, :boolean, virtual: true, default: false
    field :digitalocean_api_token, Hostctl.EncryptedField, redact: true
    field :digitalocean_zone_name, :string
    field :clear_digitalocean_token, :boolean, virtual: true, default: false

    belongs_to :domain, Domain
    has_many :dns_records, DnsRecord

    timestamps(type: :utc_datetime)
  end

  def provider_changeset(zone, attrs) do
    zone
    |> cast(attrs, [
      :provider,
      :cloudflare_api_token,
      :clear_cloudflare_token,
      :digitalocean_api_token,
      :clear_digitalocean_token
    ])
    |> validate_required([:provider])
    |> validate_inclusion(:provider, ~w(inherit local cloudflare digitalocean))
    |> preserve_token(:cloudflare_api_token, :clear_cloudflare_token)
    |> preserve_token(:digitalocean_api_token, :clear_digitalocean_token)
  end

  defp preserve_token(cs, token, clear) do
    cs =
      if get_change(cs, token) in [nil, ""],
        do: delete_change(cs, token),
        else: cs

    if get_field(cs, clear),
      do: put_change(cs, token, nil),
      else: cs
  end

  def changeset(dns_zone, attrs) do
    dns_zone
    |> cast(attrs, [:ttl, :status, :cloudflare_zone_id])
    |> validate_required([:ttl])
    |> validate_number(:ttl, greater_than: 0)
    |> validate_inclusion(:status, ~w(active inactive))
  end
end
