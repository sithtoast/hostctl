defmodule Hostctl.Backup.Restore do
  @moduledoc """
  Restore helpers for importing SQL dumps into panel and hosted databases.
  """

  @preview_read_bytes 65_536

  @doc """
  Validates a SQL dump before import.

  Returns `{:ok, %{warnings: [String.t()], details: [String.t()]}}` if import can proceed,
  or `{:error, reason}` if the dump should not be imported.
  """
  def preview_sql(kind, sql_path, target_db \\ nil)

  def preview_sql(kind, sql_path, target_db) do
    with :ok <- validate_sql_file(sql_path),
         {:ok, header} <- read_header(sql_path),
         :ok <- validate_target(kind, target_db),
         :ok <- validate_client_available(kind),
         :ok <- validate_dump_family(kind, header) do
      warnings =
        header
        |> preview_warnings(kind)

      details =
        [
          "File: #{sql_path}",
          "Kind: #{kind}"
        ] ++
          if(target_db in [nil, ""], do: [], else: ["Target DB: #{target_db}"])

      {:ok, %{warnings: warnings, details: details}}
    end
  end

  @doc """
  Imports a SQL file by backup item kind.

  Kinds:
    - "panel_postgresql" -> imports into hostctl panel database
    - "mysql" -> imports into provided MySQL database target
    - "postgresql" -> imports into provided PostgreSQL database target
  """
  def import_sql(kind, sql_path, target_db \\ nil)

  def import_sql("panel_postgresql", sql_path, _target_db) do
    with {:ok, _preview} <- preview_sql("panel_postgresql", sql_path, nil) do
      do_import_panel_postgresql(sql_path)
    end
  end

  def import_sql("mysql", sql_path, target_db) when is_binary(target_db) and target_db != "" do
    with {:ok, _preview} <- preview_sql("mysql", sql_path, target_db) do
      do_import_mysql(sql_path, target_db)
    end
  end

  def import_sql("postgresql", sql_path, target_db)
      when is_binary(target_db) and target_db != "" do
    with {:ok, _preview} <- preview_sql("postgresql", sql_path, target_db) do
      do_import_postgresql(sql_path, target_db)
    end
  end

  def import_sql("mysql", _sql_path, _target_db), do: {:error, "Select a target MySQL database."}

  def import_sql("postgresql", _sql_path, _target_db),
    do: {:error, "Select a target PostgreSQL database."}

  def import_sql(_kind, _sql_path, _target_db), do: {:error, "This item is not a SQL dump."}

  defp do_import_panel_postgresql(sql_path) do
    {host, port, username, password, panel_db} = panel_postgres_config()

    run_psql(sql_path, host, port, username, password, panel_db)
  end

  defp do_import_mysql(sql_path, target_db) do
    {host, port, username, password} = mysql_server_config()
    mysql = System.find_executable("mysql") || "mysql"

    args = [
      "--host",
      host,
      "--port",
      port,
      "--user",
      username,
      target_db,
      "--execute",
      "source #{sql_path}"
    ]

    case System.cmd(mysql, args, env: [{"MYSQL_PWD", password}], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, code} -> {:error, "mysql import failed (exit #{code}): #{output}"}
    end
  end

  defp do_import_postgresql(sql_path, target_db) do
    {host, port, username, password, _panel_db} = panel_postgres_config()

    run_psql(sql_path, host, port, username, password, target_db)
  end

  defp validate_sql_file(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size > 0 -> :ok
      {:ok, _} -> {:error, "SQL dump file is empty."}
      {:error, reason} -> {:error, "Cannot read SQL dump file: #{inspect(reason)}"}
    end
  end

  defp read_header(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        try do
          case IO.binread(io, @preview_read_bytes) do
            :eof -> {:ok, ""}
            data when is_binary(data) -> {:ok, data}
            {:error, reason} -> {:error, "Cannot read SQL dump file: #{inspect(reason)}"}
          end
        after
          File.close(io)
        end

      {:error, reason} ->
        {:error, "Cannot open SQL dump file: #{inspect(reason)}"}
    end
  end

  defp validate_target("mysql", target_db) when is_binary(target_db) and target_db != "", do: :ok

  defp validate_target("postgresql", target_db)
       when is_binary(target_db) and target_db != "",
       do: :ok

  defp validate_target("panel_postgresql", _target_db), do: :ok
  defp validate_target("mysql", _target_db), do: {:error, "Select a target MySQL database."}

  defp validate_target("postgresql", _target_db),
    do: {:error, "Select a target PostgreSQL database."}

  defp validate_target(_kind, _target_db), do: {:error, "This item is not a SQL dump."}

  defp validate_client_available("mysql") do
    if System.find_executable("mysql"), do: :ok, else: {:error, "mysql CLI not found on host."}
  end

  defp validate_client_available(kind) when kind in ["postgresql", "panel_postgresql"] do
    if System.find_executable("psql"), do: :ok, else: {:error, "psql CLI not found on host."}
  end

  defp validate_client_available(_), do: :ok

  defp validate_dump_family(kind, header) do
    family = detect_dump_family(header)

    case {kind, family} do
      {"mysql", :postgresql} ->
        {:error, "Dump appears to be PostgreSQL, not MySQL."}

      {"postgresql", :mysql} ->
        {:error, "Dump appears to be MySQL/MariaDB, not PostgreSQL."}

      {"panel_postgresql", :mysql} ->
        {:error, "Dump appears to be MySQL/MariaDB, not PostgreSQL."}

      _ ->
        :ok
    end
  end

  defp preview_warnings(header, kind) do
    warnings = []

    warnings =
      if byte_size(header) >= @preview_read_bytes do
        ["Large SQL file: only the first #{@preview_read_bytes} bytes were inspected." | warnings]
      else
        warnings
      end

    warnings =
      if detect_dump_family(header) == :unknown do
        ["Dump signature not recognized from header; proceed carefully." | warnings]
      else
        warnings
      end

    warnings =
      if kind == "mysql" and String.contains?(header, "DEFINER=") do
        ["Dump contains DEFINER clauses; target server privileges may be required." | warnings]
      else
        warnings
      end

    Enum.reverse(warnings)
  end

  defp detect_dump_family(header) when is_binary(header) do
    cond do
      String.contains?(header, "PostgreSQL database dump") -> :postgresql
      String.contains?(header, "SET search_path") -> :postgresql
      String.contains?(header, "MySQL dump") -> :mysql
      String.contains?(header, "MariaDB dump") -> :mysql
      String.contains?(header, "/*!40101") -> :mysql
      true -> :unknown
    end
  end

  defp run_psql(sql_path, host, port, username, password, database) do
    psql = System.find_executable("psql") || "psql"

    args = [
      "--host",
      host,
      "--port",
      port,
      "--username",
      username,
      "--no-password",
      "--single-transaction",
      "--set",
      "ON_ERROR_STOP=1",
      "--dbname",
      database,
      "--file",
      sql_path
    ]

    case System.cmd(psql, args, env: [{"PGPASSWORD", password}], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, code} -> {:error, "psql import failed (exit #{code}): #{output}"}
    end
  end

  defp mysql_server_config do
    cfg = Application.get_env(:hostctl, :database_server, [])
    host = to_string(Keyword.get(cfg, :hostname, "localhost"))
    port = to_string(Keyword.get(cfg, :port, 3306))
    username = to_string(Keyword.get(cfg, :username, "root"))
    password = to_string(Keyword.get(cfg, :password, ""))
    {host, port, username, password}
  end

  defp panel_postgres_config do
    config = Hostctl.Repo.config()
    host = to_string(Keyword.get(config, :hostname, "localhost"))
    port = to_string(Keyword.get(config, :port, 5432))
    username = to_string(Keyword.get(config, :username, "postgres"))
    password = to_string(Keyword.get(config, :password) || "")
    database = to_string(Keyword.get(config, :database, "hostctl"))
    {host, port, username, password, database}
  end
end
