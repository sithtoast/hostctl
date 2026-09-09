defmodule Hostctl.Isolation do
  @moduledoc """
  Account identity reservations and database migration preflight.

  These operations do not provision OS users, change files, or activate service
  isolation. A migration plan is an inventory, never authorization to chown paths.
  """
  import Ecto.Query

  alias Hostctl.Accounts.{Scope, User}
  alias Hostctl.Hosting.{CronJob, Domain, DomainS3Backend, FtpAccount, Subdomain, UploadJob}
  alias Hostctl.Isolation.{Plan, SystemIdentity}
  alias Hostctl.Repo

  @doc "Returns only the caller's account identity, including pending reservations."
  def get_identity(%Scope{user: %User{id: id}}) when is_integer(id) and id > 0 do
    Repo.get_by(SystemIdentity, user_id: id)
  end

  @doc """
  Reserves a stable name for the caller's hosting account, idempotently.

  Serializes concurrent reservations with the owner's database row lock. Panel
  users without hosting resources need no identity. The manager's identity is
  never substituted for the owner's. This writes a pending database record only.
  """
  def reserve_identity(%Scope{user: %User{id: id}}) when is_integer(id) and id > 0 do
    Repo.transaction(fn ->
      user =
        Repo.one(from u in User, where: u.id == ^id, lock: "FOR UPDATE", select: struct(u, [:id]))

      if is_nil(user), do: Repo.rollback(:account_not_found)

      case Repo.get_by(SystemIdentity, original_user_id: id) do
        %SystemIdentity{user_id: ^id} = identity ->
          identity

        %SystemIdentity{} ->
          Repo.rollback(:identity_retained)

        nil ->
          unless hosting_resources?(id), do: Repo.rollback(:no_hosting_resources)

          case Repo.insert(SystemIdentity.reservation_changeset(user)) do
            {:ok, identity} -> identity
            {:error, changeset} -> Repo.rollback(changeset)
          end
      end
    end)
  end

  @doc """
  Returns a credential-free database inventory and potential migration blockers.

  No identity is reserved by this read. Other owners' paths are inspected for
  conflicts but never included in the returned inventory or findings. Live
  filesystem, process, backup, and service checks remain mandatory.
  """
  def plan(%Scope{user: %User{id: id}} = scope) when is_integer(id) and id > 0 do
    if Repo.exists?(from u in User, where: u.id == ^id) do
      # Select inventory fields only: never load FTP hashes, S3 credentials,
      # upload metadata, or cron commands into the report.
      domains =
        Repo.all(
          from d in Domain,
            order_by: d.id,
            select: map(d, [:id, :user_id, :name, :document_root, :php_version, :status])
        )

      subdomains =
        Repo.all(
          from s in Subdomain,
            order_by: s.id,
            select: map(s, [:id, :domain_id, :name, :document_root])
        )

      ftp_accounts =
        Repo.all(
          from f in FtpAccount,
            order_by: f.id,
            select: map(f, [:id, :user_id, :username, :home_dir, :mounts, :status])
        )

      domain_ids = domains |> Enum.filter(&(&1.user_id == id)) |> Enum.map(& &1.id)

      backends =
        Repo.all(
          from b in DomainS3Backend,
            where: b.domain_id in ^domain_ids,
            order_by: b.id,
            select: map(b, [:id, :domain_id, :subdomain, :url_path, :enabled, :ftp_mount_enabled])
        )

      jobs =
        Repo.all(
          from j in UploadJob,
            where: j.domain_id in ^domain_ids or j.user_id == ^id,
            order_by: j.id,
            select: map(j, [:id, :domain_id, :status])
        )

      cron_jobs =
        Repo.all(
          from c in CronJob,
            where: c.domain_id in ^domain_ids,
            order_by: c.id,
            select: map(c, [:id, :domain_id, :enabled])
        )

      {:ok,
       Plan.build(id, get_identity(scope), %{
         domains: domains,
         subdomains: subdomains,
         ftp_accounts: ftp_accounts,
         s3_backends: backends,
         upload_jobs: jobs,
         cron_jobs: cron_jobs
       })}
    else
      {:error, :account_not_found}
    end
  end

  defp hosting_resources?(id) do
    Repo.exists?(from d in Domain, where: d.user_id == ^id) or
      Repo.exists?(from f in FtpAccount, where: f.user_id == ^id)
  end
end
