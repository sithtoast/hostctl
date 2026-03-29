defmodule Hostctl.Hosting do
  require Logger

  import Ecto.Query

  alias Hostctl.Repo
  alias Hostctl.Accounts.Scope
  alias Hostctl.Settings
  alias Hostctl.DNS.Cloudflare
  alias Hostctl.MailgunClient
  alias Hostctl.WebServer
  alias Hostctl.CertBot
  alias Hostctl.FtpServer
  alias Hostctl.MailServer

  alias Hostctl.Hosting.{
    Domain,
    Subdomain,
    DnsZone,
    DnsRecord,
    EmailAccount,
    Database,
    SslCertificate,
    CronJob,
    FtpAccount,
    DomainSmarthostSetting
  }

  # ---------------------------------------------------------------------------
  # Domains
  # ---------------------------------------------------------------------------

  def list_domains(%Scope{} = scope) do
    Repo.all(from d in Domain, where: d.user_id == ^scope.user.id, order_by: [asc: d.name])
  end

  def get_domain!(%Scope{} = scope, id) do
    Repo.get_by!(Domain, id: id, user_id: scope.user.id)
  end

  def get_domain_with_stats!(%Scope{} = scope, id) do
    domain = get_domain!(scope, id)

    email_count = Repo.aggregate(from(e in EmailAccount, where: e.domain_id == ^id), :count)
    db_count = Repo.aggregate(from(d in Database, where: d.domain_id == ^id), :count)
    subdomain_count = Repo.aggregate(from(s in Subdomain, where: s.domain_id == ^id), :count)

    %{domain | :__meta__ => domain.__meta__}
    |> Map.put(:email_count, email_count)
    |> Map.put(:db_count, db_count)
    |> Map.put(:subdomain_count, subdomain_count)
  end

  def create_domain(%Scope{} = scope, attrs) do
    %Domain{user_id: scope.user.id}
    |> Domain.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, domain} ->
        {:ok, zone} =
          %DnsZone{domain_id: domain.id}
          |> DnsZone.changeset(%{})
          |> Repo.insert()

        if domain.apply_dns_template do
          apply_dns_template(zone, domain.name)
        end

        WebServer.sync_domain(domain)

        {:ok, domain}

      error ->
        error
    end
  end

  def update_domain(%Scope{} = scope, %Domain{} = domain, attrs) do
    true = domain.user_id == scope.user.id

    domain
    |> Domain.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, updated_domain} = result ->
        WebServer.sync_domain(updated_domain)
        result

      error ->
        error
    end
  end

  def delete_domain(%Scope{} = scope, %Domain{} = domain) do
    true = domain.user_id == scope.user.id

    case Repo.delete(domain) do
      {:ok, _} = result ->
        WebServer.remove_domain(domain)
        result

      error ->
        error
    end
  end

  def change_domain(%Domain{} = domain, attrs \\ %{}) do
    Domain.changeset(domain, attrs)
  end

  def domain_stats(%Scope{} = scope) do
    user_id = scope.user.id

    total = Repo.aggregate(from(d in Domain, where: d.user_id == ^user_id), :count)

    active =
      Repo.aggregate(
        from(d in Domain, where: d.user_id == ^user_id and d.status == "active"),
        :count
      )

    ssl_enabled =
      Repo.aggregate(
        from(d in Domain, where: d.user_id == ^user_id and d.ssl_enabled == true),
        :count
      )

    %{total: total, active: active, ssl_enabled: ssl_enabled}
  end

  # ---------------------------------------------------------------------------
  # Subdomains
  # ---------------------------------------------------------------------------

  def list_subdomains(%Domain{} = domain) do
    Repo.all(from s in Subdomain, where: s.domain_id == ^domain.id, order_by: [asc: s.name])
  end

  def create_subdomain(%Domain{} = domain, attrs) do
    %Subdomain{domain_id: domain.id}
    |> Subdomain.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, _subdomain} = result ->
        WebServer.sync_domain(domain)
        result

      error ->
        error
    end
  end

  def update_subdomain(%Subdomain{} = subdomain, attrs) do
    subdomain
    |> Subdomain.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, _updated} = result ->
        domain = Repo.get!(Domain, subdomain.domain_id)
        WebServer.sync_domain(domain)
        result

      error ->
        error
    end
  end

  def delete_subdomain(%Subdomain{} = subdomain) do
    domain = Repo.get!(Domain, subdomain.domain_id)

    case Repo.delete(subdomain) do
      {:ok, _} = result ->
        WebServer.sync_domain(domain)
        result

      error ->
        error
    end
  end

  def change_subdomain(%Subdomain{} = subdomain, attrs \\ %{}) do
    Subdomain.changeset(subdomain, attrs)
  end

  # ---------------------------------------------------------------------------
  # DNS
  # ---------------------------------------------------------------------------

  def get_dns_zone_for_domain(%Domain{} = domain) do
    Repo.get_by(DnsZone, domain_id: domain.id)
  end

  def get_dns_zone_with_records!(%Domain{} = domain) do
    zone = Repo.get_by!(DnsZone, domain_id: domain.id)

    records =
      Repo.all(
        from r in DnsRecord,
          where: r.dns_zone_id == ^zone.id,
          order_by: [asc: r.type, asc: r.name]
      )

    %{zone | dns_records: records}
  end

  def update_dns_zone(%DnsZone{} = zone, attrs) do
    zone
    |> DnsZone.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Attempts to link a DNS zone to a Cloudflare zone by looking up the domain name.
  Requires Cloudflare to be configured in DNS provider settings.
  """
  def link_zone_to_cloudflare(%DnsZone{} = zone) do
    with %{provider: "cloudflare", cloudflare_api_token: token}
         when is_binary(token) and token != "" <-
           Settings.get_dns_provider_setting(),
         domain <- Repo.preload(zone, :domain).domain,
         {:ok, cloudflare_zone_id} <- Cloudflare.find_zone(token, domain.name),
         {:ok, linked_zone} <- update_dns_zone(zone, %{cloudflare_zone_id: cloudflare_zone_id}) do
      # Push all existing local records to Cloudflare (best-effort)
      records = Repo.all(from r in DnsRecord, where: r.dns_zone_id == ^linked_zone.id)

      Enum.each(records, fn record ->
        case Cloudflare.create_record(token, cloudflare_zone_id, record) do
          {:ok, cf_record_id} ->
            Repo.update(Ecto.Changeset.change(record, cloudflare_record_id: cf_record_id))
          {:error, reason} ->
            Logger.warning("[Cloudflare] Failed to push #{record.type} #{record.name}: #{reason}")
        end
      end)

      {:ok, linked_zone}
    else
      %{provider: "local"} -> {:error, :cloudflare_not_configured}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :cloudflare_not_configured}
    end
  end

  @doc """
  Pushes all local DNS records for the given zone to Cloudflare. Records that
  already have a `cloudflare_record_id` are updated; others are created and the
  ID is stored locally.

  Returns `{:ok, %{synced: n, failed: n}}` or `{:error, :not_linked | :cloudflare_not_configured}`.
  """
  def sync_zone_to_cloudflare(%DnsZone{cloudflare_zone_id: cf_zone_id} = zone)
      when is_binary(cf_zone_id) do
    with %{provider: "cloudflare", cloudflare_api_token: token}
         when is_binary(token) and token != "" <-
           Settings.get_dns_provider_setting() do
      records = Repo.all(from r in DnsRecord, where: r.dns_zone_id == ^zone.id)

      {synced, failed} =
        Enum.reduce(records, {0, 0}, fn record, {ok_count, err_count} ->
          result =
            if is_binary(record.cloudflare_record_id) do
              Cloudflare.update_record(token, cf_zone_id, record.cloudflare_record_id, record)
            else
              case Cloudflare.create_record(token, cf_zone_id, record) do
                {:ok, cf_id} ->
                  Repo.update(Ecto.Changeset.change(record, cloudflare_record_id: cf_id))
                  :ok

                {:error, _} = err ->
                  err
              end
            end

          case result do
            :ok -> {ok_count + 1, err_count}

            {:error, reason} ->
              Logger.warning(
                "[Cloudflare] Sync failed for #{record.name}: #{inspect(reason)}"
              )

              {ok_count, err_count + 1}
          end
        end)

      {:ok, %{synced: synced, failed: failed}}
    else
      _ -> {:error, :cloudflare_not_configured}
    end
  end

  def sync_zone_to_cloudflare(_zone), do: {:error, :not_linked}

  def create_dns_record(%DnsZone{} = zone, attrs) do
    result =
      %DnsRecord{dns_zone_id: zone.id}
      |> DnsRecord.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, record} ->
        record = maybe_sync_create_to_cloudflare(zone, record)
        {:ok, record}

      error ->
        error
    end
  end

  def update_dns_record(%DnsRecord{} = record, attrs) do
    result =
      record
      |> DnsRecord.changeset(attrs)
      |> Repo.update()

    case result do
      {:ok, updated_record} ->
        zone = Repo.get!(DnsZone, updated_record.dns_zone_id)
        updated_record = maybe_sync_update_to_cloudflare(zone, updated_record)
        {:ok, updated_record}

      error ->
        error
    end
  end

  def delete_dns_record(%DnsRecord{} = record) do
    maybe_sync_delete_to_cloudflare(record)
    Repo.delete(record)
  end

  def change_dns_record(%DnsRecord{} = record, attrs \\ %{}) do
    DnsRecord.changeset(record, attrs)
  end

  defp maybe_sync_create_to_cloudflare(%DnsZone{cloudflare_zone_id: cf_zone_id} = _zone, record)
       when is_binary(cf_zone_id) do
    with %{provider: "cloudflare", cloudflare_api_token: token}
         when is_binary(token) and token != "" <-
           Settings.get_dns_provider_setting(),
         {:ok, cf_record_id} <- Cloudflare.create_record(token, cf_zone_id, record),
         {:ok, updated} <-
           Repo.update(Ecto.Changeset.change(record, cloudflare_record_id: cf_record_id)) do
      updated
    else
      _ -> record
    end
  end

  defp maybe_sync_create_to_cloudflare(_zone, record), do: record

  defp maybe_sync_update_to_cloudflare(
         %DnsZone{cloudflare_zone_id: cf_zone_id},
         %DnsRecord{cloudflare_record_id: cf_record_id} = record
       )
       when is_binary(cf_zone_id) and is_binary(cf_record_id) do
    with %{provider: "cloudflare", cloudflare_api_token: token}
         when is_binary(token) and token != "" <-
           Settings.get_dns_provider_setting() do
      Cloudflare.update_record(token, cf_zone_id, cf_record_id, record)
    end

    record
  end

  defp maybe_sync_update_to_cloudflare(_zone, record), do: record

  defp maybe_sync_delete_to_cloudflare(%DnsRecord{
         cloudflare_record_id: cf_record_id,
         dns_zone_id: zone_id
       })
       when is_binary(cf_record_id) do
    with %{provider: "cloudflare", cloudflare_api_token: token}
         when is_binary(token) and token != "" <-
           Settings.get_dns_provider_setting(),
         %DnsZone{cloudflare_zone_id: cf_zone_id} when is_binary(cf_zone_id) <-
           Repo.get!(DnsZone, zone_id) do
      Cloudflare.delete_record(token, cf_zone_id, cf_record_id)
    end

    :ok
  end

  defp maybe_sync_delete_to_cloudflare(_record), do: :ok

  defp apply_dns_template(%DnsZone{} = zone, domain_name) do
    Settings.resolve_dns_template(domain_name)
    |> Enum.each(fn attrs ->
      %DnsRecord{dns_zone_id: zone.id}
      |> DnsRecord.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, record} -> maybe_sync_create_to_cloudflare(zone, record)
        _ -> :ok
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Email Accounts
  # ---------------------------------------------------------------------------

  def list_email_accounts(%Domain{} = domain) do
    Repo.all(
      from e in EmailAccount, where: e.domain_id == ^domain.id, order_by: [asc: e.username]
    )
  end

  def list_all_email_accounts_with_domains do
    Repo.all(
      from ea in EmailAccount,
        join: d in Domain, on: ea.domain_id == d.id,
        select: {ea.username, d.name, ea.hashed_password}
    )
  end

  def create_email_account(%Domain{} = domain, attrs) do
    result =
      %EmailAccount{domain_id: domain.id}
      |> EmailAccount.changeset(attrs)
      |> Repo.insert()

    if match?({:ok, _}, result) do
      MailServer.sync_dovecot_passwd()
      MailServer.sync_virtual_mailboxes()
    end

    result
  end

  def update_email_account(%EmailAccount{} = account, attrs) do
    result =
      account
      |> EmailAccount.changeset(attrs)
      |> Repo.update()

    if match?({:ok, _}, result), do: MailServer.sync_dovecot_passwd()
    result
  end

  def delete_email_account(%EmailAccount{} = account) do
    result = Repo.delete(account)

    if match?({:ok, _}, result) do
      MailServer.sync_dovecot_passwd()
      MailServer.sync_virtual_mailboxes()
    end

    result
  end

  def change_email_account(%EmailAccount{} = account, attrs \\ %{}) do
    EmailAccount.changeset(account, attrs)
  end

  # ---------------------------------------------------------------------------
  # Databases
  # ---------------------------------------------------------------------------

  def list_databases(%Domain{} = domain) do
    Repo.all(from d in Database, where: d.domain_id == ^domain.id, order_by: [asc: d.name])
  end

  def create_database(%Domain{} = domain, attrs) do
    %Database{domain_id: domain.id}
    |> Database.changeset(attrs)
    |> Repo.insert()
  end

  def update_database(%Database{} = database, attrs) do
    database
    |> Database.changeset(attrs)
    |> Repo.update()
  end

  def delete_database(%Database{} = database) do
    Repo.delete(database)
  end

  def change_database(%Database{} = database, attrs \\ %{}) do
    Database.changeset(database, attrs)
  end

  # ---------------------------------------------------------------------------
  # SSL Certificates
  # ---------------------------------------------------------------------------

  def get_ssl_certificate(%Domain{} = domain) do
    Repo.get_by(SslCertificate, domain_id: domain.id)
  end

  def change_ssl_certificate(%SslCertificate{} = cert, attrs \\ %{}) do
    SslCertificate.changeset(cert, attrs)
  end

  def create_ssl_certificate(%Domain{} = domain, attrs) do
    %SslCertificate{domain_id: domain.id}
    |> SslCertificate.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, cert} = result ->
        domain = Repo.get!(Domain, domain.id)
        WebServer.sync_domain(domain)

        if cert.cert_type == "lets_encrypt" do
          Task.Supervisor.start_child(Hostctl.TaskSupervisor, fn ->
            provision_lets_encrypt_cert(domain, cert)
          end)
        end

        result

      error ->
        error
    end
  end

  def update_ssl_certificate(%SslCertificate{} = cert, attrs) do
    cert
    |> SslCertificate.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, updated_cert} = result ->
        domain = Repo.get!(Domain, cert.domain_id)
        WebServer.sync_domain(domain)

        Phoenix.PubSub.broadcast(
          Hostctl.PubSub,
          "domain:#{cert.domain_id}:ssl",
          {:ssl_cert_updated, updated_cert}
        )

        result

      error ->
        error
    end
  end

  defp provision_lets_encrypt_cert(%Domain{} = domain, %SslCertificate{} = cert) do
    case CertBot.provision(domain, cert) do
      {:ok, expires_at, log} ->
        # Auto-enable SSL on the domain so nginx writes the 443 block.
        unless domain.ssl_enabled do
          domain
          |> Domain.changeset(%{ssl_enabled: true})
          |> Repo.update()
          |> case do
            {:ok, _} ->
              Logger.info("[Hosting] ssl_enabled set to true for #{domain.name}")

            {:error, r} ->
              Logger.error(
                "[Hosting] Could not set ssl_enabled for #{domain.name}: #{inspect(r)}"
              )
          end
        end

        case update_ssl_certificate(cert, %{status: "active", expires_at: expires_at, log: log}) do
          {:ok, _} ->
            Logger.info("[Hosting] SSL certificate activated for #{domain.name}")

          {:error, reason} ->
            Logger.error(
              "[Hosting] Failed to mark SSL cert active for #{domain.name}: #{inspect(reason)}"
            )
        end

      {:error, :disabled, _log} ->
        :ok

      {:error, _reason, log} ->
        update_ssl_certificate(cert, %{status: "pending", log: log})
        Logger.error("[Hosting] SSL provisioning failed for #{domain.name}")
    end
  end

  # ---------------------------------------------------------------------------
  # Cron Jobs
  # ---------------------------------------------------------------------------

  def list_cron_jobs(%Domain{} = domain) do
    Repo.all(from c in CronJob, where: c.domain_id == ^domain.id, order_by: [asc: c.inserted_at])
  end

  def create_cron_job(%Domain{} = domain, attrs) do
    %CronJob{domain_id: domain.id}
    |> CronJob.changeset(attrs)
    |> Repo.insert()
  end

  def update_cron_job(%CronJob{} = cron_job, attrs) do
    cron_job
    |> CronJob.changeset(attrs)
    |> Repo.update()
  end

  def delete_cron_job(%CronJob{} = cron_job) do
    Repo.delete(cron_job)
  end

  def change_cron_job(%CronJob{} = cron_job, attrs \\ %{}) do
    CronJob.changeset(cron_job, attrs)
  end

  # ---------------------------------------------------------------------------
  # FTP Accounts
  # ---------------------------------------------------------------------------

  def list_ftp_accounts(%Domain{} = domain) do
    Repo.all(from f in FtpAccount, where: f.domain_id == ^domain.id, order_by: [asc: f.username])
  end

  def create_ftp_account(%Domain{} = domain, attrs) do
    result =
      %FtpAccount{domain_id: domain.id}
      |> FtpAccount.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, account} ->
        raw_password = attrs["password"] || attrs[:password]
        FtpServer.provision_account(account, raw_password)
        {:ok, account}

      error ->
        error
    end
  end

  def update_ftp_account(%FtpAccount{} = account, attrs) do
    result =
      account
      |> FtpAccount.update_changeset(attrs)
      |> Repo.update()

    case result do
      {:ok, updated} ->
        raw_password = attrs["password"] || attrs[:password]
        FtpServer.provision_account(updated, raw_password)
        {:ok, updated}

      error ->
        error
    end
  end

  def delete_ftp_account(%FtpAccount{} = account) do
    case Repo.delete(account) do
      {:ok, deleted} ->
        FtpServer.remove_account(deleted)
        {:ok, deleted}

      error ->
        error
    end
  end

  def change_ftp_account(%FtpAccount{} = account, attrs \\ %{}) do
    FtpAccount.changeset(account, attrs)
  end

  def change_ftp_account_for_update(%FtpAccount{} = account, attrs \\ %{}) do
    FtpAccount.update_changeset(account, attrs)
  end

  # ---------------------------------------------------------------------------
  # Domain Smarthost Settings
  # ---------------------------------------------------------------------------

  @doc """
  Returns the smarthost setting for a domain, or a new unsaved struct if none exists.
  """
  def get_domain_smarthost_setting(%Domain{} = domain) do
    Repo.get_by(DomainSmarthostSetting, domain_id: domain.id) ||
      %DomainSmarthostSetting{domain_id: domain.id}
  end

  @doc """
  Upserts the smarthost setting for a domain.
  """
  def save_domain_smarthost_setting(%Domain{} = domain, attrs) do
    case get_domain_smarthost_setting(domain) do
      %DomainSmarthostSetting{id: nil} = new ->
        new
        |> DomainSmarthostSetting.changeset(attrs)
        |> Repo.insert()

      existing ->
        existing
        |> DomainSmarthostSetting.changeset(attrs)
        |> Repo.update()
    end
  end

  @doc "Returns a changeset for a domain smarthost setting."
  def change_domain_smarthost_setting(%DomainSmarthostSetting{} = setting, attrs \\ %{}) do
    DomainSmarthostSetting.changeset(setting, attrs)
  end

  @doc """
  Returns all domain smarthost settings that are enabled, with domain preloaded.
  Used by MailServer when rebuilding the full relay map.
  """
  def list_enabled_domain_smarthost_settings do
    Repo.all(
      from s in DomainSmarthostSetting,
        where: s.enabled == true,
        preload: [:domain]
    )
  end

  # ---------------------------------------------------------------------------
  # Mailgun provisioning
  # ---------------------------------------------------------------------------

  @doc """
  Provisions Mailgun for a domain in three steps:

  1. Fetches the existing Mailgun domain (or creates it if absent).
  2. Syncs all sending/receiving DNS records to Cloudflare (best-effort, skipped
     when Cloudflare is not configured or the zone cannot be found).
  3. Creates (or updates) a `hostctl` SMTP credential on that domain.

  Returns `{:ok, %{login: login, password: password}}` or `{:error, reason}`.
  """
  def provision_mailgun_for_domain(domain_name, api_key, region \\ :us) do
    Logger.info("[Mailgun] Provisioning #{domain_name} (region: #{region})")

    with {:ok, domain_info} <- get_or_create_mailgun_domain(api_key, domain_name, region) do
      # Fetch Mailgun DMARC records separately (different API endpoint)
      dmarc_records =
        case MailgunClient.get_dmarc_records(api_key, domain_name, region) do
          {:ok, records} -> records
          _ -> []
        end

      sync_mailgun_dns_to_cloudflare(domain_name, domain_info, dmarc_records)
      ensure_dmarc_record(domain_name, dmarc_records)
      MailgunClient.create_smtp_credential(api_key, domain_name, region)
    end
  end

  defp get_or_create_mailgun_domain(api_key, domain_name, region) do
    case MailgunClient.get_domain(api_key, domain_name, region) do
      {:ok, _} = ok ->
        Logger.info("[Mailgun] Domain #{domain_name} already exists")
        ok

      {:error, "HTTP 404"} ->
        Logger.info("[Mailgun] Domain #{domain_name} not found, creating...")
        MailgunClient.create_domain(api_key, domain_name, region)

      {:error, reason} = error ->
        Logger.warning("[Mailgun] get_domain failed: #{reason}")
        error
    end
  end

  defp sync_mailgun_dns_to_cloudflare(domain_name, %{
         sending_dns_records: sending
       }, dmarc_records) do
    # Only use sending records (SPF, DKIM) — never receiving_dns_records,
    # which are Mailgun's own inbound MX servers, not ours.
    mg_sending_records =
      Enum.map(sending, fn mg_record ->
        %{
          type: mg_record["record_type"],
          name: mg_record["name"] || "@",
          value: mg_record["value"],
          priority: mg_record["priority"],
          ttl: 3600
        }
      end)

    # Merge in DMARC records fetched from the separate Mailgun endpoint
    cf_records = mg_sending_records ++ dmarc_records

    # Sync to local hostctl DNS zone (best-effort)
    sync_mailgun_dns_to_local_zone(domain_name, cf_records)

    case Settings.get_dns_provider_setting() do
      %{provider: "cloudflare", cloudflare_api_token: token}
      when is_binary(token) and token != "" ->
        case Cloudflare.find_zone(token, domain_name) do
          {:ok, zone_id} ->
            Logger.info(
              "[Mailgun] Syncing #{length(cf_records)} DNS records to Cloudflare zone #{zone_id}"
            )

            # Fetch existing records so we can replace conflicting TXT/MX entries
            existing =
              case Cloudflare.list_records(token, zone_id) do
                {:ok, records} -> records
                _ -> []
              end

            # Delete any existing TXT or MX record whose name matches a Mailgun record we're about to set
            mg_names = MapSet.new(cf_records, & &1.name)
            mg_types = MapSet.new(cf_records, & &1.type)

            Enum.each(existing, fn ex ->
              ex_name = ex["name"]
              # Cloudflare returns FQDNs; normalise by stripping trailing dot
              normalised_name = String.trim_trailing(ex_name, ".")
              ex_type = ex["type"]

              if MapSet.member?(mg_types, ex_type) and
                   (MapSet.member?(mg_names, normalised_name) or
                      MapSet.member?(mg_names, ex_name)) do
                Logger.info("[Mailgun] Replacing existing #{ex_type} record: #{ex_name}")
                Cloudflare.delete_record(token, zone_id, ex["id"])
              end
            end)

            # Create the Mailgun records
            Enum.each(cf_records, fn record ->
              case Cloudflare.create_record(token, zone_id, record) do
                {:ok, _} -> :ok
                {:error, reason} ->
                  Logger.warning("[Mailgun] DNS sync failed for #{record.name}: #{reason}")
              end
            end)

          {:error, reason} ->
            Logger.info(
              "[Mailgun] Cloudflare zone not found for #{domain_name}: #{reason}, skipping DNS sync"
            )
        end

      _ ->
        Logger.info("[Mailgun] Cloudflare not configured, skipping DNS sync")
    end

    :ok
  end

  # Ensures a _dmarc TXT record exists for the domain. Called after Mailgun
  # provisioning as a fallback — Mailgun's DMARC API often returns nothing.
  # Upserts the _dmarc TXT record using Mailgun-provided records when available,
  # falling back to a sensible default. Always upserts so re-provisioning updates
  # any stale value.
  defp ensure_dmarc_record(domain_name, mailgun_dmarc_records) do
    with %Domain{} = domain <- Repo.get_by(Domain, name: domain_name),
         %DnsZone{} = zone <- Repo.get_by(DnsZone, domain_id: domain.id) do
      dmarc_name = "_dmarc.#{domain_name}"

      # Prefer the record Mailgun provides; fall back to a sensible default
      dmarc_value =
        case Enum.find(mailgun_dmarc_records, fn r ->
               r.name == dmarc_name or r.name == "_dmarc" or
                 String.starts_with?(to_string(r.name), "_dmarc")
             end) do
          %{value: v} when is_binary(v) and v != "" ->
            v

          _ ->
            "v=DMARC1; p=none; pct=100; fo=1; ri=3600; rua=mailto:postmaster@#{domain_name}"
        end

      attrs = %{type: "TXT", name: dmarc_name, value: dmarc_value, ttl: 300}

      # Delete any existing _dmarc record (plain Repo.delete_all so Cloudflare
      # sync doesn't fire twice — we'll push the new record right after)
      existing = Repo.get_by(DnsRecord, dns_zone_id: zone.id, type: "TXT", name: dmarc_name)

      if existing do
        maybe_sync_delete_to_cloudflare(existing)
        Repo.delete(existing)
      end

      %DnsRecord{dns_zone_id: zone.id}
      |> DnsRecord.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, record} ->
          Logger.info("[DMARC] Upserted #{dmarc_name} = #{dmarc_value}")
          maybe_sync_create_to_cloudflare(zone, record)

        {:error, changeset} ->
          Logger.warning("[DMARC] Failed to upsert record: #{inspect(changeset.errors)}")
      end
    end

    :ok
  end

  defp sync_mailgun_dns_to_local_zone(domain_name, mg_records) do
    with %Domain{} = domain <- Repo.get_by(Domain, name: domain_name),
         %DnsZone{} = zone <- Repo.get_by(DnsZone, domain_id: domain.id) do
      mg_types = Enum.map(mg_records, & &1.type) |> MapSet.new()
      mg_names = Enum.map(mg_records, & &1.name) |> MapSet.new()

      # Remove existing local records that conflict with what Mailgun provides
      existing =
        Repo.all(from r in DnsRecord, where: r.dns_zone_id == ^zone.id)

      Enum.each(existing, fn record ->
        if MapSet.member?(mg_types, record.type) and MapSet.member?(mg_names, record.name) do
          maybe_sync_delete_to_cloudflare(record)
          Repo.delete(record)
        end
      end)

      # Insert the new Mailgun records
      Enum.each(mg_records, fn attrs ->
        %DnsRecord{dns_zone_id: zone.id}
        |> DnsRecord.changeset(attrs)
        |> Repo.insert()
        |> case do
          {:ok, record} -> maybe_sync_create_to_cloudflare(zone, record)
          _ -> :ok
        end
      end)
    else
      _ ->
        Logger.info("[Mailgun] Local DNS zone not found for #{domain_name}, skipping local sync")
    end
  end
end
