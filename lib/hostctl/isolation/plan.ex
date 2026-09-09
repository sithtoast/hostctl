defmodule Hostctl.Isolation.Plan do
  @moduledoc false

  alias Hostctl.Isolation.SystemIdentity

  def build(user_id, identity, inventory) do
    paths = website_paths(inventory.domains, inventory.subdomains)
    {owned_paths, other_paths} = Enum.split_with(paths, &(&1.user_id == user_id))
    {ftp, other_ftp} = Enum.split_with(inventory.ftp_accounts, &(&1.user_id == user_id))
    ftp_paths = Enum.flat_map(ftp, &ftp_paths/1)
    foreign_paths = other_paths ++ Enum.flat_map(other_ftp, &ftp_paths/1)
    owned_domains = Enum.filter(inventory.domains, &(&1.user_id == user_id))
    owned_domain_ids = MapSet.new(owned_domains, & &1.id)

    findings =
      Enum.flat_map(owned_paths ++ ftp_paths, &path_findings/1) ++
        overlap_findings(owned_paths ++ ftp_paths, foreign_paths) ++
        Enum.flat_map(ftp, &ftp_findings(&1, owned_paths)) ++
        Enum.flat_map(inventory.s3_backends, fn backend ->
          if backend.ftp_mount_enabled do
            [finding(:review, :s3_mount_permissions, "s3_backend", backend.id)]
          else
            []
          end
        end) ++
        Enum.flat_map(inventory.upload_jobs, fn job ->
          if job.status in ["pending", "running", "paused"] do
            [finding(:blocker, :unfinished_upload, "upload_job", job.id)]
          else
            []
          end
        end) ++
        Enum.flat_map(inventory.cron_jobs, fn job ->
          if job.enabled,
            do: [finding(:review, :scheduled_job_identity, "cron_job", job.id)],
            else: []
        end)

    %{
      account_user_id: user_id,
      phase: "database_inventory",
      apply_supported: false,
      identity: identity_summary(identity, user_id),
      domains: Enum.map(owned_domains, &Map.delete(&1, :user_id)),
      subdomains:
        Enum.filter(inventory.subdomains, &MapSet.member?(owned_domain_ids, &1.domain_id)),
      ftp_accounts: Enum.map(ftp, &ftp_summary/1),
      s3_backends: inventory.s3_backends,
      upload_jobs: inventory.upload_jobs,
      cron_jobs: inventory.cron_jobs,
      php_versions: owned_domains |> Enum.map(& &1.php_version) |> Enum.uniq() |> Enum.sort(),
      findings: Enum.uniq(findings),
      required_live_checks: [
        "OS username/UID/GID collisions and locked-login policy",
        "Canonical paths, symlinks, hard links, ownership, modes, ACLs and mount boundaries",
        "Quiesce PHP, FTP, imports, restores and scheduled writers",
        "Snapshot and record rollback metadata before changing ownership",
        "Validate PHP pools, Nginx symlink policy, FTP mapping and S3 permissions",
        "Verify account access and cross-account denial using two Linux accounts"
      ]
    }
  end

  # Lexical checks only. Passing these checks never establishes filesystem safety.
  defp safe_path?(path) when is_binary(path) do
    Regex.match?(~r|\A/var/www/[A-Za-z0-9_.\-/]+\z|, path) and
      not Enum.any?(String.split(path, "/") |> Enum.drop(1), &(&1 in ["", ".", ".."]))
  end

  defp safe_path?(_), do: false

  defp within?(path, root) do
    safe_path?(path) and safe_path?(root) and
      (path == root or String.starts_with?(path, root <> "/"))
  end

  defp website_paths(domains, subdomains) do
    subdomains_by_domain = Enum.group_by(subdomains, & &1.domain_id)

    Enum.flat_map(domains, fn domain ->
      root = "/var/www/#{domain.name}"
      docroot = domain.document_root || "#{root}/httpdocs"

      [
        path_entry(domain.user_id, "domain", domain.id, root, root),
        path_entry(domain.user_id, "domain", domain.id, docroot, root)
      ] ++
        for sub <- Map.get(subdomains_by_domain, domain.id, []) do
          path_entry(
            domain.user_id,
            "subdomain",
            sub.id,
            sub.document_root || "#{root}/#{sub.name}.#{domain.name}",
            root
          )
        end
    end)
  end

  defp path_entry(user_id, type, id, path, root \\ nil) do
    %{user_id: user_id, type: type, id: id, path: path, root: root}
  end

  defp ftp_paths(account) do
    if account.mounts in [nil, []] do
      [path_entry(account.user_id, "ftp_account", account.id, account.home_dir)]
    else
      Enum.map(List.wrap(account.mounts), fn mount ->
        path = if is_map(mount), do: Map.get(mount, "path"), else: nil
        path_entry(account.user_id, "ftp_account", account.id, path)
      end)
    end
  end

  defp path_findings(entry) do
    cond do
      not safe_path?(entry.path) ->
        [finding(:blocker, :unsafe_or_unsupported_path, entry.type, entry.id)]

      entry.root && not within?(entry.path, entry.root) ->
        [finding(:review, :custom_document_root, entry.type, entry.id)]

      true ->
        []
    end
  end

  defp overlap_findings(owned, foreign) do
    unknown =
      if Enum.any?(foreign, &(not safe_path?(&1.path))) do
        [finding(:blocker, :unvalidated_foreign_paths, "account", nil)]
      else
        []
      end

    unknown ++
      Enum.flat_map(owned, fn entry ->
        if Enum.any?(foreign, fn other ->
             within?(entry.path, other.path) or within?(other.path, entry.path)
           end) do
          [finding(:blocker, :cross_account_path_overlap, entry.type, entry.id)]
        else
          []
        end
      end)
  end

  defp ftp_findings(account, owned_paths) do
    outside =
      Enum.any?(ftp_paths(account), fn entry ->
        not Enum.any?(owned_paths, &within?(entry.path, &1.path))
      end)

    mount_names =
      Enum.map(List.wrap(account.mounts), fn mount ->
        if is_map(mount), do: Map.get(mount, "name"), else: nil
      end)

    []
    |> add_if(outside, finding(:blocker, :ftp_path_not_owned, "ftp_account", account.id))
    |> add_if(
      not safe_component?(account.username),
      finding(:blocker, :unsafe_ftp_username, "ftp_account", account.id)
    )
    |> add_if(
      Enum.any?(mount_names, &(not safe_component?(&1))) or
        Enum.uniq(mount_names) != mount_names,
      finding(:blocker, :invalid_ftp_mount_names, "ftp_account", account.id)
    )
    |> add_if(
      account.mounts not in [nil, []],
      finding(:review, :ftp_bind_mounts, "ftp_account", account.id)
    )
  end

  defp safe_component?(value) when is_binary(value) do
    Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/, value)
  end

  defp safe_component?(_), do: false

  defp add_if(list, true, item), do: list ++ [item]
  defp add_if(list, false, _item), do: list

  defp identity_summary(nil, user_id) do
    %{username: SystemIdentity.username(user_id), state: "unreserved", uid: nil, gid: nil}
  end

  defp identity_summary(identity, _user_id) do
    identity
    |> Map.take([:username, :state, :uid, :gid])
    |> Map.update!(:state, &Atom.to_string/1)
  end

  defp ftp_summary(account) do
    account
    |> Map.take([:id, :username, :home_dir, :status])
    |> Map.put(
      :mounts,
      Enum.map(List.wrap(account.mounts), fn
        mount when is_map(mount) -> Map.take(mount, ["name", "path"])
        _ -> %{}
      end)
    )
  end

  defp finding(severity, code, resource_type, resource_id) do
    %{severity: severity, code: code, resource_type: resource_type, resource_id: resource_id}
  end
end
