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

  @doc "Changeset for creating a new FTP account. Username and password are required."
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
    |> validate_home_dir()
    |> unique_constraint(:username)
    |> put_hashed_password()
  end

  @doc "Changeset for updating an existing FTP account. Password is optional."
  def update_changeset(ftp_account, attrs) do
    ftp_account
    |> cast(attrs, [:password, :home_dir, :status])
    |> clear_empty_password()
    |> validate_length(:password, min: 8, max: 72)
    |> validate_inclusion(:status, ~w(active suspended))
    |> validate_home_dir()
    |> put_hashed_password()
  end

  # Treat a submitted empty string as "no change" so updates to home_dir/status
  # don't require re-entering the password.
  defp clear_empty_password(changeset) do
    case get_change(changeset, :password) do
      "" -> delete_change(changeset, :password)
      _ -> changeset
    end
  end

  defp validate_home_dir(changeset) do
    case get_field(changeset, :home_dir) do
      nil ->
        changeset

      home_dir ->
        if String.match?(home_dir, ~r|^/var/www/[^/]+(/.*)?$|) do
          changeset
        else
          add_error(changeset, :home_dir, "must be within /var/www/<domain>")
        end
    end
  end

  defp put_hashed_password(changeset) do
    case get_change(changeset, :password) do
      nil -> changeset
      password -> put_change(changeset, :hashed_password, Bcrypt.hash_pwd_salt(password))
    end
  end
end
