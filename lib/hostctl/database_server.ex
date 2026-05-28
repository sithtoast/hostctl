defmodule Hostctl.DatabaseServer do
  @moduledoc """
  Manages MySQL and PostgreSQL database and user provisioning for hosted applications.

  When databases are created or deleted via the `Hostctl.Hosting` context,
  these functions create/drop the actual database and grant/revoke user
  privileges on the respective database server.

  ## MySQL Configuration

      config :hostctl, :database_server,
        enabled: true,
        hostname: "localhost",
        port: 3306,
        username: "root",
        password: "hostctl"

  Set `enabled: false` in test/dev environments to skip all MySQL operations.

  ## PostgreSQL Configuration

      config :hostctl, :postgres_server,
        enabled: true,
        hostname: "localhost",
        port: 5432,
        username: "postgres",
        password: "postgres"

  Set `enabled: false` in test/dev environments to skip all PostgreSQL operations.
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

  def create_database(%Database{db_type: "postgresql"} = database) do
    if pg_enabled?() do
      case pg_create_database(database.name) do
        :ok ->
          Logger.info("[DatabaseServer] Created PostgreSQL database #{database.name}")
          :ok

        {:error, reason} ->
          Logger.error(
            "[DatabaseServer] Failed to create PostgreSQL database #{database.name}: #{inspect(reason)}. " <>
              "Ensure POSTGRES_ROOT_URL is set in the env file and the service has been restarted."
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

  def drop_database(%Database{db_type: "postgresql"} = database) do
    if pg_enabled?() do
      case pg_drop_database(database.name) do
        :ok ->
          Logger.info("[DatabaseServer] Dropped PostgreSQL database #{database.name}")
          :ok

        {:error, reason} ->
          Logger.error(
            "[DatabaseServer] Failed to drop PostgreSQL database #{database.name}: #{inspect(reason)}"
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
      case do_create_user(db_user.username, raw_password, database.name, db_user.access_host) do
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

  def create_user(%DbUser{} = db_user, %Database{db_type: "postgresql"} = database, raw_password) do
    if pg_enabled?() do
      case pg_create_user(db_user.username, raw_password, database.name) do
        :ok ->
          Logger.info(
            "[DatabaseServer] Created PostgreSQL user #{db_user.username} for database #{database.name}"
          )

          :ok

        {:error, reason} ->
          Logger.error(
            "[DatabaseServer] Failed to create PostgreSQL user #{db_user.username}: #{inspect(reason)}"
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
      case do_drop_user(db_user.username, db_user.access_host) do
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

  def drop_user(%DbUser{} = db_user, %Database{db_type: "postgresql"}) do
    if pg_enabled?() do
      case pg_drop_user(db_user.username) do
        :ok ->
          Logger.info("[DatabaseServer] Dropped PostgreSQL user #{db_user.username}")
          :ok

        {:error, reason} ->
          Logger.error(
            "[DatabaseServer] Failed to drop PostgreSQL user #{db_user.username}: #{inspect(reason)}"
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
      case do_update_password(db_user.username, raw_password, db_user.access_host) do
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

  def update_user_password(%DbUser{} = db_user, %Database{db_type: "postgresql"}, raw_password) do
    if pg_enabled?() do
      case pg_update_password(db_user.username, raw_password) do
        :ok ->
          Logger.info("[DatabaseServer] Updated password for PostgreSQL user #{db_user.username}")
          :ok

        {:error, reason} ->
          Logger.error(
            "[DatabaseServer] Failed to update password for PostgreSQL user #{db_user.username}: #{inspect(reason)}"
          )

          {:error, reason}
      end
    else
      :ok
    end
  end

  def update_user_password(%DbUser{}, %Database{}, _raw_password), do: :ok

  @doc """
  Updates a DB user's access host configuration and password.

  For MySQL, this always keeps localhost access and optionally provisions
  a specific remote host account.
  """
  def update_user_access(
        %DbUser{} = db_user,
        %Database{db_type: "mysql"} = database,
        raw_password,
        new_access_host
      ) do
    if enabled?() do
      case do_update_user_access(
             db_user.username,
             raw_password,
             database.name,
             db_user.access_host,
             new_access_host
           ) do
        :ok ->
          Logger.info(
            "[DatabaseServer] Updated MySQL user #{db_user.username} access for database #{database.name}"
          )

          :ok

        {:error, reason} ->
          Logger.error(
            "[DatabaseServer] Failed to update MySQL user #{db_user.username} access: #{inspect(reason)}"
          )

          {:error, reason}
      end
    else
      :ok
    end
  end

  def update_user_access(
        %DbUser{} = db_user,
        %Database{db_type: "postgresql"},
        raw_password,
        _new_access_host
      ) do
    if pg_enabled?() do
      case pg_update_password(db_user.username, raw_password) do
        :ok ->
          Logger.info("[DatabaseServer] Updated password for PostgreSQL user #{db_user.username}")
          :ok

        {:error, reason} ->
          Logger.error(
            "[DatabaseServer] Failed to update password for PostgreSQL user #{db_user.username}: #{inspect(reason)}"
          )

          {:error, reason}
      end
    else
      :ok
    end
  end

  def update_user_access(%DbUser{}, %Database{}, _raw_password, _new_access_host), do: :ok

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

  defp do_create_user(username, password, db_name, access_host) do
    # Username is validated to be alphanumeric + underscores only (see DbUser.changeset),
    # so interpolation is safe. MariaDB does not accept ? placeholders in DDL statements
    # (CREATE USER / IDENTIFIED BY), so we interpolate the escaped password directly.
    esc_pw = escape_string(password)
    remote_host = remote_mysql_host(access_host)

    with_connection(fn conn ->
      with :ok <-
             query(
               conn,
               "CREATE USER IF NOT EXISTS '#{username}'@'localhost' IDENTIFIED BY '#{esc_pw}'"
             ),
           :ok <-
             query(
               conn,
               "GRANT ALL PRIVILEGES ON `#{db_name}`.* TO '#{username}'@'localhost'"
             ),
           :ok <- maybe_create_remote_user(conn, username, esc_pw, db_name, remote_host),
           :ok <- query(conn, "FLUSH PRIVILEGES") do
        :ok
      end
    end)
  end

  defp do_drop_user(username, access_host) do
    remote_host = remote_mysql_host(access_host)

    with_connection(fn conn ->
      with :ok <- query(conn, "DROP USER IF EXISTS '#{username}'@'localhost'"),
           :ok <- maybe_drop_remote_user(conn, username, remote_host),
           :ok <- query(conn, "DROP USER IF EXISTS '#{username}'@'%'"),
           :ok <- query(conn, "FLUSH PRIVILEGES") do
        :ok
      end
    end)
  end

  defp do_update_password(username, password, access_host) do
    esc_pw = escape_string(password)
    remote_host = remote_mysql_host(access_host)

    with_connection(fn conn ->
      with :ok <-
             query(
               conn,
               "ALTER USER '#{username}'@'localhost' IDENTIFIED BY '#{esc_pw}'"
             ),
           :ok <- maybe_update_remote_user_password(conn, username, esc_pw, remote_host),
           :ok <- query(conn, "FLUSH PRIVILEGES") do
        :ok
      end
    end)
  end

  defp do_update_user_access(username, password, db_name, old_access_host, new_access_host) do
    esc_pw = escape_string(password)
    old_remote_host = remote_mysql_host(old_access_host)
    new_remote_host = remote_mysql_host(new_access_host)

    with_connection(fn conn ->
      with :ok <-
             query(
               conn,
               "ALTER USER '#{username}'@'localhost' IDENTIFIED BY '#{esc_pw}'"
             ),
           :ok <-
             sync_remote_mysql_user(
               conn,
               username,
               esc_pw,
               db_name,
               old_remote_host,
               new_remote_host
             ),
           :ok <- query(conn, "DROP USER IF EXISTS '#{username}'@'%'"),
           :ok <- query(conn, "FLUSH PRIVILEGES") do
        :ok
      end
    end)
  end

  defp sync_remote_mysql_user(_conn, _username, _esc_pw, _db_name, nil, nil), do: :ok

  defp sync_remote_mysql_user(conn, username, _esc_pw, _db_name, old_remote_host, nil) do
    maybe_drop_remote_user(conn, username, old_remote_host)
  end

  defp sync_remote_mysql_user(conn, username, esc_pw, db_name, nil, new_remote_host) do
    maybe_create_remote_user(conn, username, esc_pw, db_name, new_remote_host)
  end

  defp sync_remote_mysql_user(
         conn,
         username,
         esc_pw,
         _db_name,
         old_remote_host,
         new_remote_host
       )
       when old_remote_host == new_remote_host do
    maybe_update_remote_user_password(conn, username, esc_pw, old_remote_host)
  end

  defp sync_remote_mysql_user(conn, username, esc_pw, db_name, old_remote_host, new_remote_host) do
    with :ok <- maybe_drop_remote_user(conn, username, old_remote_host),
         :ok <- maybe_create_remote_user(conn, username, esc_pw, db_name, new_remote_host) do
      :ok
    end
  end

  defp maybe_create_remote_user(_conn, _username, _esc_pw, _db_name, nil), do: :ok

  defp maybe_create_remote_user(conn, username, esc_pw, db_name, remote_host) do
    esc_host = escape_string(remote_host)

    with :ok <-
           query(
             conn,
             "CREATE USER IF NOT EXISTS '#{username}'@'#{esc_host}' IDENTIFIED BY '#{esc_pw}'"
           ),
         :ok <-
           query(
             conn,
             "GRANT ALL PRIVILEGES ON `#{db_name}`.* TO '#{username}'@'#{esc_host}'"
           ) do
      :ok
    end
  end

  defp maybe_drop_remote_user(_conn, _username, nil), do: :ok

  defp maybe_drop_remote_user(conn, username, remote_host) do
    esc_host = escape_string(remote_host)
    query(conn, "DROP USER IF EXISTS '#{username}'@'#{esc_host}'")
  end

  defp maybe_update_remote_user_password(_conn, _username, _esc_pw, nil), do: :ok

  defp maybe_update_remote_user_password(conn, username, esc_pw, remote_host) do
    esc_host = escape_string(remote_host)
    query(conn, "ALTER USER '#{username}'@'#{esc_host}' IDENTIFIED BY '#{esc_pw}'")
  end

  defp remote_mysql_host(nil), do: nil
  defp remote_mysql_host(""), do: nil
  defp remote_mysql_host("localhost"), do: nil
  defp remote_mysql_host(host), do: host

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

  # Escape a string for safe interpolation into a MySQL/MariaDB single-quoted literal.
  # Escapes backslashes first, then single quotes.
  defp escape_string(str) do
    str
    |> String.replace("\\\\", "\\\\\\\\")
    |> String.replace("'", "''")
  end

  defp enabled?, do: Keyword.get(config(), :enabled, false)

  defp config, do: Application.get_env(:hostctl, :database_server, [])

  # ---------------------------------------------------------------------------
  # Private — PostgreSQL operations
  # ---------------------------------------------------------------------------

  defp pg_create_database(name) do
    pg_with_connection(fn conn ->
      # CREATE DATABASE cannot run inside a transaction
      case Postgrex.query(conn, "SELECT 1 FROM pg_database WHERE datname = $1", [name]) do
        {:ok, %{num_rows: 0}} ->
          # Database names are validated by schema to be alphanumeric + underscores,
          # so quoting with double quotes is safe here.
          pg_query(conn, ~s(CREATE DATABASE "#{name}"))

        {:ok, _} ->
          :ok

        {:error, error} ->
          {:error, error}
      end
    end)
  end

  defp pg_drop_database(name) do
    pg_with_connection(fn conn ->
      # Terminate active connections before dropping
      _ =
        Postgrex.query(
          conn,
          "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = $1 AND pid <> pg_backend_pid()",
          [name]
        )

      pg_query(conn, ~s(DROP DATABASE IF EXISTS "#{name}"))
    end)
  end

  defp pg_create_user(username, password, db_name) do
    pg_with_connection(fn conn ->
      # Check if role already exists
      case Postgrex.query(conn, "SELECT 1 FROM pg_roles WHERE rolname = $1", [username]) do
        {:ok, %{num_rows: 0}} ->
          with :ok <-
                 pg_query(
                   conn,
                   ~s(CREATE USER "#{username}" WITH PASSWORD '#{pg_escape_string(password)}')
                 ),
               :ok <-
                 pg_query(
                   conn,
                   ~s(GRANT ALL PRIVILEGES ON DATABASE "#{db_name}" TO "#{username}")
                 ) do
            :ok
          end

        {:ok, _} ->
          # User exists, just update password and ensure grants
          with :ok <-
                 pg_query(
                   conn,
                   ~s(ALTER USER "#{username}" WITH PASSWORD '#{pg_escape_string(password)}')
                 ),
               :ok <-
                 pg_query(
                   conn,
                   ~s(GRANT ALL PRIVILEGES ON DATABASE "#{db_name}" TO "#{username}")
                 ) do
            :ok
          end

        {:error, error} ->
          {:error, error}
      end
    end)
  end

  defp pg_drop_user(username) do
    pg_with_connection(fn conn ->
      pg_query(conn, ~s(DROP USER IF EXISTS "#{username}"))
    end)
  end

  defp pg_update_password(username, password) do
    pg_with_connection(fn conn ->
      pg_query(conn, ~s(ALTER USER "#{username}" WITH PASSWORD '#{pg_escape_string(password)}'))
    end)
  end

  defp pg_with_connection(fun) do
    opts = [
      hostname: Keyword.get(pg_config(), :hostname, "localhost"),
      port: Keyword.get(pg_config(), :port, 5432),
      username: Keyword.get(pg_config(), :username, "postgres"),
      password: Keyword.get(pg_config(), :password, "postgres"),
      database: "postgres",
      ssl: Keyword.get(pg_config(), :ssl, false),
      pool_size: 1,
      backoff_type: :stop
    ]

    case Postgrex.start_link(opts) do
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

  defp pg_query(conn, sql) do
    case Postgrex.query(conn, sql, []) do
      {:ok, _result} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  # Escape a string for safe interpolation into a PostgreSQL single-quoted literal.
  defp pg_escape_string(str) do
    String.replace(str, "'", "''")
  end

  defp pg_enabled?, do: Keyword.get(pg_config(), :enabled, false)

  defp pg_config, do: Application.get_env(:hostctl, :postgres_server, [])
end
