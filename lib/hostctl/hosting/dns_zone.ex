defmodule Hostctl.Hosting.DnsZone do
  use Ecto.Schema
  import Ecto.Changeset

  alias Hostctl.Hosting.{Domain, DnsRecord}

  schema "dns_zones" do
    field :ttl, :integer, default: 3600
    field :status, :string, default: "active"

    belongs_to :domain, Domain
    has_many :dns_records, DnsRecord

    timestamps(type: :utc_datetime)
  end

  def changeset(dns_zone, attrs) do
    dns_zone
    |> cast(attrs, [:ttl, :status])
    |> validate_required([:ttl])
    |> validate_number(:ttl, greater_than: 0)
    |> validate_inclusion(:status, ~w(active inactive))
  end
end
