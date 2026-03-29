defmodule Hostctl.DatabaseServer do
  @moduledoc """
  Manages MySQL database and user provisioning for hosted applications.

  When databases with `db_type: "mysql"` are created or deleted via the
  `Hostctl.Hosting` context, these functions create/drop the actual MySQL
  database and grant/revoke user privileges on the MySQL server.

  Connects to MySQL using the `myxql` library with root credentials
  configured via the `:database_server` application config.

  ## Configuration

      config :hostctl, :database_server,
        enabled: true,
        hostname: "localhost",
        port: 3306,
        username: "root",
        password: "hostctl"

  Set `enabled: false` in test/dev environments to skip all operations.
  """

  require Logger

  alias Hostctl.Hosting.Database
  alias Hostctl.Hosting.DbUser

  @doc """
  Creates a MySQL database on the server.

  Issues `CREATE DATABASE IF NOT EXISTS` to be idempotent.
  """
  def create_database(%Database{db_type: "mysql"} = database) do
    if enabled?() do
      case do_create_database(database.name) do
        :ok ->
          Logger.info("[DatabaseServer] Created MySQL database #{database.name}")
          :ok

        {:error, reason} ->
          Logger.error(
            "[DatabaseServer] Failed to create MySQL database #{database.name}: #{inspect(reason)}. " <>
              "Ensure MYSQL_ROOT_URL is set in the env file and the service has been restarted."
          )

          {:error, reason}
      end
    else
      :ok
    end
  end

  def create_database(%Database{}), do: :ok

  @doc """
  Drops a MySQL database from the server.

  Issues `DROP DATABASE IF EXISTS` to be idempotent.
  """
  def drop_database(%Database{db_type: "mysql"} = database) do
    if enabled?() do
      case do_drop_database(database.name) do
        :ok ->
          Logger.info("[DatabaseServer] Dropped MySQL database #{database.name}")
          :ok

        {:error, reason} ->
          Logger.error(
            "[DatabaseServer] Failed to drop MySQL database #{database.name}: #{inspect(reason)}"
          )

          {:error, reason}
      end
    else
      :ok
    end
  end

  def drop_database(%Database{}), do: :ok

  @doc """
  Creates a MySQL user and grants full privileges on the given database.

  The `raw_password` is the plaintext password captured before hashing.
  """
  def create_user(%DbUser{} = db_user, %Database{db_type: "mysql"} = database, raw_password) do
    if enabled?() do
      case do_create_user(db_user.username, raw_password, database.name) do
        :ok ->
          Logger.info(
            "[DatabaseServer] Created MySQL user #{db_user.username} for database #{database.name}"
          )

          :ok

        {:error, reason} ->
          Logger.error(
            "[DatabaseServer] Failed to create MySQL user #{db_user.username}: #{inspect(reason)}"
          )

          {:error, reason}
      end
    else
      :ok
    end
  end

  def create_user(%DbUser{}, %Database{}, _raw_password), do: :ok

  @doc """
  Drops a MySQL user from the server.
  """
  def drop_user(%DbUser{} = db_user, %Database{db_type: "mysql"}) do
    if enabled?() do
      case do_drop_user(db_user.username) do
        :ok ->
          Logger.info("[DatabaseServer] Dropped MySQL user #{db_user.username}")
          :ok

        {:error, reason} ->
          Logger.error(
            "[DatabaseServer] Failed to drop MySQL user #{db_user.username}: #{inspect(reason)}"
          )

          {:error, reason}
      end
    else
      :ok
    end
  end

  def drop_user(%DbUser{}, %Database{}), do: :ok

  @doc """
  Updates a MySQL user's password.
  """
  def update_user_password(%DbUser{} = db_user, %Database{db_type: "mysql"}, raw_password) do
    if enabled?() do
      case do_update_password(db_user.username, raw_password) do
        :ok ->
          Logger.info("[DatabaseServer] Updated password for MySQL user #{db_user.username}")
          :ok

        {:error, reason} ->
          Logger.error(
            "[DatabaseServer] Failed to update password for MySQL user #{db_user.username}: #{inspect(reason)}"
          )

          {:error, reason}
      end
    else
      :ok
    end
  end

  def update_user_password(%DbUser{}, %Database{}, _raw_password), do: :ok

  # ---------------------------------------------------------------------------
  # Private — MySQL operations
  # ---------------------------------------------------------------------------

  defp do_create_database(name) do
    # Database names are validated by the schema to be alphanumeric + underscores
    with_connection(fn conn ->
      query(
        conn,
        "CREATE DATABASE IF NOT EXISTS `#{name}` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
      )
    end)
  end

  defp do_drop_database(name) do
    with_connection(fn conn ->
      query(conn, "DROP DATABASE IF EXISTS `#{name}`")
    end)
  end

  defp do_create_user(username, password, db_name) do
    with_connection(fn conn ->
      with :ok <-
             query(conn, "CREATE USER IF NOT EXISTS ?@'%' IDENTIFIED BY ?", [username, password]),
           :ok <- query(conn, "GRANT ALL PRIVILEGES ON `#{db_name}`.* TO ?@'%'", [username]),
           :ok <- query(conn, "FLUSH PRIVILEGES") do
        :ok
      end
    end)
  end

  defp do_drop_user(username) do
    with_connection(fn conn ->
      with :ok <- query(conn, "DROP USER IF EXISTS ?@'%'", [username]),
           :ok <- query(conn, "FLUSH PRIVILEGES") do
        :ok
      end
    end)
  end

  defp do_update_password(username, password) do
    with_connection(fn conn ->
      with :ok <- query(conn, "ALTER USER ?@'%' IDENTIFIED BY ?", [username, password]),
           :ok <- query(conn, "FLUSH PRIVILEGES") do
        :ok
      end
    end)
  end

  defp with_connection(fun) do
    opts = [
      hostname: Keyword.get(config(), :hostname, "localhost"),
      port: Keyword.get(config(), :port, 3306),
      username: Keyword.get(config(), :username, "root"),
      password: Keyword.get(config(), :password, ""),
      database: "mysql",
      ssl: Keyword.get(config(), :ssl, false),
      pool_size: 1,
      backoff_type: :stop
    ]

    case MyXQL.start_link(opts) do
      {:ok, conn} ->
        try do
          fun.(conn)
        after
          GenServer.stop(conn)
        end

      {:error, reason} ->
        {:error, {:connection_failed, reason}}
    end
  end

  defp query(conn, sql, params \\ []) do
    case MyXQL.query(conn, sql, params) do
      {:ok, _result} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp enabled?, do: Keyword.get(config(), :enabled, false)

  defp config, do: Application.get_env(:hostctl, :database_server, [])
end
