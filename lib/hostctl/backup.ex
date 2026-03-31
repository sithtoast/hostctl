defmodule Hostctl.Backup do
  @moduledoc """
  Context for managing backup settings, logs, and triggering backup runs.
  """

  import Ecto.Query
  alias Hostctl.Repo
  alias Hostctl.Backup.S3
  alias Hostctl.Backup.{Setting, Log, DomainSetting, SubdomainSetting}
  alias Hostctl.Hosting.{Domain, Subdomain}
  alias Hostctl.Hosting.Database

  # ---------------------------------------------------------------------------
  # Settings
  # ---------------------------------------------------------------------------

  @doc "Returns the single backup settings row, creating it if it doesn't exist."
  def get_or_create_settings do
    case Repo.one(Setting) do
      nil -> Repo.insert!(%Setting{})
      setting -> setting
    end
  end

  @doc "Returns a changeset for the backup settings."
  def change_settings(%Setting{} = setting, attrs \\ %{}) do
    Setting.changeset(setting, attrs)
  end

  @doc "Saves updated backup settings."
  def update_settings(%Setting{} = setting, attrs) do
    setting
    |> Setting.changeset(attrs)
    |> Repo.update()
  end

  # ---------------------------------------------------------------------------
  # Logs
  # ---------------------------------------------------------------------------

  @doc "Lists recent backup logs, newest first."
  def list_logs(limit \\ 25) do
    Log
    |> order_by([l], desc: l.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Creates a backup log entry."
  def create_log(attrs) do
    %Log{}
    |> Log.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Updates an existing backup log entry."
  def update_log(%Log{} = log, attrs) do
    log
    |> Log.changeset(attrs)
    |> Repo.update()
  end

  @doc "Returns the most recent successful backup log, or nil."
  def get_last_successful_log do
    Log
    |> where([l], l.status == "success")
    |> order_by([l], desc: l.completed_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc "Returns a backup log by id, or nil."
  def get_log(id) when is_integer(id), do: Repo.get(Log, id)

  @doc "Lists successful completed backups with optional filters."
  def list_completed_logs(filters \\ %{}, limit \\ 200) do
    trigger = Map.get(filters, "trigger", "all")
    destination = Map.get(filters, "destination", "all")
    from_date = Map.get(filters, "from_date", "")
    to_date = Map.get(filters, "to_date", "")
    query = Map.get(filters, "query", "") |> to_string() |> String.trim() |> String.downcase()

    logs =
      Log
      |> where([l], l.status == "success")
      |> maybe_filter_trigger(trigger)
      |> maybe_filter_destination(destination)
      |> maybe_filter_from_date(from_date)
      |> maybe_filter_to_date(to_date)
      |> order_by([l], desc: l.completed_at, desc: l.inserted_at)
      |> limit(^limit)
      |> Repo.all()

    if query == "" do
      logs
    else
      Enum.filter(logs, &completed_log_matches_query?(&1, query))
    end
  end

  @doc "Returns true if a backup is currently marked as running."
  def backup_running? do
    Repo.exists?(from l in Log, where: l.status == "running")
  end

  defp maybe_filter_trigger(query, "all"), do: query
  defp maybe_filter_trigger(query, nil), do: query

  defp maybe_filter_trigger(query, trigger) do
    where(query, [l], l.trigger == ^trigger)
  end

  defp maybe_filter_destination(query, "all"), do: query
  defp maybe_filter_destination(query, nil), do: query

  defp maybe_filter_destination(query, destination) do
    where(query, [l], l.destination == ^destination)
  end

  defp maybe_filter_from_date(query, nil), do: query
  defp maybe_filter_from_date(query, ""), do: query

  defp maybe_filter_from_date(query, from_date) do
    case Date.from_iso8601(from_date) do
      {:ok, date} ->
        {:ok, start_of_day} = NaiveDateTime.new(date, ~T[00:00:00])
        where(query, [l], not is_nil(l.completed_at) and l.completed_at >= ^start_of_day)

      _ ->
        query
    end
  end

  defp maybe_filter_to_date(query, nil), do: query
  defp maybe_filter_to_date(query, ""), do: query

  defp maybe_filter_to_date(query, to_date) do
    case Date.from_iso8601(to_date) do
      {:ok, date} ->
        {:ok, end_of_day} = NaiveDateTime.new(date, ~T[23:59:59])
        where(query, [l], not is_nil(l.completed_at) and l.completed_at <= ^end_of_day)

      _ ->
        query
    end
  end

  defp completed_log_matches_query?(log, query) do
    details = log.details || %{}
    domain_names = Map.get(details, :domain_names) || Map.get(details, "domain_names") || []

    haystack =
      [
        log.local_path,
        log.s3_key,
        log.destination,
        log.trigger
      ] ++ domain_names

    Enum.any?(haystack, fn value ->
      is_binary(value) and String.contains?(String.downcase(value), query)
    end)
  end

  # ---------------------------------------------------------------------------
  # Per-domain settings
  # ---------------------------------------------------------------------------

  @doc """
  Returns all domains paired with their backup setting (or a default if none exists).
  Result is a list of `{domain, domain_setting}` tuples ordered by domain name.
  """
  def list_domains_with_backup_settings do
    from(d in Domain,
      left_join: s in DomainSetting,
      on: s.domain_id == d.id,
      order_by: [asc: d.name],
      select: {d, s}
    )
    |> Repo.all()
    |> Enum.map(fn {domain, setting} ->
      {domain,
       setting ||
         %DomainSetting{
           domain_id: domain.id,
           include_files: true,
           include_mail: true,
           excluded_dirs: []
         }}
    end)
  end

  @doc """
  Returns the IDs of domains that should have their files backed up.
  Domains with no setting row are included by default.
  """
  def file_backup_domain_ids do
    explicitly_excluded =
      Repo.all(from s in DomainSetting, where: s.include_files == false, select: s.domain_id)

    Repo.all(
      from d in Domain,
        where: d.id not in ^explicitly_excluded,
        select: d.id
    )
  end

  @doc "Upserts the `include_files` flag for a single domain."
  def set_domain_include_files(domain_id, include_files) when is_boolean(include_files) do
    case Repo.get_by(DomainSetting, domain_id: domain_id) do
      nil ->
        %DomainSetting{domain_id: domain_id}
        |> DomainSetting.changeset(%{include_files: include_files})
        |> Repo.insert()

      setting ->
        setting
        |> DomainSetting.changeset(%{include_files: include_files})
        |> Repo.update()
    end
  end

  @doc "Upserts the `include_mail` flag for a single domain."
  def set_domain_include_mail(domain_id, include_mail) when is_boolean(include_mail) do
    case Repo.get_by(DomainSetting, domain_id: domain_id) do
      nil ->
        %DomainSetting{domain_id: domain_id}
        |> DomainSetting.changeset(%{include_mail: include_mail})
        |> Repo.insert()

      setting ->
        setting
        |> DomainSetting.changeset(%{include_mail: include_mail})
        |> Repo.update()
    end
  end

  @doc "Returns domain names that should have their mail backed up (include_mail is true)."
  def mail_backup_domain_names do
    explicitly_excluded =
      Repo.all(from s in DomainSetting, where: s.include_mail == false, select: s.domain_id)

    Repo.all(
      from d in Domain,
        where: d.id not in ^explicitly_excluded,
        select: d.name
    )
  end

  # ---------------------------------------------------------------------------
  # Per-subdomain settings
  # ---------------------------------------------------------------------------

  @doc """
  Returns all domains with their backup settings and each domain's subdomains
  with their backup settings, ordered by domain name then subdomain name.
  Result shape:
    [%{id, name, document_root, include_files, subdomains: [%{id, name, full_name, document_root, include_files}]}]
  """
  def list_domain_groups do
    domain_rows =
      from(d in Domain,
        left_join: ds in DomainSetting,
        on: ds.domain_id == d.id,
        order_by: [asc: d.name],
        select: {d, ds}
      )
      |> Repo.all()

    subdomain_rows =
      from(s in Subdomain,
        left_join: ss in SubdomainSetting,
        on: ss.subdomain_id == s.id,
        order_by: [asc: s.name],
        select: {s, ss}
      )
      |> Repo.all()

    subs_by_domain = Enum.group_by(subdomain_rows, fn {sub, _} -> sub.domain_id end)

    Enum.map(domain_rows, fn {domain, ds} ->
      domain_setting =
        ds ||
          %DomainSetting{
            domain_id: domain.id,
            include_files: true,
            include_mail: true,
            excluded_dirs: []
          }

      subdomains =
        subs_by_domain
        |> Map.get(domain.id, [])
        |> Enum.map(fn {sub, ss} ->
          %{
            id: sub.id,
            name: sub.name,
            full_name: "#{sub.name}.#{domain.name}",
            document_root: sub.document_root,
            include_files: if(ss, do: ss.include_files, else: true),
            excluded_dirs: if(ss, do: ss.excluded_dirs || [], else: []),
            s3_mode: if(ss, do: ss.s3_mode, else: nil)
          }
        end)

      %{
        id: domain.id,
        name: domain.name,
        document_root: domain.document_root,
        include_files: domain_setting.include_files,
        include_mail: domain_setting.include_mail,
        excluded_dirs: domain_setting.excluded_dirs || [],
        s3_mode: domain_setting.s3_mode,
        subdomains: subdomains
      }
    end)
  end

  @doc "Upserts the `include_files` flag for a single subdomain."
  def set_subdomain_include_files(subdomain_id, include_files) when is_boolean(include_files) do
    case Repo.get_by(SubdomainSetting, subdomain_id: subdomain_id) do
      nil ->
        %SubdomainSetting{subdomain_id: subdomain_id}
        |> SubdomainSetting.changeset(%{include_files: include_files})
        |> Repo.insert()

      setting ->
        setting
        |> SubdomainSetting.changeset(%{include_files: include_files})
        |> Repo.update()
    end
  end

  @doc "Upserts excluded directories for a single domain."
  def set_domain_excluded_dirs(domain_id, excluded_dirs) when is_list(excluded_dirs) do
    case Repo.get_by(DomainSetting, domain_id: domain_id) do
      nil ->
        %DomainSetting{domain_id: domain_id}
        |> DomainSetting.changeset(%{excluded_dirs: excluded_dirs})
        |> Repo.insert()

      setting ->
        setting
        |> DomainSetting.changeset(%{excluded_dirs: excluded_dirs})
        |> Repo.update()
    end
  end

  @doc "Upserts excluded directories for a single subdomain."
  def set_subdomain_excluded_dirs(subdomain_id, excluded_dirs) when is_list(excluded_dirs) do
    case Repo.get_by(SubdomainSetting, subdomain_id: subdomain_id) do
      nil ->
        %SubdomainSetting{subdomain_id: subdomain_id}
        |> SubdomainSetting.changeset(%{excluded_dirs: excluded_dirs})
        |> Repo.insert()

      setting ->
        setting
        |> SubdomainSetting.changeset(%{excluded_dirs: excluded_dirs})
        |> Repo.update()
    end
  end

  @doc "Upserts the `s3_mode` override for a single domain (nil clears override)."
  def set_domain_s3_mode(domain_id, s3_mode)
      when s3_mode in ["archive", "stream", "raw", nil] do
    case Repo.get_by(DomainSetting, domain_id: domain_id) do
      nil ->
        %DomainSetting{domain_id: domain_id}
        |> DomainSetting.changeset(%{include_files: true, s3_mode: s3_mode})
        |> Repo.insert()

      setting ->
        setting
        |> DomainSetting.changeset(%{s3_mode: s3_mode})
        |> Repo.update()
    end
  end

  @doc "Upserts the `s3_mode` override for a single subdomain (nil clears override)."
  def set_subdomain_s3_mode(subdomain_id, s3_mode)
      when s3_mode in ["archive", "stream", "raw", nil] do
    case Repo.get_by(SubdomainSetting, subdomain_id: subdomain_id) do
      nil ->
        %SubdomainSetting{subdomain_id: subdomain_id}
        |> SubdomainSetting.changeset(%{include_files: true, s3_mode: s3_mode})
        |> Repo.insert()

      setting ->
        setting
        |> SubdomainSetting.changeset(%{s3_mode: s3_mode})
        |> Repo.update()
    end
  end

  @doc "Returns subdomain IDs that have been explicitly excluded from file backups."
  def file_backup_excluded_subdomain_ids do
    Repo.all(
      from ss in SubdomainSetting, where: ss.include_files == false, select: ss.subdomain_id
    )
  end

  # ---------------------------------------------------------------------------
  # Restore helpers
  # ---------------------------------------------------------------------------

  @doc "Lists local backup archives available for restore selection."
  def list_restore_local_archives(limit \\ 25) do
    local_dir = get_or_create_settings().local_path || "/var/backups/hostctl"

    case File.ls(local_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&archive_file?/1)
        |> Enum.map(fn name ->
          path = Path.join(local_dir, name)

          %{mtime: mtime} =
            case File.stat(path, time: :posix) do
              {:ok, %File.Stat{mtime: file_mtime}} -> %{mtime: file_mtime}
              _ -> %{mtime: 0}
            end

          %{name: name, path: path, mtime: mtime}
        end)
        |> Enum.sort_by(& &1.mtime, :desc)
        |> Enum.take(limit)

      {:error, _} ->
        []
    end
  end

  @doc "Lists S3 backup archives under the configured backup prefix."
  def list_restore_s3_archives(limit \\ 50) do
    settings = get_or_create_settings()

    if settings.s3_enabled do
      prefix = settings.s3_path_prefix || "hostctl-backups"

      case S3.list_objects(settings, prefix <> "/") do
        {:ok, objects} ->
          archives =
            objects
            |> Enum.filter(fn %{key: key} -> archive_file?(key) end)
            |> Enum.sort_by(fn %{last_modified: lm} -> lm || "" end, :desc)
            |> Enum.take(limit)

          {:ok, archives}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, []}
    end
  end

  @doc "Returns available database names grouped by backend for restore targeting."
  def restore_database_targets do
    panel_db = to_string(Keyword.get(Hostctl.Repo.config(), :database, "hostctl"))

    mysql =
      Repo.all(
        from d in Database,
          where: d.db_type == "mysql" and d.status == "active",
          order_by: [asc: d.name],
          select: d.name
      )

    postgresql =
      Repo.all(
        from d in Database,
          where: d.db_type == "postgresql" and d.status == "active",
          order_by: [asc: d.name],
          select: d.name
      )

    %{panel_postgresql: panel_db, mysql: mysql, postgresql: postgresql}
  end

  # ---------------------------------------------------------------------------
  # Raw S3 restore helpers
  # ---------------------------------------------------------------------------

  @doc """
  Lists domain names that have raw (non-archive) files in S3 under the
  configured `domains/` prefix. Returns `{:ok, [domain_name]}` or `{:error, reason}`.
  """
  def list_raw_s3_domains do
    settings = get_or_create_settings()

    if settings.s3_enabled do
      prefix = (settings.s3_path_prefix || "hostctl-backups") <> "/domains/"

      case S3.list_objects(settings, prefix) do
        {:ok, objects} ->
          domains =
            objects
            |> Enum.map(fn %{key: key} -> key |> String.trim_leading(prefix) end)
            |> Enum.map(fn rel ->
              # Raw files look like: domains/example.com/path/to/file
              # Archives look like: domains/example.com.tar.gz
              rel |> String.split("/", parts: 2) |> List.first()
            end)
            |> Enum.reject(fn name ->
              is_nil(name) or name == "" or archive_file?(name)
            end)
            |> Enum.uniq()
            |> Enum.sort()

          {:ok, domains}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, []}
    end
  end

  @doc """
  Lists all raw (non-archive) S3 objects under a specific domain prefix.
  Returns `{:ok, [%{key, rel_path, size, last_modified}]}` or `{:error, reason}`.
  """
  def list_raw_s3_domain_files(domain_name) when is_binary(domain_name) do
    settings = get_or_create_settings()

    if settings.s3_enabled do
      prefix = (settings.s3_path_prefix || "hostctl-backups") <> "/domains/#{domain_name}/"

      case S3.list_objects(settings, prefix) do
        {:ok, objects} ->
          files =
            objects
            |> Enum.reject(fn %{key: key} -> archive_file?(key) end)
            |> Enum.map(fn obj ->
              Map.put(obj, :rel_path, String.trim_leading(obj.key, prefix))
            end)
            |> Enum.reject(fn %{rel_path: rel} -> rel == "" end)
            |> Enum.sort_by(& &1.rel_path)

          {:ok, files}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, []}
    end
  end

  @doc """
  Downloads all raw S3 files for a domain into the given target directory,
  preserving the directory structure. Returns `{:ok, count}` or `{:error, reason}`.
  """
  def restore_raw_s3_domain(domain_name, target_dir)
      when is_binary(domain_name) and is_binary(target_dir) do
    settings = get_or_create_settings()

    case list_raw_s3_domain_files(domain_name) do
      {:ok, []} ->
        {:error, "No raw files found for #{domain_name}."}

      {:ok, files} ->
        results =
          Enum.map(files, fn %{key: s3_key, rel_path: rel_path} ->
            dest = Path.join(target_dir, rel_path)

            case S3.download(settings, s3_key, dest) do
              {:ok, _} -> :ok
              {:error, reason} -> {:error, "#{rel_path}: #{reason}"}
            end
          end)

        errors = Enum.filter(results, &match?({:error, _}, &1))

        if errors == [] do
          {:ok, length(files)}
        else
          error_msgs = Enum.map(errors, fn {:error, msg} -> msg end) |> Enum.join("; ")
          {:error, "Some files failed to restore: #{error_msgs}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the document root for a domain by name, or nil if not found.
  """
  def domain_document_root(domain_name) when is_binary(domain_name) do
    Repo.one(from d in Domain, where: d.name == ^domain_name, select: d.document_root)
  end

  @doc """
  Lists all non-archive S3 objects under a specific key prefix.
  Returns `{:ok, [%{key, rel_path, size, last_modified}]}` or `{:error, reason}`.
  """
  def list_s3_prefix_files(prefix) when is_binary(prefix) do
    settings = get_or_create_settings()

    if settings.s3_enabled do
      search_prefix = String.trim_trailing(prefix, "/") <> "/"

      case S3.list_objects(settings, search_prefix) do
        {:ok, objects} ->
          files =
            objects
            |> Enum.reject(fn %{key: key} -> archive_file?(key) end)
            |> Enum.map(fn obj ->
              Map.put(obj, :rel_path, String.trim_leading(obj.key, search_prefix))
            end)
            |> Enum.reject(fn %{rel_path: rel} -> rel == "" end)
            |> Enum.sort_by(& &1.rel_path)

          {:ok, files}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, []}
    end
  end

  @doc """
  Downloads all non-archive files under a specific S3 prefix to the given
  target directory, preserving directory structure.
  Returns `{:ok, count}` or `{:error, reason}`.
  """
  def restore_s3_prefix_to_dir(prefix, target_dir)
      when is_binary(prefix) and is_binary(target_dir) do
    settings = get_or_create_settings()

    case list_s3_prefix_files(prefix) do
      {:ok, []} ->
        {:error, "No files found under prefix."}

      {:ok, files} ->
        results =
          Enum.map(files, fn %{key: s3_key, rel_path: rel_path} ->
            dest = Path.join(target_dir, rel_path)

            case S3.download(settings, s3_key, dest) do
              {:ok, _} -> :ok
              {:error, reason} -> {:error, "#{rel_path}: #{reason}"}
            end
          end)

        errors = Enum.filter(results, &match?({:error, _}, &1))

        if errors == [] do
          {:ok, length(files)}
        else
          error_msgs = Enum.map(errors, fn {:error, msg} -> msg end) |> Enum.join("; ")
          {:error, "Some files failed to restore: #{error_msgs}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp archive_file?(name) when is_binary(name) do
    String.ends_with?(name, ".tar.gz") or String.ends_with?(name, ".tgz")
  end

  defp archive_file?(_), do: false
end
