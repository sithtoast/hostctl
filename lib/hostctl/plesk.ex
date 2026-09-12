defmodule Hostctl.Plesk do
  @moduledoc """
  Context for managing Plesk migrations (saved discovery + restore state).
  """

  import Ecto.Query

  alias Hostctl.Accounts.Scope
  alias Hostctl.Plesk.Migration
  alias Hostctl.Repo

  def list_import_jobs(%Scope{user: %{role: "admin"}}, ids) do
    from(j in Hostctl.Hosting.UploadJob,
      join: d in assoc(j, :domain),
      where: j.id in ^ids and j.job_type == "plesk_import",
      order_by: [asc: j.id],
      select: %{
        id: j.id,
        status: j.status,
        total_files: j.total_files,
        uploaded_files: j.uploaded_files,
        failed_files: j.failed_files,
        current_file: j.current_file,
        error_message: j.error_message,
        s3_bucket: j.s3_bucket,
        s3_prefix: j.s3_prefix,
        domain: %{id: d.id, name: d.name}
      }
    )
    |> Repo.all()
  end

  def list_import_jobs(%Scope{}, _ids), do: []

  def list_migrations(%Scope{user: user}) do
    Migration
    |> where(user_id: ^user.id)
    |> order_by(desc: :updated_at)
    |> Repo.all()
  end

  def get_migration!(%Scope{user: user}, id) do
    Migration
    |> where(user_id: ^user.id)
    |> Repo.get!(id)
  end

  def create_migration(%Scope{user: user}, attrs) do
    %Migration{user_id: user.id}
    |> Migration.changeset(attrs)
    |> Repo.insert()
  end

  def update_migration(%Migration{} = migration, attrs) do
    migration
    |> Migration.changeset(attrs)
    |> Repo.update()
  end

  def delete_migration(%Migration{} = migration) do
    Repo.delete(migration)
  end
end
