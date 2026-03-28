defmodule Hostctl.Hosting.EmailAccount do
  use Ecto.Schema
  import Ecto.Changeset

  alias Hostctl.Hosting.Domain

  schema "email_accounts" do
    field :username, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :quota_mb, :integer, default: 1024
    field :status, :string, default: "active"

    belongs_to :domain, Domain

    timestamps(type: :utc_datetime)
  end

  def changeset(email_account, attrs) do
    email_account
    |> cast(attrs, [:username, :password, :quota_mb, :status])
    |> validate_required([:username, :password])
    |> validate_format(:username, ~r/^[a-z0-9._\-+]+$/i,
      message: "must contain only letters, numbers, dots, underscores, and hyphens"
    )
    |> validate_length(:username, max: 64)
    |> validate_length(:password, min: 8, max: 72)
    |> validate_number(:quota_mb, greater_than: 0)
    |> validate_inclusion(:status, ~w(active suspended))
    |> unique_constraint(:username, name: :email_accounts_domain_id_username_index)
    |> put_hashed_password()
  end

  defp put_hashed_password(changeset) do
    case get_change(changeset, :password) do
      nil -> changeset
      password -> put_change(changeset, :hashed_password, Bcrypt.hash_pwd_salt(password))
    end
  end
end
