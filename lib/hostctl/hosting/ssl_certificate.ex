defmodule Hostctl.Hosting.SslCertificate do
  use Ecto.Schema
  import Ecto.Changeset

  alias Hostctl.Hosting.Domain

  schema "ssl_certificates" do
    field :cert_type, :string, default: "lets_encrypt"
    field :certificate, :string
    field :private_key, :string
    field :expires_at, :utc_datetime
    field :status, :string, default: "pending"
    field :log, :string
    field :email, :string

    belongs_to :domain, Domain

    timestamps(type: :utc_datetime)
  end

  def changeset(ssl_certificate, attrs) do
    ssl_certificate
    |> cast(attrs, [:cert_type, :certificate, :private_key, :expires_at, :status, :log, :email])
    |> validate_required([:cert_type])
    |> validate_inclusion(:cert_type, ~w(lets_encrypt custom))
    |> validate_inclusion(:status, ~w(active pending expired))
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
      message: "must be a valid email address"
    )
  end
end
