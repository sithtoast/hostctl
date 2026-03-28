defmodule Hostctl.Settings.DnsTemplateRecord do
  use Ecto.Schema
  import Ecto.Changeset

  alias Hostctl.Hosting.DnsRecord

  @doc """
  A DNS record template entry.

  The `name` and `value` fields support placeholders which are substituted
  with actual values when the template is applied to a new domain:

    - `{{domain}}`   — the domain name (e.g. `example.com`)
    - `{{ip}}`       — the server's primary IPv4 address
    - `{{ipv6}}`     — the server's primary IPv6 address
    - `{{hostname}}` — the server's hostname

  Examples:
    name:  "{{domain}}"          → "example.com"
    name:  "mail.{{domain}}"     → "mail.example.com"
    value: "{{ip}}"              → "203.0.113.10"
    value: "v=spf1 +a +mx +a:{{hostname}} -all" → "v=spf1 +a +mx +a:myserver.example.com -all"
  """

  schema "dns_template_records" do
    field :type, :string
    field :name, :string
    field :value, :string
    field :ttl, :integer, default: 3600
    field :priority, :integer
    field :description, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:type, :name, :value, :ttl, :priority, :description])
    |> validate_required([:type, :name, :value])
    |> validate_inclusion(:type, DnsRecord.valid_types(),
      message: "must be a valid DNS record type"
    )
    |> validate_length(:name, max: 255)
    |> validate_length(:value, max: 512)
    |> validate_number(:ttl, greater_than: 0)
  end
end
