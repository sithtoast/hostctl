defmodule Hostctl.Hosting do
  import Ecto.Query

  alias Hostctl.Repo
  alias Hostctl.Accounts.Scope

  alias Hostctl.Hosting.{
    Domain,
    Subdomain,
    DnsZone,
    DnsRecord,
    EmailAccount,
    Database,
    SslCertificate,
    CronJob,
    FtpAccount
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
        # Auto-create a DNS zone for every new domain
        %DnsZone{domain_id: domain.id}
        |> DnsZone.changeset(%{})
        |> Repo.insert()

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
  end

  def delete_domain(%Scope{} = scope, %Domain{} = domain) do
    true = domain.user_id == scope.user.id
    Repo.delete(domain)
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
  end

  def update_subdomain(%Subdomain{} = subdomain, attrs) do
    subdomain
    |> Subdomain.changeset(attrs)
    |> Repo.update()
  end

  def delete_subdomain(%Subdomain{} = subdomain) do
    Repo.delete(subdomain)
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

  def create_dns_record(%DnsZone{} = zone, attrs) do
    %DnsRecord{dns_zone_id: zone.id}
    |> DnsRecord.changeset(attrs)
    |> Repo.insert()
  end

  def update_dns_record(%DnsRecord{} = record, attrs) do
    record
    |> DnsRecord.changeset(attrs)
    |> Repo.update()
  end

  def delete_dns_record(%DnsRecord{} = record) do
    Repo.delete(record)
  end

  def change_dns_record(%DnsRecord{} = record, attrs \\ %{}) do
    DnsRecord.changeset(record, attrs)
  end

  # ---------------------------------------------------------------------------
  # Email Accounts
  # ---------------------------------------------------------------------------

  def list_email_accounts(%Domain{} = domain) do
    Repo.all(
      from e in EmailAccount, where: e.domain_id == ^domain.id, order_by: [asc: e.username]
    )
  end

  def create_email_account(%Domain{} = domain, attrs) do
    %EmailAccount{domain_id: domain.id}
    |> EmailAccount.changeset(attrs)
    |> Repo.insert()
  end

  def update_email_account(%EmailAccount{} = account, attrs) do
    account
    |> EmailAccount.changeset(attrs)
    |> Repo.update()
  end

  def delete_email_account(%EmailAccount{} = account) do
    Repo.delete(account)
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

  def create_ssl_certificate(%Domain{} = domain, attrs) do
    %SslCertificate{domain_id: domain.id}
    |> SslCertificate.changeset(attrs)
    |> Repo.insert()
  end

  def update_ssl_certificate(%SslCertificate{} = cert, attrs) do
    cert
    |> SslCertificate.changeset(attrs)
    |> Repo.update()
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
    %FtpAccount{domain_id: domain.id}
    |> FtpAccount.changeset(attrs)
    |> Repo.insert()
  end

  def update_ftp_account(%FtpAccount{} = account, attrs) do
    account
    |> FtpAccount.changeset(attrs)
    |> Repo.update()
  end

  def delete_ftp_account(%FtpAccount{} = account) do
    Repo.delete(account)
  end

  def change_ftp_account(%FtpAccount{} = account, attrs \\ %{}) do
    FtpAccount.changeset(account, attrs)
  end
end
