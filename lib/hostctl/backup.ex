defmodule Hostctl.Backup do
  @moduledoc """
  Context for managing backup settings, logs, and triggering backup runs.
  """

  import Ecto.Query
  alias Hostctl.Repo
  alias Hostctl.Backup.{Setting, Log, DomainSetting, SubdomainSetting}
  alias Hostctl.Hosting.{Domain, Subdomain}

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

  @doc "Returns true if a backup is currently marked as running."
  def backup_running? do
    Repo.exists?(from l in Log, where: l.status == "running")
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
       setting || %DomainSetting{domain_id: domain.id, include_files: true, include_mail: true}}
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
        ds || %DomainSetting{domain_id: domain.id, include_files: true, include_mail: true}

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
            s3_mode: if(ss, do: ss.s3_mode, else: nil)
          }
        end)

      %{
        id: domain.id,
        name: domain.name,
        document_root: domain.document_root,
        include_files: domain_setting.include_files,
        include_mail: domain_setting.include_mail,
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

  @doc "Upserts the `s3_mode` override for a single domain (nil clears override)."
  def set_domain_s3_mode(domain_id, s3_mode) when s3_mode in ["archive", "stream", nil] do
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
  def set_subdomain_s3_mode(subdomain_id, s3_mode) when s3_mode in ["archive", "stream", nil] do
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
end
