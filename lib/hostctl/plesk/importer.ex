defmodule Hostctl.Plesk.Importer do
  @moduledoc """
  Imports domain inventory from Plesk backups or the Plesk REST API.

  This module is intentionally conservative:
  - It only creates missing domains in Hostctl.
  - It never updates or deletes existing Hostctl domains.
  - It supports dry-run previews before writing anything.
  """

  require Logger

  alias Hostctl.Accounts.Scope
  alias Hostctl.Hosting

  import Ecto.Query

  @domain_info_regex ~r/<domain-info[^>]*\sname="([^"]+)"/

  @doc """
  Extracts domain names from an extracted Plesk backup folder.

  Preferred source is `.discovered/*/object_index` because it is compact and fast.
  Falls back to scanning the root `backup_info_*.xml` file.
  """
  def backup_domain_names(backup_path) when is_binary(backup_path) do
    with {:ok, subscriptions} <- backup_subscriptions(backup_path) do
      {:ok, subscriptions |> Enum.map(& &1.domain) |> Enum.uniq() |> Enum.sort()}
    end
  end

  @doc """
  Extracts domain subscriptions from an extracted Plesk backup folder.

  Returns a list of maps:

      %{domain: "example.com", owner_login: "admin", owner_type: "admin", system_user: "example"}

  If only XML fallback data is available, owner/system fields are nil.
  """
  def backup_subscriptions(backup_path) when is_binary(backup_path) do
    with :ok <- ensure_directory(backup_path) do
      object_index_subscriptions =
        backup_path
        |> object_index_paths()
        |> Enum.flat_map(fn path ->
          case File.read(path) do
            {:ok, content} -> subscriptions_from_object_index_content(content)
            _ -> []
          end
        end)

      if object_index_subscriptions != [] do
        {:ok,
         object_index_subscriptions
         |> Enum.uniq_by(& &1.domain)
         |> Enum.sort_by(& &1.domain)}
      else
        from_root_backup_info_xml_subscriptions(backup_path)
      end
    end
  end

  @doc """
  Extracts domain names from Plesk API response at `/api/v2/domains`.
  """
  def api_domain_names(api_url, auth_opts \\ []) when is_binary(api_url) and is_list(auth_opts) do
    url = normalize_api_url(api_url)

    headers =
      [{"accept", "application/json"}]
      |> Kernel.++(auth_headers(auth_opts))

    case Req.get(url: url <> "/api/v2/domains", headers: headers) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        names = domain_names_from_api_response(body)

        if names == [] do
          {:error, "No domain names were found in Plesk API response."}
        else
          {:ok, names}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "Plesk API request failed with HTTP #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Plesk API request failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Imports domains from an extracted Plesk backup into a Hostctl user scope.

  Options:
    - `:dry_run` (default: true)
    - `:apply_dns_template` (default: false)
  """
  def import_from_backup(%Scope{} = scope, backup_path, opts \\ []) do
    with {:ok, domain_names} <- backup_domain_names(backup_path) do
      import_domains(scope, domain_names, opts)
    end
  end

  @doc """
  Imports domains discovered from Plesk API into a Hostctl user scope.

  Options:
    - `:dry_run` (default: true)
    - `:apply_dns_template` (default: false)
  """
  def import_from_api(%Scope{} = scope, api_url, auth_opts, opts \\ [])
      when is_binary(api_url) and is_list(auth_opts) and is_list(opts) do
    with {:ok, domain_names} <- api_domain_names(api_url, auth_opts) do
      import_domains(scope, domain_names, opts)
    end
  end

  @doc """
  Imports a set of domain names into a Hostctl scope.
  """
  def import_domains(%Scope{} = scope, domain_names, opts \\ []) when is_list(domain_names) do
    dry_run = Keyword.get(opts, :dry_run, true)
    apply_dns_template = Keyword.get(opts, :apply_dns_template, false)

    normalized_names =
      domain_names
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.sort()

    existing_names =
      scope
      |> Hosting.list_domains()
      |> Enum.map(& &1.name)
      |> MapSet.new()

    initial = %{created: [], planned: [], skipped_existing: [], failed: []}

    result =
      Enum.reduce(normalized_names, initial, fn name, acc ->
        cond do
          MapSet.member?(existing_names, name) ->
            %{acc | skipped_existing: [name | acc.skipped_existing]}

          dry_run ->
            %{acc | planned: [name | acc.planned]}

          true ->
            attrs = %{name: name, apply_dns_template: apply_dns_template}

            case Hosting.create_domain(scope, attrs) do
              {:ok, _domain} ->
                %{acc | created: [name | acc.created]}

              {:error, changeset} ->
                message = changeset_error_summary(changeset)
                %{acc | failed: ["#{name}: #{message}" | acc.failed]}
            end
        end
      end)

    {:ok,
     %{
       dry_run: dry_run,
       total_input: length(normalized_names),
       planned_count: length(result.planned),
       created_count: length(result.created),
       skipped_existing_count: length(result.skipped_existing),
       failed_count: length(result.failed),
       planned: Enum.reverse(result.planned),
       created: Enum.reverse(result.created),
       skipped_existing: Enum.reverse(result.skipped_existing),
       failed: Enum.reverse(result.failed)
     }}
  end

  @doc """
  Imports domains and subdomains from subscriptions with merged subdomain data.

  This function creates parent domains first, then creates subdomains under them.
  Subscriptions should already have subdomains merged via `SSHProbe.merge_subdomains/1`.

  Options:
    - `:dry_run` (default: true)
    - `:apply_dns_template` (default: false)
  """
  def import_subscriptions(%Scope{} = scope, subscriptions, opts \\ [])
      when is_list(subscriptions) do
    dry_run = Keyword.get(opts, :dry_run, true)

    # Import parent domains
    domain_names = Enum.map(subscriptions, & &1.domain)
    {:ok, domain_result} = import_domains(scope, domain_names, opts)

    # Collect all subdomains with their parent domain reference
    all_subdomains =
      Enum.flat_map(subscriptions, fn sub ->
        sub
        |> Map.get(:subdomains, [])
        |> Enum.map(&Map.put(&1, :parent_domain, sub.domain))
      end)

    subdomain_result =
      if dry_run do
        %{
          planned: Enum.map(all_subdomains, & &1.full_name),
          planned_count: length(all_subdomains),
          created: [],
          created_count: 0,
          skipped: [],
          skipped_count: 0,
          failed: [],
          failed_count: 0
        }
      else
        do_import_subdomains(scope, all_subdomains)
      end

    {:ok, Map.put(domain_result, :subdomain_result, subdomain_result)}
  end

  defp do_import_subdomains(scope, subdomains) do
    initial = %{created: [], skipped: [], failed: []}

    result =
      Enum.reduce(subdomains, initial, fn sub, acc ->
        parent_domain = Hosting.get_domain_by_name(scope, sub.parent_domain)

        cond do
          is_nil(parent_domain) ->
            msg = "#{sub.full_name}: parent domain #{sub.parent_domain} not found"
            %{acc | failed: [msg | acc.failed]}

          subdomain_exists?(parent_domain, sub.name) ->
            %{acc | skipped: [sub.full_name | acc.skipped]}

          true ->
            case Hosting.create_subdomain(parent_domain, %{name: sub.name}) do
              {:ok, _subdomain} ->
                %{acc | created: [sub.full_name | acc.created]}

              {:error, changeset} ->
                message = changeset_error_summary(changeset)
                %{acc | failed: ["#{sub.full_name}: #{message}" | acc.failed]}
            end
        end
      end)

    %{
      planned: [],
      planned_count: 0,
      created: Enum.reverse(result.created),
      created_count: length(result.created),
      skipped: Enum.reverse(result.skipped),
      skipped_count: length(result.skipped),
      failed: Enum.reverse(result.failed),
      failed_count: length(result.failed)
    }
  end

  defp subdomain_exists?(domain, subdomain_name) do
    domain
    |> Hosting.list_subdomains()
    |> Enum.any?(&(&1.name == subdomain_name))
  end

  @restore_categories [
    "web_files",
    "subdomains",
    "dns",
    "mail_accounts",
    "mail_content",
    "databases",
    "db_users",
    "cron_jobs",
    "ftp_accounts",
    "ssl_certificates"
  ]

  @local_maildir_base "/var/mail/vhosts"

  @doc """
  Restores discovered inventory data for a single domain.

  Creates the domain if it doesn't exist, then restores selected categories
  from the discovery inventory.

  `inventory` should be the discovery inventory already filtered for this domain.
  `subscription` should be the subscription map for this domain (with optional subdomains).

  Options:
    - `:categories` - list of category keys to restore (default: all categories)
    - `:apply_dns_template` - whether to apply DNS template on domain creation (default: false)
    - `:dry_run` - if true, returns a plan without writing (default: false)
    - `:ssh_opts` - SSH connection opts for mail content and web files rsync
    - `:web_files_path` - local destination path for web files rsync
    - `:progress_pid` - PID to receive `{:restore_progress, domain, category, index, total, result}` messages
  """
  def restore_domain(%Scope{} = scope, subscription, inventory, opts \\ [])
      when is_map(subscription) and is_map(inventory) do
    categories = Keyword.get(opts, :categories, @restore_categories)
    apply_dns_template = Keyword.get(opts, :apply_dns_template, false)
    dry_run = Keyword.get(opts, :dry_run, false)
    ssh_opts = Keyword.get(opts, :ssh_opts)
    web_files_path = Keyword.get(opts, :web_files_path)
    progress_pid = Keyword.get(opts, :progress_pid)
    domain_name = subscription.domain

    restore_opts = %{
      ssh_opts: ssh_opts,
      web_files_path: web_files_path,
      progress_pid: progress_pid
    }

    result = %{
      domain: domain_name,
      domain_status: nil,
      categories: %{}
    }

    if dry_run do
      {:ok, build_restore_plan(scope, subscription, inventory, categories, apply_dns_template)}
    else
      do_restore_domain(
        scope,
        subscription,
        inventory,
        categories,
        apply_dns_template,
        restore_opts,
        result
      )
    end
  end

  defp build_restore_plan(scope, subscription, inventory, categories, _apply_dns_template) do
    domain_name = subscription.domain
    existing_domain = Hosting.get_domain_by_name(scope, domain_name)

    domain_status =
      if existing_domain, do: :exists, else: :will_create

    category_plans =
      Enum.reduce(categories, %{}, fn category, acc ->
        count = plan_category_count(category, subscription, inventory)
        Map.put(acc, category, %{planned: count, status: :planned})
      end)

    %{domain: domain_name, domain_status: domain_status, categories: category_plans}
  end

  defp plan_category_count("subdomains", subscription, _inventory) do
    subscription |> Map.get(:subdomains, []) |> length()
  end

  defp plan_category_count("dns", _subscription, inventory) do
    inventory |> Map.get("dns_records", []) |> length()
  end

  defp plan_category_count(category, _subscription, inventory) do
    inventory |> Map.get(category, []) |> length()
  end

  defp do_restore_domain(
         scope,
         subscription,
         inventory,
         categories,
         apply_dns_template,
         restore_opts,
         result
       ) do
    domain_name = subscription.domain

    # Ensure domain exists
    {domain, domain_status} =
      case Hosting.get_domain_by_name(scope, domain_name) do
        nil ->
          case Hosting.create_domain(scope, %{
                 name: domain_name,
                 apply_dns_template: apply_dns_template
               }) do
            {:ok, domain} -> {domain, :created}
            {:error, cs} -> {nil, {:failed, changeset_error_summary(cs)}}
          end

        existing ->
          {existing, :exists}
      end

    result = %{result | domain_status: domain_status}

    case domain do
      nil ->
        {:error, result}

      %{} ->
        progress_pid = Map.get(restore_opts, :progress_pid)
        total = length(categories)

        category_results =
          categories
          |> Enum.with_index(1)
          |> Enum.reduce(%{}, fn {category, index}, acc ->
            notify_progress(progress_pid, domain_name, category, index, total, :in_progress)
            cat_result = restore_category(category, domain, subscription, inventory, restore_opts)
            notify_progress(progress_pid, domain_name, category, index, total, cat_result)
            Map.put(acc, category, cat_result)
          end)

        {:ok, %{result | categories: category_results}}
    end
  end

  defp restore_category("subdomains", domain, subscription, _inventory, _restore_opts) do
    subs = Map.get(subscription, :subdomains, [])
    do_restore_items(subs, fn sub -> restore_subdomain(domain, sub) end)
  end

  defp restore_category("dns", domain, _subscription, inventory, restore_opts) do
    records = Map.get(inventory, "dns_records", [])
    supported_types = Hostctl.Hosting.DnsRecord.valid_types() |> MapSet.new()

    # Build IP replacement map: old Plesk server IPs → new server IPs
    ip_replacements = build_ip_replacements(restore_opts)

    # Filter records belonging to this domain and with supported types
    domain_records =
      records
      |> Enum.filter(fn r ->
        r.domain == domain.name and MapSet.member?(supported_types, r.type)
      end)

    # Always ensure a DNS zone exists for this domain
    zone =
      case Hosting.get_dns_zone_for_domain(domain) do
        nil ->
          {:ok, zone} =
            %Hostctl.Hosting.DnsZone{domain_id: domain.id}
            |> Hostctl.Hosting.DnsZone.changeset(%{})
            |> Hostctl.Repo.insert()

          zone

        existing_zone ->
          existing_zone
      end

    if domain_records == [] do
      %{created: 0, skipped: 0, failed: 0, errors: []}
    else

      # Get existing records to avoid duplicates
      existing_records =
        Hostctl.Repo.all(
          from(r in Hostctl.Hosting.DnsRecord,
            where: r.dns_zone_id == ^zone.id,
            select: {r.type, r.name, r.value}
          )
        )

      existing_set = MapSet.new(existing_records)

      Enum.reduce(domain_records, %{created: 0, skipped: 0, failed: 0, errors: []}, fn rec, acc ->
        # Replace old host IPs with new server IPs in A/AAAA records
        value = maybe_replace_ip(rec.type, rec.value, ip_replacements)
        key = {rec.type, rec.name, value}

        if MapSet.member?(existing_set, key) do
          %{acc | skipped: acc.skipped + 1}
        else
          attrs = %{
            type: rec.type,
            name: rec.name,
            value: value,
            priority: rec.priority
          }

          case Hosting.create_dns_record(zone, attrs) do
            {:ok, _record} ->
              %{acc | created: acc.created + 1}

            {:error, cs} ->
              %{
                acc
                | failed: acc.failed + 1,
                  errors:
                    acc.errors ++ ["#{rec.type} #{rec.name}: #{changeset_error_summary(cs)}"]
              }
          end
        end
      end)
    end
  end

  defp restore_category("web_files", domain, subscription, inventory, restore_opts) do
    all_items = Map.get(inventory, "web_files", [])
    ssh_opts = Map.get(restore_opts, :ssh_opts)
    web_files_path = Map.get(restore_opts, :web_files_path)

    # Only process the parent domain entry — subdomain folders live inside
    # /var/www/vhosts/{domain}/{sub.domain}/ and are included in the parent rsync.
    subdomain_names =
      subscription
      |> Map.get(:subdomains, [])
      |> MapSet.new(& &1.full_name)

    items = Enum.reject(all_items, fn item -> MapSet.member?(subdomain_names, item.domain) end)

    cond do
      items == [] ->
        %{created: 0, skipped: 0, failed: 0, errors: []}

      is_nil(ssh_opts) ->
        %{
          created: 0,
          skipped: 0,
          failed: length(items),
          errors: ["SSH connection details required to transfer web files"],
          note: "Provide SSH credentials to enable web files rsync"
        }

      is_nil(web_files_path) || web_files_path == "" ->
        %{
          created: 0,
          skipped: 0,
          failed: length(items),
          errors: ["No destination path specified for web files"],
          note: "Set a destination path for web files"
        }

      true ->
        do_restore_items(items, fn item ->
          restore_web_files(domain, item, ssh_opts, web_files_path)
        end)
    end
  end

  defp restore_category("mail_accounts", domain, _subscription, inventory, _restore_opts) do
    accounts = Map.get(inventory, "mail_accounts", [])
    do_restore_items(accounts, fn item -> restore_mail_account(domain, item) end)
  end

  defp restore_category("mail_content", domain, _subscription, inventory, restore_opts) do
    items = Map.get(inventory, "mail_content", [])
    ssh_opts = Map.get(restore_opts, :ssh_opts)

    if is_nil(ssh_opts) do
      if items == [] do
        %{created: 0, skipped: 0, failed: 0, errors: []}
      else
        %{
          created: 0,
          skipped: 0,
          failed: length(items),
          errors: ["SSH connection details required to transfer mail content"],
          note: "Provide SSH credentials to enable mail content rsync"
        }
      end
    else
      do_restore_items(items, fn item -> restore_mail_content(domain, item, ssh_opts) end)
    end
  end

  defp restore_category("databases", domain, _subscription, inventory, restore_opts) do
    dbs = Map.get(inventory, "databases", [])
    ssh_opts = Map.get(restore_opts, :ssh_opts)

    if ssh_opts != nil and dbs != [] do
      restore_databases_via_pleskbackup(domain, dbs, ssh_opts)
    else
      do_restore_items(dbs, fn item -> restore_database(domain, item) end)
    end
  end

  defp restore_category("db_users", domain, _subscription, inventory, _restore_opts) do
    users = Map.get(inventory, "db_users", [])
    do_restore_items(users, fn item -> restore_db_user(domain, item) end)
  end

  defp restore_category("cron_jobs", _domain, _subscription, inventory, _restore_opts) do
    jobs = Map.get(inventory, "cron_jobs", [])

    if jobs == [] do
      %{created: 0, skipped: 0, failed: 0, errors: []}
    else
      %{
        created: 0,
        skipped: 0,
        failed: 0,
        errors: [],
        note: "Cron job detail import not yet supported (only counts discovered)"
      }
    end
  end

  defp restore_category("ftp_accounts", domain, _subscription, inventory, _restore_opts) do
    accounts = Map.get(inventory, "ftp_accounts", [])
    do_restore_items(accounts, fn item -> restore_ftp_account(domain, item) end)
  end

  defp restore_category("ssl_certificates", _domain, _subscription, inventory, _restore_opts) do
    certs = Map.get(inventory, "ssl_certificates", [])

    if certs == [] do
      %{created: 0, skipped: 0, failed: 0, errors: []}
    else
      %{
        created: 0,
        skipped: 0,
        failed: 0,
        errors: [],
        note: "SSL certificate content import not yet supported (only names discovered)"
      }
    end
  end

  defp restore_category(_category, _domain, _subscription, _inventory, _restore_opts) do
    %{created: 0, skipped: 0, failed: 0, errors: []}
  end

  defp notify_progress(nil, _domain, _category, _index, _total, _status), do: :ok

  defp notify_progress(pid, domain, category, index, total, status) do
    send(pid, {:restore_progress, domain, category, index, total, status})
  end

  defp do_restore_items(items, restore_fn) do
    Enum.reduce(items, %{created: 0, skipped: 0, failed: 0, errors: []}, fn item, acc ->
      case restore_fn.(item) do
        :created -> %{acc | created: acc.created + 1}
        :skipped -> %{acc | skipped: acc.skipped + 1}
        {:failed, reason} -> %{acc | failed: acc.failed + 1, errors: [reason | acc.errors]}
      end
    end)
  end

  defp restore_subdomain(domain, sub) do
    if subdomain_exists?(domain, sub.name) do
      :skipped
    else
      # Skip auto-creating DNS records — the "dns" restore category handles
      # those with the actual records from Plesk (with IP replacement).
      case Hosting.create_subdomain(domain, %{name: sub.name}, skip_dns_records: true) do
        {:ok, _} -> :created
        {:error, cs} -> {:failed, "#{sub.full_name}: #{changeset_error_summary(cs)}"}
      end
    end
  end

  defp restore_mail_account(domain, item) do
    username =
      item.address
      |> String.split("@")
      |> List.first()

    existing =
      domain
      |> Hosting.list_email_accounts()
      |> Enum.any?(&(&1.username == username))

    if existing do
      :skipped
    else
      # Create with a random password since we can't recover the original
      password = generate_random_password()

      case Hosting.create_email_account(domain, %{
             username: username,
             password: password,
             quota_mb: 500
           }) do
        {:ok, _} -> :created
        {:error, cs} -> {:failed, "#{item.address}: #{changeset_error_summary(cs)}"}
      end
    end
  end

  defp restore_mail_content(domain, item, ssh_opts) do
    username =
      item.address
      |> String.split("@")
      |> List.first()

    remote_path = item.path
    local_path = Path.join([@local_maildir_base, domain.name, username, "Maildir"])

    # Ensure local maildir directory exists with proper ownership
    case ensure_local_maildir(local_path) do
      :ok ->
        case rsync_maildir(ssh_opts, remote_path, local_path) do
          :ok ->
            # Fix ownership after rsync
            fix_maildir_ownership(local_path)
            :created

          {:error, reason} ->
            {:failed, "#{item.address}: rsync failed - #{reason}"}
        end

      {:error, reason} ->
        {:failed, "#{item.address}: #{reason}"}
    end
  end

  @plesk_rsync_excludes [
    ".cache/",
    ".composer/",
    ".local/",
    ".trash/",
    ".ssh/",
    ".pki/",
    ".nodenv/",
    ".phpenv/",
    ".rbenv/",
    ".wp-cli/",
    ".revisium_antivirus_cache/",
    "error_docs/",
    ".bash*",
    ".node-version",
    ".php-ini",
    ".php-version",
    ".imunify*",
    ".myimunify*",
    ".wget*",
    ".yarnrc"
  ]

  defp restore_web_files(_domain, item, ssh_opts, local_base_path) do
    # Rsync the entire domain directory, not just the document root.
    # Plesk stores web files under /var/www/vhosts/{domain}/ with httpdocs/
    # as the docroot. Our default domain docroot is also httpdocs/, so the
    # rsynced structure maps directly with no rename needed.
    remote_path = "/var/www/vhosts/#{item.domain}"

    case ensure_local_directory(local_base_path) do
      :ok ->
        case do_rsync(ssh_opts, remote_path, local_base_path,
               timeout: 3600,
               excludes: @plesk_rsync_excludes,
               chown: "www-data:www-data"
             ) do
          :ok ->
            :created

          {:error, reason} ->
            {:failed, "#{item.domain}: rsync failed - #{reason}"}
        end

      {:error, reason} ->
        {:failed, "#{item.domain}: #{reason}"}
    end
  end

  defp ensure_local_directory(path) do
    args = ["mkdir", "-p", path]

    case System.cmd("sudo", ["systemd-run", "--pipe", "--wait", "--collect", "--quiet" | args],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {output, _} -> {:error, "Failed to create directory: #{String.trim(output)}"}
    end
  end

  defp ensure_local_maildir(path) do
    args = ["mkdir", "-p", path]

    case System.cmd("sudo", ["systemd-run", "--pipe", "--wait", "--collect", "--quiet" | args],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {output, _} -> {:error, "Failed to create maildir: #{String.trim(output)}"}
    end
  end

  defp fix_maildir_ownership(path) do
    args = ["/usr/bin/chown", "-R", "5000:5000", path]

    System.cmd("sudo", ["systemd-run", "--pipe", "--wait", "--collect", "--quiet" | args],
      stderr_to_stdout: true
    )
  end

  defp rsync_maildir(ssh_opts, remote_path, local_path) do
    do_rsync(ssh_opts, remote_path, local_path, timeout: 60, chown: "5000:5000")
  end

  defp do_rsync(ssh_opts, remote_path, local_path, opts) do
    host = normalize_string(Map.get(ssh_opts, :host) || Map.get(ssh_opts, "host"))
    port = normalize_string(Map.get(ssh_opts, :port) || Map.get(ssh_opts, "port"))
    username = normalize_string(Map.get(ssh_opts, :username) || Map.get(ssh_opts, "username"))
    timeout = Keyword.get(opts, :timeout, 300)
    excludes = Keyword.get(opts, :excludes, [])
    chown = Keyword.get(opts, :chown)

    # Build the remote rsync-path with sudo.
    # For password auth we use SUDO_ASKPASS so stdin stays free for rsync.
    rsync_path = remote_rsync_path(ssh_opts)

    with {:ok, sshpass_prefix, auth_args, env} <- ssh_auth_parts(ssh_opts) do
      # Ensure remote_path ends with / for rsync directory sync
      remote_path =
        if String.ends_with?(remote_path, "/"), do: remote_path, else: remote_path <> "/"

      remote = "#{username}@#{host}:#{remote_path}"

      ssh_args = ["-p", port] ++ auth_args
      ssh_cmd = String.trim("#{sshpass_prefix} ssh #{Enum.join(ssh_args, " ")}")

      rsync = System.find_executable("rsync") || "rsync"

      # Forward env vars (e.g. SSHPASS) into the systemd-run environment
      env_args =
        Enum.flat_map(env, fn {k, v} ->
          ["--setenv=#{k}=#{v}"]
        end)

      exclude_args = Enum.map(excludes, fn pattern -> "--exclude=#{pattern}" end)
      chown_args = if chown, do: ["--chown=#{chown}"], else: []

      args =
        ["systemd-run", "--pipe", "--wait", "--collect", "--quiet"] ++
          env_args ++
          [
            rsync,
            "-rltzD",
            "--chmod=D755,F644",
            "--timeout=#{timeout}",
            "--rsync-path=#{rsync_path}"
          ] ++
          chown_args ++
          exclude_args ++
          [
            "-e",
            ssh_cmd,
            remote,
            local_path <> "/"
          ]

      case System.cmd("sudo", args, stderr_to_stdout: true, env: env) do
        # exit 0 = success, exit 24 = partial transfer (vanished source files) — both OK
        {_, code} when code in [0, 24] -> :ok
        {output, _} -> {:error, String.trim(output)}
      end
    end
  end

  defp restore_database(domain, item) do
    db_type =
      (Map.get(item, :db_type) || Map.get(item, "db_type") || "mysql")
      |> normalize_db_type()

    existing =
      domain
      |> Hosting.list_databases()
      |> Enum.find(&(&1.name == item.name))

    case existing do
      nil ->
        case Hosting.create_database(domain, %{name: item.name, db_type: db_type}) do
          {:ok, _db} -> :created
          {:error, cs} -> {:failed, "#{item.name}: #{changeset_error_summary(cs)}"}
        end

      _db ->
        :skipped
    end
  end

  # ---------------------------------------------------------------------------
  # pleskbackup-based database import
  # ---------------------------------------------------------------------------
  # Runs `pleskbackup` on the remote Plesk server (which has its own DB creds),
  # downloads the backup tar via SCP, extracts SQL dumps, and imports each one
  # into the corresponding local database.
  # ---------------------------------------------------------------------------

  defp restore_databases_via_pleskbackup(domain, dbs, ssh_opts) do
    # Partition databases by type — pleskbackup only includes MySQL dumps,
    # so PostgreSQL databases need a separate pg_dump-over-SSH path.
    {pg_dbs, mysql_dbs} =
      Enum.split_with(dbs, fn item ->
        db_type =
          (Map.get(item, :db_type) || Map.get(item, "db_type") || "mysql")
          |> normalize_db_type()

        db_type == "postgresql"
      end)

    mysql_results =
      if mysql_dbs != [] do
        restore_mysql_databases_via_pleskbackup(domain, mysql_dbs, ssh_opts)
      else
        %{created: 0, skipped: 0, failed: 0, errors: []}
      end

    pg_results =
      if pg_dbs != [] do
        restore_pg_databases_via_ssh(domain, pg_dbs, ssh_opts)
      else
        %{created: 0, skipped: 0, failed: 0, errors: []}
      end

    # Merge results from both paths
    %{
      created: mysql_results.created + pg_results.created,
      skipped: mysql_results.skipped + pg_results.skipped,
      failed: mysql_results.failed + pg_results.failed,
      errors: mysql_results.errors ++ pg_results.errors
    }
  end

  # ---------------------------------------------------------------------------
  # MySQL: pleskbackup-based database import
  # ---------------------------------------------------------------------------

  defp restore_mysql_databases_via_pleskbackup(domain, dbs, ssh_opts) do
    # Step 1: Create all database entries in hostctl
    db_statuses =
      Enum.map(dbs, fn item ->
        {item, restore_database(domain, item)}
      end)

    # Step 2: Run pleskbackup, download, extract, and import
    case download_plesk_db_backup(domain.name, ssh_opts) do
      {:ok, extract_dir} ->
        results =
          Enum.map(db_statuses, fn
            {_item, {:failed, _} = status} ->
              status

            {item, create_status} ->
              db_type =
                (Map.get(item, :db_type) || Map.get(item, "db_type") || "mysql")
                |> normalize_db_type()

              case find_and_import_dump(extract_dir, item.name, db_type) do
                :ok ->
                  :created

                :not_found ->
                  all_files =
                    Path.wildcard("#{extract_dir}/**/*")
                    |> Enum.reject(&File.dir?/1)
                    |> Enum.map(&String.replace_leading(&1, extract_dir <> "/", ""))

                  Logger.warning(
                    "[Importer] No SQL dump found for DB '#{item.name}'. " <>
                      "Files in backup: #{inspect(all_files)}"
                  )

                  label = if create_status == :created, do: "created but ", else: ""
                  {:failed, "#{item.name}: #{label}no SQL dump found in backup"}

                {:error, reason} ->
                  label = if create_status == :created, do: "created but ", else: ""
                  {:failed, "#{item.name}: #{label}data import failed - #{reason}"}
              end
          end)

        File.rm_rf(extract_dir)
        tally_restore_results(results)

      {:error, reason} ->
        # Backup failed — report database creation results + backup error
        results =
          Enum.map(db_statuses, fn
            {_item, {:failed, _} = status} ->
              status

            {item, :created} ->
              {:failed, "#{item.name}: created but backup failed - #{reason}"}

            {item, _} ->
              {:failed, "#{item.name}: backup failed - #{reason}"}
          end)

        tally_restore_results(results)
    end
  end

  # ---------------------------------------------------------------------------
  # PostgreSQL: pg_dump-over-SSH database import
  # ---------------------------------------------------------------------------
  # pleskbackup does not include PostgreSQL dumps. Instead, we run pg_dump
  # directly on the remote Plesk server via SSH using `sudo -u postgres`
  # (which leverages PostgreSQL's peer authentication on Unix sockets).
  # ---------------------------------------------------------------------------

  defp restore_pg_databases_via_ssh(domain, dbs, ssh_opts) do
    results =
      Enum.map(dbs, fn item ->
        # Step 1: Create the database entry locally
        create_status = restore_database(domain, item)

        case create_status do
          {:failed, _} = status ->
            status

          _ ->
            # Step 2: pg_dump on remote, download, and import locally
            case dump_pg_database_via_ssh(item.name, ssh_opts) do
              {:ok, local_dir, dump_file} ->
                result = import_sql_file(dump_file, item.name, "postgresql")
                File.rm_rf(local_dir)

                case result do
                  :ok -> :created
                  {:error, reason} ->
                    label = if create_status == :created, do: "created but ", else: ""
                    {:failed, "#{item.name}: #{label}data import failed - #{reason}"}
                end

              {:error, reason} ->
                label = if create_status == :created, do: "created but ", else: ""
                {:failed, "#{item.name}: #{label}pg_dump failed - #{reason}"}
            end
        end
      end)

    tally_restore_results(results)
  end

  defp dump_pg_database_via_ssh(db_name, ssh_opts) do
    rand =
      :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false) |> String.slice(0, 8)

    remote_dump = "/tmp/hostctl_pgdump_#{rand}.sql"
    local_dir = Path.join(System.tmp_dir!(), "hostctl_pgdump_#{rand}")
    local_dump = Path.join(local_dir, "#{db_name}.sql")

    File.mkdir_p!(local_dir)

    # Locate pg_dump on the remote — no sudo needed to find the binary path.
    # Check common locations: /bin, /usr/bin, /usr/local/bin, and distro-specific
    # paths like /usr/lib/postgresql/*/bin/ (Debian/Ubuntu).
    find_pg_dump_cmd =
      "command -v pg_dump 2>/dev/null " <>
        "|| for d in /bin /usr/bin /usr/local/bin /usr/lib/postgresql/*/bin /usr/pgsql-*/bin; do " <>
        "[ -x \"$d/pg_dump\" ] && echo \"$d/pg_dump\" && break; done"

    pg_dump_bin =
      case ssh_exec_output(ssh_opts, find_pg_dump_cmd) do
        {:ok, path} ->
          trimmed = String.trim(path)
          if trimmed != "", do: trimmed, else: "/usr/bin/pg_dump"

        _ ->
          "/usr/bin/pg_dump"
      end

    Logger.info("[Importer] Dumping PostgreSQL DB '#{db_name}' via SSH (pg_dump=#{pg_dump_bin})")

    # Build the full dump command. Uses SUDO_ASKPASS (same proven pattern as
    # rsync) to avoid piping the password through stdin, which can interfere
    # with command output and cause empty dumps.
    auth_method =
      normalize_string(Map.get(ssh_opts, :auth_method) || Map.get(ssh_opts, "auth_method"))

    password =
      normalize_string(Map.get(ssh_opts, :password) || Map.get(ssh_opts, "password"))

    escaped_pg_dump = shell_escape(pg_dump_bin)
    escaped_db = shell_escape(db_name)
    escaped_out = shell_escape(remote_dump)
    remote_err = "/tmp/hostctl_pgdump_err_#{rand}.log"
    escaped_err = shell_escape(remote_err)

    # cd /tmp first so sudo -u postgres doesn't try to cd to the calling
    # user's home dir (which it can't access → "could not change directory"
    # warning that was previously contaminating the SQL dump via 2>&1).
    # stderr goes to a separate file so it never mixes with the SQL dump.
    dump_cmd =
      if auth_method == "password" and password != "" do
        escaped_pass = String.replace(password, "'", "'\\''")
        askpass = "/tmp/hostctl_pgask_#{rand}"

        "AP=#{askpass}; " <>
          "printf '#!/bin/sh\\necho '\"'\"'#{escaped_pass}'\"'\"'\\n' > $AP && " <>
          "chmod 700 $AP && " <>
          "cd /tmp && " <>
          "SUDO_ASKPASS=$AP sudo -A -u postgres " <>
          "#{escaped_pg_dump} --no-owner --no-acl #{escaped_db} > #{escaped_out} 2>#{escaped_err}; " <>
          "RC=$?; rm -f $AP; " <>
          "if [ $RC -ne 0 ]; then cat #{escaped_err} >&2; fi; " <>
          "rm -f #{escaped_err}; exit $RC"
      else
        "cd /tmp && sudo -u postgres #{escaped_pg_dump} --no-owner --no-acl " <>
          "#{escaped_db} > #{escaped_out} 2>#{escaped_err}; " <>
          "RC=$?; if [ $RC -ne 0 ]; then cat #{escaped_err} >&2; fi; " <>
          "rm -f #{escaped_err}; exit $RC"
      end

    with {:ok, output} <- ssh_exec_output(ssh_opts, dump_cmd) do
      if output != "", do: Logger.info("[Importer] pg_dump output for '#{db_name}': #{output}")

      case scp_download(ssh_opts, remote_dump, local_dump) do
        :ok ->
          ssh_exec(ssh_opts, "rm -f #{escaped_out}")
          validate_pg_dump(local_dir, local_dump, db_name)

        {:error, reason} ->
          File.rm_rf(local_dir)
          ssh_exec(ssh_opts, "rm -f #{escaped_out}")
          {:error, "SCP download failed: #{reason}"}
      end
    else
      {:error, reason} ->
        File.rm_rf(local_dir)
        ssh_exec(ssh_opts, "rm -f #{escaped_out}")
        {:error, reason}
    end
  end

  defp validate_pg_dump(local_dir, local_dump, db_name) do
    case File.stat(local_dump) do
      {:ok, %{size: size}} when size > 100 ->
        # Log the first few lines for diagnostics
        head =
          case File.open(local_dump, [:read, :utf8]) do
            {:ok, file} ->
              lines = Enum.reduce_while(1..15, [], fn _, acc ->
                case IO.read(file, :line) do
                  :eof -> {:halt, acc}
                  {:error, _} -> {:halt, acc}
                  line -> {:cont, [line | acc]}
                end
              end)
              File.close(file)
              Enum.reverse(lines)

            _ ->
              []
          end

        Logger.info(
          "[Importer] PG dump head for '#{db_name}' (#{size} bytes):\n" <>
            Enum.join(head, "")
        )

        # Check for actual table data
        has_tables? =
          case System.cmd("grep", ["-c", "-E", "^(CREATE TABLE|COPY )", local_dump],
                 stderr_to_stdout: true
               ) do
            {count_str, 0} -> String.trim(count_str) != "0"
            _ -> false
          end

        if has_tables? do
          {:ok, local_dir, local_dump}
        else
          Logger.warning("[Importer] PG dump for '#{db_name}' has no CREATE TABLE or COPY statements")
          {:ok, local_dir, local_dump}
        end

      {:ok, %{size: size}} ->
        Logger.warning(
          "[Importer] PG dump for '#{db_name}' is suspiciously small: #{size} bytes"
        )

        File.rm_rf(local_dir)
        {:error, "pg_dump produced empty or near-empty output (#{size} bytes)"}

      {:error, reason} ->
        File.rm_rf(local_dir)
        {:error, "dump file not found after download: #{inspect(reason)}"}
    end
  end

  defp tally_restore_results(results) do
    Enum.reduce(results, %{created: 0, skipped: 0, failed: 0, errors: []}, fn
      :created, acc -> %{acc | created: acc.created + 1}
      :skipped, acc -> %{acc | skipped: acc.skipped + 1}
      {:failed, reason}, acc -> %{acc | failed: acc.failed + 1, errors: [reason | acc.errors]}
    end)
  end

  defp download_plesk_db_backup(domain_name, ssh_opts) do
    rand = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false) |> String.slice(0, 8)
    remote_tar = "/tmp/hostctl_dbexport_#{rand}.tar"
    local_dir = Path.join(System.tmp_dir!(), "hostctl_dbexport_#{rand}")
    local_tar = Path.join(local_dir, "backup.tar")

    File.mkdir_p!(local_dir)

    sudo_prefix = sudo_prefix(ssh_opts)

    backup_cmd =
      "#{sudo_prefix}plesk bin pleskbackup --domains-name #{shell_escape(domain_name)}" <>
        " -exclude-files -exclude-mail -exclude-logs" <>
        " -output-file #{shell_escape(remote_tar)}"

    with :ok <- ssh_exec(ssh_opts, backup_cmd),
         :ok <- scp_download(ssh_opts, remote_tar, local_tar),
         _ <- ssh_exec(ssh_opts, "rm -f #{shell_escape(remote_tar)}"),
         :ok <- extract_backup_archives(local_dir) do
      {:ok, local_dir}
    else
      {:error, reason} ->
        File.rm_rf(local_dir)
        # Try to clean up remote tar too
        ssh_exec(ssh_opts, "rm -f #{shell_escape(remote_tar)}")
        {:error, reason}
    end
  end

  defp ssh_exec(ssh_opts, command) do
    case ssh_exec_output(ssh_opts, command) do
      {:ok, _output} -> :ok
      error -> error
    end
  end

  defp ssh_exec_output(ssh_opts, command) do
    host = normalize_string(Map.get(ssh_opts, :host) || Map.get(ssh_opts, "host"))
    port = normalize_string(Map.get(ssh_opts, :port) || Map.get(ssh_opts, "port"))
    username = normalize_string(Map.get(ssh_opts, :username) || Map.get(ssh_opts, "username"))

    with {:ok, sshpass_prefix, auth_args, env} <- ssh_auth_parts(ssh_opts) do
      args = ["-p", port] ++ auth_args ++ ["#{username}@#{host}", command]

      full_cmd =
        String.trim("#{sshpass_prefix} ssh #{Enum.map_join(args, " ", &shell_escape/1)}")

      case System.cmd("/bin/sh", ["-c", full_cmd], stderr_to_stdout: true, env: env) do
        {output, 0} -> {:ok, String.trim(output)}
        {output, _} -> {:error, String.trim(output)}
      end
    end
  end

  defp scp_download(ssh_opts, remote_path, local_path) do
    host = normalize_string(Map.get(ssh_opts, :host) || Map.get(ssh_opts, "host"))
    port = normalize_string(Map.get(ssh_opts, :port) || Map.get(ssh_opts, "port"))
    username = normalize_string(Map.get(ssh_opts, :username) || Map.get(ssh_opts, "username"))

    with {:ok, sshpass_prefix, auth_args, env} <- ssh_auth_parts(ssh_opts) do
      # SCP uses -P (uppercase) for port
      args = ["-P", port] ++ auth_args ++ ["#{username}@#{host}:#{remote_path}", local_path]

      full_cmd =
        String.trim("#{sshpass_prefix} scp #{Enum.map_join(args, " ", &shell_escape/1)}")

      case System.cmd("/bin/sh", ["-c", full_cmd], stderr_to_stdout: true, env: env) do
        {_, 0} -> :ok
        {output, _} -> {:error, "scp download failed: #{String.trim(output)}"}
      end
    end
  end

  # Builds a sudo prefix for remote commands. With password auth, pipes the
  # SSH password into `sudo -S`. With key auth, uses plain `sudo` (requires
  # NOPASSWD in sudoers).
  defp sudo_prefix(ssh_opts) do
    auth_method =
      normalize_string(Map.get(ssh_opts, :auth_method) || Map.get(ssh_opts, "auth_method"))

    password =
      normalize_string(Map.get(ssh_opts, :password) || Map.get(ssh_opts, "password"))

    if auth_method == "password" and password != "" do
      "echo #{shell_escape(password)} | sudo -S "
    else
      "sudo "
    end
  end

  # Builds the --rsync-path value for running rsync as root on the remote.
  # Unlike sudo_prefix (which is for one-shot commands), this must preserve
  # stdin for the rsync protocol. With password auth we feed the password to
  # sudo via printf, then `cat` forwards the rsync protocol data.
  defp remote_rsync_path(ssh_opts) do
    auth_method =
      normalize_string(Map.get(ssh_opts, :auth_method) || Map.get(ssh_opts, "auth_method"))

    password =
      normalize_string(Map.get(ssh_opts, :password) || Map.get(ssh_opts, "password"))

    if auth_method == "password" and password != "" do
      # Write a tiny SUDO_ASKPASS helper script on the remote that echoes
      # the password, run sudo -A (which calls the askpass script instead of
      # reading from stdin), then clean up. This keeps stdin completely free
      # for rsync's protocol data — the previous (printf; cat) | sudo -S
      # approach caused cat to hang after rsync finished because it kept
      # waiting for more data on stdin.
      escaped = String.replace(password, "'", "'\\''")

      "sh -c '" <>
        "AP=/tmp/.rsync_askpass_$$; " <>
        "printf \"#!/bin/sh\\necho " <> "'\"'\"'" <> escaped <> "'\"'\"'" <> "\\n\" > $AP; " <>
        "chmod 700 $AP; " <>
        "SUDO_ASKPASS=$AP sudo -A rsync \"$@\"; " <>
        "RC=$?; rm -f $AP; exit $RC" <>
        "' rsync"
    else
      "sudo rsync"
    end
  end

  defp ssh_auth_parts(ssh_opts) do
    auth_method =
      normalize_string(Map.get(ssh_opts, :auth_method) || Map.get(ssh_opts, "auth_method"))

    password =
      normalize_string(Map.get(ssh_opts, :password) || Map.get(ssh_opts, "password"))

    case auth_method do
      "password" ->
        case find_cmd(["sshpass"]) do
          nil ->
            {:error, "sshpass not found — install with: apt install sshpass"}

          sshpass ->
            env =
              if is_binary(password) and password != "" do
                [{"SSHPASS", password}]
              else
                []
              end

            {:ok, "#{sshpass} -e", ["-o", "StrictHostKeyChecking=accept-new"], env}
        end

      _ ->
        private_key_path =
          ssh_opts
          |> Map.get(:private_key_path, Map.get(ssh_opts, "private_key_path"))
          |> normalize_string()
          |> expand_tilde_path()

        {:ok, "",
         [
           "-o",
           "BatchMode=yes",
           "-o",
           "StrictHostKeyChecking=accept-new",
           "-i",
           private_key_path
         ], []}
    end
  end

  defp extract_backup_archives(dir) do
    # Extract the main backup archive (Plesk may use tar, tar.gz, or zstd-compressed tar)
    tar_files =
      Path.wildcard("#{dir}/*.tar") ++
        Path.wildcard("#{dir}/*.tar.gz") ++
        Path.wildcard("#{dir}/*.tgz") ++
        Path.wildcard("#{dir}/*.tar.zst") ++
        Path.wildcard("#{dir}/*.tzst")

    case tar_files do
      [] ->
        {:error, "no backup tar found"}

      _ ->
        Enum.each(tar_files, fn tar ->
          extract_tar(tar, dir)
        end)

        # Recursively extract nested tars — Plesk backups can nest 3+ levels deep
        extract_nested_archives(dir, MapSet.new(tar_files))

        :ok
    end
  end

  defp extract_nested_archives(dir, already_extracted) do
    nested =
      (Path.wildcard("#{dir}/**/*.tar") ++
         Path.wildcard("#{dir}/**/*.tar.gz") ++
         Path.wildcard("#{dir}/**/*.tgz") ++
         Path.wildcard("#{dir}/**/*.tar.zst") ++
         Path.wildcard("#{dir}/**/*.tzst"))
      |> Enum.reject(&MapSet.member?(already_extracted, &1))

    if nested == [] do
      :ok
    else
      newly_extracted =
        Enum.reduce(nested, already_extracted, fn nested_tar, acc ->
          extract_tar(nested_tar, Path.dirname(nested_tar))
          MapSet.put(acc, nested_tar)
        end)

      # Recurse to handle any newly revealed archives
      extract_nested_archives(dir, newly_extracted)
    end
  end

  defp extract_tar(tar_path, dest_dir) do
    cond do
      String.ends_with?(tar_path, ".zst") or String.ends_with?(tar_path, ".tzst") ->
        # zstd-compressed tar — use --zstd flag (GNU tar) or pipe through zstd
        case System.cmd("tar", ["--zstd", "-xf", tar_path, "-C", dest_dir],
               stderr_to_stdout: true
             ) do
          {_, 0} ->
            :ok

          _ ->
            # Fallback: pipe through zstd -d
            System.cmd("/bin/sh", ["-c", "zstd -d -c #{shell_escape(tar_path)} | tar xf - -C #{shell_escape(dest_dir)}"],
              stderr_to_stdout: true
            )
        end

      true ->
        # tar can auto-detect gz/bz2 compression with xf
        System.cmd("tar", ["xf", tar_path, "-C", dest_dir], stderr_to_stdout: true)
    end
  end

  defp find_and_import_dump(extract_dir, db_name, db_type) do
    # Search for dump files — Plesk uses various naming conventions:
    #   - Standard: *.sql, *.sql.gz
    #   - Plesk backup: databases/{name}_N/backup_sqldump_* (with optional .tzst/.zst)
    all_dump_files =
      Path.wildcard("#{extract_dir}/**/*.sql") ++
        Path.wildcard("#{extract_dir}/**/*.sql.gz") ++
        Path.wildcard("#{extract_dir}/**/backup_sqldump_*") ++
        Path.wildcard("#{extract_dir}/**/*.sql.zst") ++
        Path.wildcard("#{extract_dir}/**/*.sql.tzst")

    # Deduplicate and exclude directories
    all_dump_files =
      all_dump_files
      |> Enum.uniq()
      |> Enum.reject(&File.dir?/1)

    db_name_lower = String.downcase(db_name)

    # Try matching by basename first
    match =
      Enum.find(all_dump_files, fn path ->
        basename = Path.basename(path) |> String.downcase()
        String.contains?(basename, db_name_lower)
      end)

    # Fall back to matching by any component in the path
    # (e.g. databases/anope_1/backup_sqldump_... where dir contains "anope")
    match =
      match ||
        Enum.find(all_dump_files, fn path ->
          path |> String.downcase() |> String.contains?(db_name_lower)
        end)

    Logger.info(
      "[Importer] DB dump search for '#{db_name}': found #{length(all_dump_files)} dump file(s), " <>
        "match=#{inspect(match && Path.relative_to(match, extract_dir))}"
    )

    case match do
      nil -> :not_found
      dump_file -> import_sql_file(dump_file, db_name, db_type)
    end
  end

  defp import_sql_file(dump_file, db_name, db_type) do
    with {:ok, import_cmd} <- local_import_command(db_name, db_type) do
      cat_cmd =
        cond do
          String.ends_with?(dump_file, ".gz") -> "zcat"
          String.ends_with?(dump_file, ".zst") or String.ends_with?(dump_file, ".tzst") -> "zstd -d -c"
          true -> "cat"
        end

      full_cmd = "#{cat_cmd} #{shell_escape(dump_file)} | #{import_cmd}"

      Logger.info("[Importer] Importing DB dump: #{full_cmd}")

      case System.cmd("/bin/sh", ["-c", full_cmd], stderr_to_stdout: true) do
        {output, 0} ->
          if output != "" do
            Logger.info("[Importer] DB import output for '#{db_name}': #{String.slice(String.trim(output), 0, 2000)}")
          end

          :ok

        {output, code} ->
          Logger.warning("[Importer] DB import failed for '#{db_name}' (exit #{code}): #{String.trim(output)}")
          {:error, String.trim(output)}
      end
    end
  end

  defp restore_db_user(domain, item) do
    databases = Hosting.list_databases(domain)
    target_db = Enum.find(databases, &(&1.name == item.database))

    cond do
      is_nil(target_db) ->
        {:failed, "#{item.login}: database #{item.database} not found"}

      Hosting.list_db_users(target_db) |> Enum.any?(&(&1.username == item.login)) ->
        :skipped

      true ->
        password = generate_random_password()

        case Hosting.create_db_user(target_db, %{
               username: item.login,
               password: password
             }) do
          {:ok, _} -> :created
          {:error, cs} -> {:failed, "#{item.login}: #{changeset_error_summary(cs)}"}
        end
    end
  end

  defp local_import_command(db_name, "postgresql") do
    config = Application.get_env(:hostctl, :postgres_server, [])

    case find_cmd(["psql"]) do
      nil ->
        {:error, "psql client not found"}

      cmd ->
        host = Keyword.get(config, :hostname, "localhost")
        port = Keyword.get(config, :port, 5432)
        user = Keyword.get(config, :username, "postgres")

        {:ok,
         "PGPASSWORD=#{shell_escape(Keyword.get(config, :password, ""))} " <>
           "#{cmd} -v ON_ERROR_STOP=1 -h #{shell_escape(host)} -p #{port} -U #{shell_escape(user)} #{shell_escape(db_name)}"}
    end
  end

  defp local_import_command(db_name, _mysql) do
    config = Application.get_env(:hostctl, :database_server, [])

    case find_cmd(["mysql", "mariadb"]) do
      nil ->
        {:error, "mysql/mariadb client not found"}

      cmd ->
        host = Keyword.get(config, :hostname, "localhost")
        port = Keyword.get(config, :port, 3306)
        user = Keyword.get(config, :username, "root")
        pass = Keyword.get(config, :password, "")

        args = "#{cmd} -h #{shell_escape(host)} -P #{port} -u #{shell_escape(user)}"

        args =
          if pass != "" do
            args <> " -p#{shell_escape(pass)}"
          else
            args
          end

        {:ok, "#{args} #{shell_escape(db_name)}"}
    end
  end

  @common_bin_dirs ["/usr/bin", "/usr/local/bin", "/usr/sbin", "/usr/local/sbin"]

  defp find_cmd(names) do
    Enum.find_value(names, fn name ->
      System.find_executable(name) ||
        Enum.find_value(@common_bin_dirs, fn dir ->
          path = Path.join(dir, name)
          if File.exists?(path), do: path
        end)
    end)
  end

  defp shell_escape(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end

  # Build a map of old Plesk server IPs to new server IPs for DNS record replacement.
  defp build_ip_replacements(restore_opts) do
    ssh_opts = Map.get(restore_opts, :ssh_opts)

    if ssh_opts do
      host = normalize_string(Map.get(ssh_opts, :host) || Map.get(ssh_opts, "host"))

      # Try to get the remote server's IPs by querying it directly via SSH,
      # falling back to local DNS resolution
      old_ips =
        case ssh_exec_output(ssh_opts, "hostname -I") do
          {:ok, output} ->
            ips = output |> String.split() |> Enum.reject(&(&1 == ""))
            Logger.info("[Importer] Got remote server IPs via SSH: #{inspect(ips)}")
            ips

          {:error, reason} ->
            Logger.info("[Importer] Could not query remote IPs via SSH (#{reason}), falling back to DNS resolution")
            resolve_host_ips(host)
        end

      {new_ipv4, new_ipv6} = Hostctl.Settings.server_ips()

      Logger.info(
        "[Importer] DNS IP replacement: host=#{inspect(host)} old_ips=#{inspect(old_ips)} new_ipv4=#{inspect(new_ipv4)} new_ipv6=#{inspect(new_ipv6)}"
      )

      replacements =
        Enum.reduce(old_ips, %{}, fn old_ip, acc ->
          if String.contains?(old_ip, ":") do
            # IPv6
            if new_ipv6 != "", do: Map.put(acc, old_ip, new_ipv6), else: acc
          else
            # IPv4
            if new_ipv4 != "", do: Map.put(acc, old_ip, new_ipv4), else: acc
          end
        end)

      if replacements != %{} do
        Logger.info(
          "[Importer] DNS IP replacements: #{inspect(replacements)}"
        )
      else
        Logger.warning(
          "[Importer] DNS IP replacement: no replacements built (old IPs may not match or server IPs not configured)"
        )
      end

      replacements
    else
      Logger.info("[Importer] DNS IP replacement skipped: no ssh_opts in restore_opts")
      %{}
    end
  end

  # Resolve a hostname to its IP addresses. If already an IP, returns it as-is.
  defp resolve_host_ips(host) when is_binary(host) and host != "" do
    charlist = String.to_charlist(host)

    # Check if it's already an IP address
    case :inet.parse_address(charlist) do
      {:ok, _} ->
        [host]

      {:error, _} ->
        # It's a hostname — resolve it
        ipv4s =
          case :inet.getaddrs(charlist, :inet) do
            {:ok, addrs} -> Enum.map(addrs, &:inet.ntoa/1) |> Enum.map(&to_string/1)
            _ -> []
          end

        ipv6s =
          case :inet.getaddrs(charlist, :inet6) do
            {:ok, addrs} -> Enum.map(addrs, &:inet.ntoa/1) |> Enum.map(&to_string/1)
            _ -> []
          end

        Enum.uniq(ipv4s ++ ipv6s)
    end
  end

  defp resolve_host_ips(_), do: []

  # Replace A/AAAA record values that match old host IPs with new server IPs.
  defp maybe_replace_ip(type, value, replacements)
       when type in ["A", "AAAA"] and map_size(replacements) > 0 do
    Map.get(replacements, value, value)
  end

  defp maybe_replace_ip(_type, value, _replacements), do: value

  defp restore_ftp_account(domain, item) do
    existing =
      domain
      |> Hosting.list_ftp_accounts()
      |> Enum.any?(&(&1.username == item.login))

    if existing do
      :skipped
    else
      password = generate_random_password()

      case Hosting.create_ftp_account(domain, %{
             username: item.login,
             password: password,
             home_dir: "/"
           }) do
        {:ok, _} -> :created
        {:error, cs} -> {:failed, "#{item.login}: #{changeset_error_summary(cs)}"}
      end
    end
  end

  defp generate_random_password do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  defp normalize_string(value) when is_binary(value), do: String.trim(value)
  defp normalize_string(_), do: ""

  defp normalize_db_type(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "postgresql" -> "postgresql"
      "postgres" -> "postgresql"
      "pgsql" -> "postgresql"
      "" -> "mysql"
      other -> other
    end
  end

  defp normalize_db_type(_), do: "mysql"

  defp expand_tilde_path("~" <> rest), do: Path.expand("~" <> rest)
  defp expand_tilde_path(path), do: path

  @doc false
  def domains_from_object_index_content(content) when is_binary(content) do
    content
    |> subscriptions_from_object_index_content()
    |> Enum.map(& &1.domain)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc false
  def subscriptions_from_object_index_content(content) when is_binary(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, "\t", trim: false) do
        ["subscription", domain, _guid, owner_login, owner_type, system_user | _rest]
        when is_binary(domain) and domain != "" ->
          [
            %{
              domain: domain,
              owner_login: normalize_blank(owner_login),
              owner_type: normalize_blank(owner_type),
              owner_name: nil,
              owner_email: nil,
              system_user: normalize_blank(system_user)
            }
          ]

        ["subscription", domain | _rest] when is_binary(domain) and domain != "" ->
          [
            %{
              domain: domain,
              owner_login: nil,
              owner_type: nil,
              owner_name: nil,
              owner_email: nil,
              system_user: nil
            }
          ]

        _ ->
          []
      end
    end)
    |> Enum.uniq_by(& &1.domain)
    |> Enum.sort_by(& &1.domain)
  end

  @doc false
  def domains_from_xml_content(content) when is_binary(content) do
    @domain_info_regex
    |> Regex.scan(content, capture: :all_but_first)
    |> Enum.map(fn [domain] -> domain end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc false
  def domain_names_from_api_response(body) do
    body
    |> extract_api_domain_items()
    |> Enum.flat_map(fn item ->
      case item do
        %{"name" => name} when is_binary(name) and name != "" -> [name]
        %{name: name} when is_binary(name) and name != "" -> [name]
        _ -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp from_root_backup_info_xml_subscriptions(backup_path) do
    backup_info_path =
      Path.wildcard(Path.join(backup_path, "backup_info_*.xml"))
      |> Enum.sort()
      |> List.first()

    if is_nil(backup_info_path) do
      {:error,
       "Could not find any .discovered object_index or root backup_info_*.xml in #{backup_path}."}
    else
      with {:ok, content} <- File.read(backup_info_path) do
        names = domains_from_xml_content(content)

        subscriptions =
          names
          |> Enum.map(fn domain ->
            %{
              domain: domain,
              owner_login: nil,
              owner_type: nil,
              owner_name: nil,
              owner_email: nil,
              system_user: nil
            }
          end)

        if names == [] do
          {:error, "No <domain-info> entries were found in #{backup_info_path}."}
        else
          {:ok, subscriptions}
        end
      else
        {:error, reason} ->
          {:error, "Unable to read #{backup_info_path}: #{inspect(reason)}"}
      end
    end
  end

  defp object_index_paths(backup_path) do
    Path.wildcard(Path.join([backup_path, ".discovered", "*", "object_index"]))
  end

  defp ensure_directory(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, _} -> {:error, "#{path} is not a directory."}
      {:error, reason} -> {:error, "Cannot access #{path}: #{inspect(reason)}"}
    end
  end

  defp normalize_api_url(url) do
    url
    |> String.trim()
    |> String.trim_trailing("/")
  end

  defp auth_headers(auth_opts) do
    api_key = Keyword.get(auth_opts, :api_key)
    username = Keyword.get(auth_opts, :username)
    password = Keyword.get(auth_opts, :password)

    cond do
      is_binary(api_key) and api_key != "" ->
        [{"x-api-key", api_key}]

      is_binary(username) and username != "" and is_binary(password) and password != "" ->
        token = Base.encode64("#{username}:#{password}")
        [{"authorization", "Basic " <> token}]

      true ->
        []
    end
  end

  defp extract_api_domain_items(body) when is_list(body), do: body

  defp extract_api_domain_items(body) when is_map(body) do
    cond do
      is_list(body["data"]) -> body["data"]
      is_list(body[:data]) -> body[:data]
      is_list(body["domains"]) -> body["domains"]
      is_list(body[:domains]) -> body[:domains]
      is_list(body["result"]) -> body["result"]
      is_list(body[:result]) -> body[:result]
      true -> []
    end
  end

  defp extract_api_domain_items(_), do: []

  defp normalize_blank(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_blank(_), do: nil

  defp changeset_error_summary(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.flat_map(fn {field, messages} ->
      Enum.map(messages, fn message -> "#{field} #{message}" end)
    end)
    |> case do
      [] -> "unknown validation error"
      messages -> Enum.join(messages, "; ")
    end
  end
end
