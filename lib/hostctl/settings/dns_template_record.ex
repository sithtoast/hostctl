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
    field :service, :string, default: "auto"

    timestamps(type: :utc_datetime)
  end

  @doc "Classifies template services; explicit choices handle custom record names."
  def service(%__MODULE__{service: service}) when service in ~w(web mail shared), do: service

  def service(%__MODULE__{} = record) do
    name = record.name |> String.downcase() |> String.trim_trailing(".")
    value = record.value |> String.trim() |> String.trim_leading("\"") |> String.downcase()
    labels = String.split(name, ".")

    cond do
      record.type == "MX" ->
        "mail"

      record.type == "TXT" and
          String.starts_with?(value, ["v=spf1", "v=dmarc1", "v=dkim1", "v=tlsrptv1", "v=stsv1"]) ->
        "mail"

      Enum.any?(labels, &(&1 in ~w(_domainkey _dmarc _mta-sts))) ->
        "mail"

      hd(labels) in ~w(mail webmail smtp imap pop pop3 autodiscover autoconfig mta-sts _smtp _smtps _submission _submissions _imap _imaps _pop3 _pop3s _autodiscover) ->
        "mail"

      name in ["@", "{{domain}}"] and record.type in ~w(A AAAA CNAME) ->
        "web"

      hd(labels) in ~w(www ftp ipv4 ipv6) ->
        "web"

      true ->
        "shared"
    end
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:type, :name, :value, :ttl, :priority, :description, :service])
    |> validate_required([:service])
    |> validate_inclusion(:service, ~w(auto web mail shared))
    |> validate_required([:type, :name, :value])
    |> validate_inclusion(:type, DnsRecord.valid_types(),
      message: "must be a valid DNS record type"
    )
    |> validate_length(:name, max: 255)
    |> validate_length(:value, max: 512)
    |> validate_number(:ttl, greater_than: 0)
  end
end
