defmodule Hostctl.Isolation.Runtime do
  @moduledoc """
  Service integration for explicitly enrolled accounts.

  Pending reservations retain legacy behavior. Once enrollment starts, errors
  never select the shared runtime. Existing-account conversion is a separate
  migration; initial enrollment is restricted to owners without hosting resources.
  """
  import Ecto.Query
  alias Hostctl.Accounts.{Scope, User}
  alias Hostctl.Hosting.{Domain, FtpAccount, Subdomain, DomainS3Backend}
  alias Hostctl.Isolation.SystemIdentity
  alias Hostctl.Repo

  def provision_identity(%Scope{user: %User{id: id}}) do
    Repo.transaction(fn ->
      user =
        Repo.one(from u in User, where: u.id == ^id, lock: "FOR UPDATE", select: struct(u, [:id]))

      if user do
        identity = Repo.get_by(SystemIdentity, original_user_id: id)

        cond do
          identity && identity.user_id != id -> {:error, :identity_retained}
          identity && identity.state == :ready -> verify_identity(identity)
          resources?(id) -> {:error, :existing_account_requires_migration}
          true -> enroll(user, identity)
        end
      else
        {:error, :account_not_found}
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp enroll(user, identity) do
    identity = identity || Repo.insert!(SystemIdentity.reservation_changeset(user))
    identity = Repo.update!(Ecto.Changeset.change(identity, state: :provisioning))

    case helper("enroll", %{owner_id: user.id, username: identity.username}) do
      {:ok, %{"username" => name, "uid" => uid, "gid" => gid}}
      when name == identity.username and is_integer(uid) and uid > 0 and uid < 4_294_967_295 and
             is_integer(gid) and gid > 0 and gid < 4_294_967_295 ->
        changeset =
          identity
          |> Ecto.Changeset.change(uid: uid, gid: gid, state: :ready)
          |> Ecto.Changeset.unique_constraint(:uid)
          |> Ecto.Changeset.unique_constraint(:gid)

        case Repo.update(changeset, mode: :savepoint) do
          {:ok, ready} -> {:ok, ready}
          {:error, _} -> fail(identity, :numeric_identity_conflict)
        end

      {:error, reason} ->
        fail(identity, reason)

      _ ->
        fail(identity, :invalid_helper_response)
    end
  end

  defp fail(identity, reason) do
    Repo.update!(Ecto.Changeset.change(identity, state: :failed))
    {:error, reason}
  end

  def identity(user_id) do
    case Repo.get_by(SystemIdentity, user_id: user_id) do
      nil -> {:ok, nil}
      %SystemIdentity{state: :pending} -> {:ok, nil}
      %SystemIdentity{state: :ready} = identity -> {:ok, identity}
      _ -> {:error, :account_isolation_not_ready}
    end
  end

  defp verify_identity(identity) do
    with {:ok, %{"uid" => uid, "gid" => gid, "username" => name}} <-
           helper("verify", payload(identity)),
         true <- {uid, gid, name} == {identity.uid, identity.gid, identity.username} do
      {:ok, identity}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :identity_verification_failed}
    end
  end

  def prepare_domain(%Domain{} = domain) do
    with {:ok, identity} <- identity(domain.user_id) do
      roots = domain_roots(domain)

      if identity do
        mounted? =
          Repo.exists?(
            from b in DomainS3Backend,
              where: b.domain_id == ^domain.id and b.ftp_mount_enabled == true
          )

        with false <- mounted?,
             true <- Enum.all?(roots, &canonical_root?(&1, domain)),
             {:ok, _} <- verify_identity(identity),
             :ok <- prepare_roots(identity, domain, roots),
             {:ok, %{"socket" => socket}} <-
               helper("php", Map.put(payload(identity), :version, domain.php_version)) do
          if socket == php_socket(identity, domain.php_version) do
            {:ok, [isolated: true, php_socket: socket]}
          else
            {:error, :invalid_php_socket}
          end
        else
          {:error, reason} -> {:error, reason}
          _ -> {:error, :unsupported_isolated_webroot_or_mount}
        end
      else
        if Enum.any?(roots, &protected_path?/1), do: {:error, :isolated_path}, else: {:ok, []}
      end
    end
  end

  defp domain_roots(domain) do
    subroots =
      Repo.all(from s in Subdomain, where: s.domain_id == ^domain.id)
      |> Enum.map(fn sub ->
        sub.document_root || root(domain) <> "/#{sub.name}.#{domain.name}"
      end)

    [domain.document_root || root(domain) <> "/httpdocs" | subroots]
  end

  defp prepare_roots(identity, domain, roots) do
    Enum.reduce_while(roots, :ok, fn path, :ok ->
      case helper("webroot", Map.merge(payload(identity), %{domain: domain.name, path: path})) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def ftp_identity(%FtpAccount{} = account) do
    with {:ok, identity} <- identity(account.user_id) do
      cond do
        is_nil(identity) ->
          paths =
            if account.mounts in [nil, []],
              do: [account.home_dir],
              else: Enum.map(account.mounts, & &1["path"])

          if Enum.any?(paths, &protected_path?/1), do: {:error, :isolated_path}, else: {:ok, nil}

        account.mounts not in [nil, []] ->
          {:error, :isolated_bind_mounts_require_migration}

        not owned_ftp_path?(account) ->
          {:error, :ftp_path_not_owned}

        true ->
          domain = ftp_domain(account)

          with {:ok, _} <- verify_identity(identity),
               {:ok, _} <-
                 helper(
                   "ftp-home",
                   Map.merge(payload(identity), %{domain: domain.name, path: account.home_dir})
                 ) do
            {:ok, identity}
          end
      end
    end
  end

  defp owned_ftp_path?(account) do
    not is_nil(ftp_domain(account))
  end

  defp ftp_domain(account) do
    Repo.all(from d in Domain, where: d.user_id == ^account.user_id)
    |> Enum.find(fn domain ->
      account.home_dir == root(domain) or canonical_root?(account.home_dir, domain)
    end)
  end

  def protected_path?(path) when is_binary(path) do
    expanded = Path.expand(path)

    Repo.all(
      from d in Domain,
        join: i in SystemIdentity,
        on: i.user_id == d.user_id,
        where: i.state != :pending,
        select: d.name
    )
    |> Enum.any?(fn name ->
      boundary = "/var/www/#{name}"

      expanded == boundary or String.starts_with?(expanded, boundary <> "/") or
        String.starts_with?(boundary, String.trim_trailing(expanded, "/") <> "/")
    end)
  end

  def protected_path?(_), do: false

  def legacy_write_allowed(path) do
    if protected_path?(path),
      do: {:error, "This account requires an isolation-aware import or restore."},
      else: :ok
  end

  @doc "Resolves and verifies an import destination without permitting legacy fallback."
  def import_destination(path) do
    if is_binary(path) and Path.expand(path) == path do
      resolve_import_destination(path)
    else
      {:error, :invalid_import_path}
    end
  end

  defp resolve_import_destination(path) do
    domain = Repo.all(Domain) |> Enum.find(&canonical_root?(path, &1))

    if domain do
      with {:ok, identity} <- identity(domain.user_id) do
        if identity do
          with {:ok, _} <- verify_identity(identity),
               {:ok, _} <-
                 helper(
                   "webroot",
                   Map.merge(payload(identity), %{domain: domain.name, path: path, index: false})
                 ) do
            {:ok, Map.merge(payload(identity), %{domain: domain.name, path: path})}
          end
        else
          with :ok <- legacy_write_allowed(path), do: {:ok, nil}
        end
      end
    else
      with :ok <- legacy_write_allowed(path), do: {:ok, nil}
    end
  end

  def import_tree(destination, source) do
    case helper("import-tree", Map.put(destination, :source, source)) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        {:error, "Isolated file import failed; check source files and destination ownership."}
    end
  end

  def enrolled? do
    Repo.exists?(from i in SystemIdentity, where: i.state != :pending)
  end

  def legacy_chown(path) do
    with :ok <- legacy_write_allowed(path),
         {:ok, _} <- helper("legacy-chown", %{path: path}) do
      :ok
    end
  end

  def canonical_root?(path, domain) when is_binary(path) do
    String.starts_with?(path, root(domain) <> "/") and
      Regex.match?(~r|\A/var/www/[A-Za-z0-9_./-]+\z|, path) and
      not Enum.any?(String.split(path, "/") |> Enum.drop(1), &(&1 in ["", ".", ".."]))
  end

  def canonical_root?(_, _), do: false
  def root(domain), do: "/var/www/#{domain.name}"
  def php_socket(identity, version), do: "/run/php/hostctl-#{identity.username}-#{version}.sock"

  defp payload(identity),
    do: %{
      owner_id: identity.original_user_id,
      username: identity.username,
      uid: identity.uid,
      gid: identity.gid
    }

  defp resources?(id),
    do:
      Repo.exists?(from d in Domain, where: d.user_id == ^id) or
        Repo.exists?(from f in FtpAccount, where: f.user_id == ^id)

  defp helper(operation, payload),
    do:
      Application.get_env(:hostctl, :isolation_adapter, Hostctl.Isolation.Linux).call(
        operation,
        payload
      )
end
