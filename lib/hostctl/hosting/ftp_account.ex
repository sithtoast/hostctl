defmodule Hostctl.Hosting.FtpAccount do
  use Ecto.Schema
  import Ecto.Changeset

  alias Hostctl.Hosting.Domain

  schema "ftp_accounts" do
    field :username, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :home_dir, :string
    field :status, :string, default: "active"

    belongs_to :domain, Domain

    timestamps(type: :utc_datetime)
  end

  def changeset(ftp_account, attrs) do
    ftp_account
    |> cast(attrs, [:username, :password, :home_dir, :status])
    |> validate_required([:username, :password])
    |> validate_format(:username, ~r/^[a-z0-9._\-]+$/i,
      message: "must contain only letters, numbers, dots, underscores, and hyphens"
    )
    |> validate_length(:username, max: 32)
    |> validate_length(:password, min: 8, max: 72)
    |> validate_inclusion(:status, ~w(active suspended))
    |> unique_constraint(:username)
    |> put_hashed_password()
  end

  defp put_hashed_password(changeset) do
    case get_change(changeset, :password) do
      nil -> changeset
      password -> put_change(changeset, :hashed_password, Bcrypt.hash_pwd_salt(password))
    end
  end
end
