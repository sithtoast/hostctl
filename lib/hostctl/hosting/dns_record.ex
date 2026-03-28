defmodule Hostctl.Hosting.DnsRecord do
  use Ecto.Schema
  import Ecto.Changeset

  alias Hostctl.Hosting.DnsZone

  @valid_types ~w(A AAAA CNAME MX TXT NS SRV CAA)

  schema "dns_records" do
    field :type, :string
    field :name, :string
    field :value, :string
    field :ttl, :integer, default: 3600
    field :priority, :integer
    field :cloudflare_record_id, :string

    belongs_to :dns_zone, DnsZone

    timestamps(type: :utc_datetime)
  end

  def changeset(dns_record, attrs) do
    dns_record
    |> cast(attrs, [:type, :name, :value, :ttl, :priority])
    |> validate_required([:type, :name, :value])
    |> validate_inclusion(:type, @valid_types, message: "must be a valid DNS record type")
    |> validate_length(:name, max: 255)
    |> validate_length(:value, max: 512)
    |> validate_number(:ttl, greater_than: 0)
  end

  def valid_types, do: @valid_types
end
