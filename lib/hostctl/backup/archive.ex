defmodule Hostctl.Backup.Archive do
  @moduledoc """
  Helpers for backup archive indexing, inspection, and selective extraction.
  """

  @index_file "_hostctl_backup_index.json"

  @restorable_roots ["database.sql", "mysql/", "postgresql/", "domains/", "mail/"]

  @doc "Writes an index file describing files inside a staged backup directory."
  def write_index!(staging_dir) when is_binary(staging_dir) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    entries =
      staging_dir
      |> list_files_recursive()
      |> Enum.reject(&(&1 == @index_file))
      |> Enum.map(fn rel_path ->
        full_path = Path.join(staging_dir, rel_path)
        {:ok, %File.Stat{size: size}} = File.stat(full_path)

        %{
          path: rel_path,
          bytes: size,
          kind: kind_for_path(rel_path)
        }
      end)
      |> Enum.sort_by(& &1.path)

    body =
      Jason.encode!(
        %{
          version: 1,
          generated_at: generated_at,
          entries: entries
        },
        pretty: true
      )

    File.write!(Path.join(staging_dir, @index_file), body)
  end

  @doc "Inspects a .tar.gz backup archive and returns restorable entries plus optional index data."
  def inspect_archive(archive_path) when is_binary(archive_path) do
    with {:ok, members} <- list_members(archive_path) do
      index = maybe_read_index(archive_path)
      size_by_path = build_size_map(index)

      items =
        members
        |> Enum.map(&normalize_member/1)
        |> Enum.uniq()
        |> Enum.filter(&restorable_path?/1)
        |> Enum.map(fn normalized_path ->
          %{
            id: normalized_path,
            path: normalized_path,
            tar_member: tar_member_for_path(members, normalized_path),
            kind: kind_for_path(normalized_path),
            label: label_for_path(normalized_path),
            bytes: Map.get(size_by_path, normalized_path)
          }
        end)
        |> Enum.sort_by(& &1.path)

      {:ok,
       %{
         index_present?: not is_nil(index),
         index: index,
         items: items
       }}
    end
  end

  @doc "Extracts selected archive members into a timestamped restore staging directory."
  def extract_selected(archive_path, selected_members, target_root)
      when is_binary(archive_path) and is_list(selected_members) and is_binary(target_root) do
    safe_members =
      selected_members
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.contains?(&1, "..")))
      |> Enum.uniq()

    if safe_members == [] do
      {:error, :nothing_selected}
    else
      ts = Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")
      destination = Path.join(target_root, "restore-#{ts}")

      with :ok <- File.mkdir_p(destination),
           {_, 0} <- run_extract_cmd(archive_path, destination, safe_members) do
        {:ok, destination}
      else
        {:error, reason} -> {:error, reason}
        {output, code} -> {:error, "tar extract failed (exit #{code}): #{output}"}
      end
    end
  end

  @doc "Lists SQL dump files from an extracted restore staging directory."
  def list_sql_dumps(extracted_dir) when is_binary(extracted_dir) do
    extracted_dir
    |> list_files_recursive()
    |> Enum.filter(&String.ends_with?(&1, ".sql"))
    |> Enum.map(fn rel_path ->
      full_path = Path.join(extracted_dir, rel_path)

      %{
        id: rel_path,
        rel_path: rel_path,
        full_path: full_path,
        kind: kind_for_path(normalize_member(rel_path)),
        label: label_for_path(normalize_member(rel_path))
      }
    end)
    |> Enum.sort_by(& &1.rel_path)
  end

  def index_file, do: @index_file

  defp list_members(archive_path) do
    case System.cmd(tar_executable(), ["-tzf", archive_path], stderr_to_stdout: true) do
      {output, 0} ->
        members =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        {:ok, members}

      {output, code} ->
        {:error, "tar list failed (exit #{code}): #{output}"}
    end
  end

  defp maybe_read_index(archive_path) do
    case System.cmd(tar_executable(), ["-xOzf", archive_path, @index_file],
           stderr_to_stdout: true
         ) do
      {json, 0} ->
        case Jason.decode(json) do
          {:ok, decoded} -> decoded
          _ -> nil
        end

      _ ->
        case System.cmd(tar_executable(), ["-xOzf", archive_path, "./#{@index_file}"],
               stderr_to_stdout: true
             ) do
          {json, 0} ->
            case Jason.decode(json) do
              {:ok, decoded} -> decoded
              _ -> nil
            end

          _ ->
            nil
        end
    end
  end

  defp build_size_map(nil), do: %{}

  defp build_size_map(%{"entries" => entries}) when is_list(entries) do
    Enum.reduce(entries, %{}, fn entry, acc ->
      path = entry["path"]
      bytes = entry["bytes"]

      if is_binary(path) and is_integer(bytes) do
        Map.put(acc, normalize_member(path), bytes)
      else
        acc
      end
    end)
  end

  defp build_size_map(_), do: %{}

  defp tar_member_for_path(members, normalized_path) do
    Enum.find(members, normalized_path, fn member ->
      normalize_member(member) == normalized_path
    end)
  end

  defp normalize_member(path) do
    path
    |> String.trim()
    |> String.trim_leading("./")
    |> String.trim_leading("/")
    |> String.trim_trailing("/")
  end

  defp restorable_path?(path) do
    Enum.any?(@restorable_roots, fn prefix ->
      if String.ends_with?(prefix, "/") do
        String.starts_with?(path, prefix)
      else
        path == prefix
      end
    end)
  end

  defp kind_for_path("database.sql"), do: "panel_postgresql"
  defp kind_for_path("database.sql.gz"), do: "panel_postgresql"

  defp kind_for_path(path) when is_binary(path) do
    cond do
      String.starts_with?(path, "mysql/") -> "mysql"
      String.starts_with?(path, "postgresql/") -> "postgresql"
      String.starts_with?(path, "domains/") -> "domain_files"
      String.starts_with?(path, "mail/") -> "mail"
      true -> "other"
    end
  end

  defp kind_for_path(_), do: "other"

  defp label_for_path(path) do
    case kind_for_path(path) do
      "panel_postgresql" -> "Panel DB dump"
      "mysql" -> "MySQL dump"
      "postgresql" -> "PostgreSQL dump"
      "domain_files" -> "Domain archive"
      "mail" -> "Mail archive"
      _ -> "Backup entry"
    end
  end

  defp list_files_recursive(root_dir) do
    walk_dir(root_dir, "")
  end

  defp walk_dir(root_dir, rel_dir) do
    current = if rel_dir == "", do: root_dir, else: Path.join(root_dir, rel_dir)

    case File.ls(current) do
      {:ok, children} ->
        children
        |> Enum.sort()
        |> Enum.flat_map(fn child ->
          rel_path = if rel_dir == "", do: child, else: Path.join(rel_dir, child)
          full_path = Path.join(root_dir, rel_path)

          if File.dir?(full_path) do
            walk_dir(root_dir, rel_path)
          else
            [rel_path]
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp run_extract_cmd(archive_path, destination, members) do
    System.cmd(tar_executable(), ["-xzf", archive_path, "-C", destination] ++ members,
      stderr_to_stdout: true
    )
  end

  defp tar_executable do
    System.find_executable("tar") || "tar"
  end
end
