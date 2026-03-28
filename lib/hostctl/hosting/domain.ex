defmodule Hostctl.Hosting.Domain do
  use Ecto.Schema
  import Ecto.Changeset

  alias Hostctl.Accounts.User

  alias Hostctl.Hosting.{
    Subdomain,
    DnsZone,
    EmailAccount,
    Database,
    SslCertificate,
    CronJob,
    FtpAccount
  }

  schema "domains" do
    field :name, :string
    field :document_root, :string
    field :php_version, :string, default: "8.3"
    field :status, :string, default: "active"
    field :ssl_enabled, :boolean, default: false
    field :disk_usage_mb, :integer, default: 0

    belongs_to :user, User
    has_many :subdomains, Subdomain
    has_one :dns_zone, DnsZone
    has_many :email_accounts, EmailAccount
    has_many :databases, Database
    has_one :ssl_certificate, SslCertificate
    has_many :cron_jobs, CronJob
    has_many :ftp_accounts, FtpAccount

    timestamps(type: :utc_datetime)
  end

  @valid_statuses ~w(active suspended pending)
  @valid_php_versions ~w(7.4 8.0 8.1 8.2 8.3 8.4)

  def changeset(domain, attrs) do
    domain
    |> cast(attrs, [:name, :document_root, :php_version, :status, :ssl_enabled])
    |> validate_required([:name])
    |> validate_format(:name, ~r/^[a-z0-9]([a-z0-9\-]{0,61}[a-z0-9])?(\.[a-z]{2,})+$/i,
      message: "must be a valid domain name"
    )
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_inclusion(:php_version, @valid_php_versions)
    |> unique_constraint(:name)
    |> maybe_set_document_root()
  end

  defp maybe_set_document_root(changeset) do
    name = get_field(changeset, :name)
    doc_root = get_field(changeset, :document_root)

    auto_generated? = is_nil(doc_root) or doc_root == "" or
                      Regex.match?(~r|^/var/www/[^/]+/public$|, doc_root)

    if is_binary(name) and name != "" and auto_generated? do
      put_change(changeset, :document_root, "/var/www/#{name}/public")
    else
      changeset
    end
  end
end
