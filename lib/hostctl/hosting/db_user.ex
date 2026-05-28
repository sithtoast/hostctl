defmodule Hostctl.Hosting.DbUser do
  use Ecto.Schema
  import Ecto.Changeset

  alias Hostctl.Hosting.Database

  schema "db_users" do
    field :username, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :access_host, :string, default: "localhost"
    field :access_mode, :string, virtual: true, default: "localhost"

    belongs_to :database, Database

    timestamps(type: :utc_datetime)
  end

  def changeset(db_user, attrs) do
    db_user
    |> cast(attrs, [:username, :password, :access_host, :access_mode])
    |> put_access_mode()
    |> normalize_access_host()
    |> validate_required([:username, :password])
    |> validate_format(:username, ~r/^[a-z0-9_]+$/i,
      message: "must contain only letters, numbers, and underscores"
    )
    |> validate_length(:username, max: 32)
    |> validate_length(:password, min: 8, max: 72)
    |> validate_access_host()
    |> unique_constraint(:username, name: :db_users_database_id_username_index)
    |> put_hashed_password()
  end

  def access_changeset(db_user, attrs, opts \\ []) do
    require_password? = Keyword.get(opts, :require_password, true)

    db_user
    |> cast(attrs, [:password, :access_host, :access_mode])
    |> put_access_mode()
    |> normalize_access_host()
    |> maybe_validate_password(require_password?)
    |> validate_access_host()
    |> put_hashed_password()
  end

  defp put_access_mode(changeset) do
    access_mode =
      changeset
      |> get_change(:access_mode)
      |> normalize_access_mode(infer_access_mode(get_field(changeset, :access_host)))

    put_change(changeset, :access_mode, access_mode)
  end

  defp normalize_access_host(changeset) do
    case get_field(changeset, :access_mode) do
      "remote" ->
        access_host =
          changeset
          |> get_field(:access_host)
          |> normalize_host_value()

        put_change(changeset, :access_host, access_host)

      _ ->
        put_change(changeset, :access_host, "localhost")
    end
  end

  defp validate_access_host(changeset) do
    case get_field(changeset, :access_mode) do
      "remote" ->
        access_host = get_field(changeset, :access_host)

        cond do
          access_host in [nil, ""] ->
            add_error(changeset, :access_host, "can't be blank")

          not valid_access_host?(access_host) ->
            add_error(changeset, :access_host, "must be a valid IP address or hostname")

          true ->
            changeset
        end

      _ ->
        changeset
    end
  end

  defp put_hashed_password(changeset) do
    case get_change(changeset, :password) do
      nil -> changeset
      password -> put_change(changeset, :hashed_password, Bcrypt.hash_pwd_salt(password))
    end
  end

  defp maybe_validate_password(changeset, true) do
    changeset
    |> validate_required([:password])
    |> validate_length(:password, min: 8, max: 72)
  end

  defp maybe_validate_password(changeset, false) do
    case get_change(changeset, :password) do
      nil -> changeset
      _password -> validate_length(changeset, :password, min: 8, max: 72)
    end
  end

  defp infer_access_mode(nil), do: "localhost"
  defp infer_access_mode(""), do: "localhost"
  defp infer_access_mode("localhost"), do: "localhost"
  defp infer_access_mode(_), do: "remote"

  defp normalize_access_mode(nil, fallback), do: fallback
  defp normalize_access_mode("remote", _fallback), do: "remote"
  defp normalize_access_mode(_value, _fallback), do: "localhost"

  defp normalize_host_value(nil), do: ""

  defp normalize_host_value(access_host) do
    access_host
    |> String.trim()
    |> String.downcase()
  end

  defp valid_access_host?(access_host) do
    String.match?(access_host, ~r/\A[a-z0-9](?:[a-z0-9.:-]*[a-z0-9])?\z/) and
      not String.contains?(access_host, "%") and
      access_host != "localhost"
  end
end
