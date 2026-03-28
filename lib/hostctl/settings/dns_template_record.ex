defmodule Hostctl.Settings.DnsTemplateRecord do
  use Ecto.Schema
  import Ecto.Changeset

  alias Hostctl.Hosting.DnsRecord

  @doc """
  A DNS record template entry.

  The `name` and `value` fields support a `{{domain}}` placeholder which is
  substituted with the actual domain name when the template is applied.

  Examples:
    name:  "@"         → kept as-is
    name:  "www"       → kept as-is
    value: "{{domain}}" → replaced with "example.com"
    value: "mail.{{domain}}" → replaced with "mail.example.com"
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
