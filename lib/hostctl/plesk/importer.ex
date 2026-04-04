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
    server_credentials = Keyword.get(opts, :server_credentials)
    domain_name = subscription.domain

    restore_opts = %{
      ssh_opts: ssh_opts,
      web_files_path: web_files_path,
      progress_pid: progress_pid,
      server_credentials: server_credentials
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
        ssh_opts = Map.get(restore_opts, :ssh_opts)
        has_server_creds = Map.get(restore_opts, :server_credentials) != nil

        # Download a per-domain backup when we need SQL dumps or credentials.
        # Even when server-wide credentials were pre-fetched, we still
        # download a per-domain backup for mail_accounts because the server
        # backup may not include plaintext mail passwords (depends on Plesk's
        # plain_backups setting and exclusion flags).
        needs_backup =
          ssh_opts != nil and
            Enum.any?(categories, &(&1 in ~w(databases db_users mail_accounts)))

        {restore_opts, extract_dir} =
          if needs_backup do
            case download_plesk_db_backup(domain_name, ssh_opts) do
              {:ok, dir} ->
                opts = Map.put(restore_opts, :backup_extract_dir, dir)

                # Always parse per-domain credentials. When server-wide
                # credentials were downloaded, merge them so per-domain
                # passwords fill in any gaps (e.g. mail passwords that the
                # server backup didn't include as plaintext).
                domain_credentials = parse_backup_credentials(dir)

                opts =
                  if has_server_creds do
                    merged =
                      merge_credentials(restore_opts.server_credentials, domain_credentials)

                    Map.put(opts, :backup_credentials, merged)
                  else
                    Map.put(opts, :backup_credentials, domain_credentials)
                  end

                {opts, dir}

              {:error, reason} ->
                Logger.warning(
                  "[Importer] Backup download failed for #{domain_name}: #{reason}. " <>
                    "SQL dump import will be skipped."
                )

                # Even without SQL dumps, server-wide credentials can still
                # be used for db_users/mail_accounts
                opts =
                  if has_server_creds do
                    Map.put_new(
                      restore_opts,
                      :backup_credentials,
                      restore_opts.server_credentials
                    )
                  else
                    restore_opts
                  end

                {opts, nil}
            end
          else
            # No per-domain backup needed — apply server credentials if available
            opts =
              if has_server_creds do
                Map.put_new(restore_opts, :backup_credentials, restore_opts.server_credentials)
              else
                restore_opts
              end

            {opts, nil}
          end

        category_results =
          categories
          |> Enum.with_index(1)
          |> Enum.reduce(%{}, fn {category, index}, acc ->
            notify_progress(progress_pid, domain_name, category, index, total, :in_progress)
            cat_result = restore_category(category, domain, subscription, inventory, restore_opts)
            notify_progress(progress_pid, domain_name, category, index, total, cat_result)
            Map.put(acc, category, cat_result)
          end)

        # Clean up the pre-downloaded backup
        if extract_dir, do: File.rm_rf(extract_dir)

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

    # Find the parent domain web_files item (the one matching our domain name).
    # Subdomain WEB entries also exist in inventory but are filtered by
    # filter_inventory_for_domain to only include the parent domain.
    parent_item = Enum.find(all_items, fn item -> item.domain == domain.name end)
    subdomains = Map.get(subscription, :subdomains, [])

    cond do
      is_nil(ssh_opts) ->
        if parent_item == nil and all_items == [] do
          %{created: 0, skipped: 0, failed: 0, errors: []}
        else
          %{
            created: 0,
            skipped: 0,
            failed: 1,
            errors: ["SSH connection details required to transfer web files"],
            note: "Provide SSH credentials to enable web files rsync"
          }
        end

      is_nil(web_files_path) || web_files_path == "" ->
        %{
          created: 0,
          skipped: 0,
          failed: 1,
          errors: ["No destination path specified for web files"],
          note: "Set a destination path for web files"
        }

      true ->
        # When no web_files entry exists in inventory, build a synthetic item
        # using the default Plesk path so we still attempt to rsync.
        item =
          parent_item ||
            List.first(all_items) ||
            %{domain: domain.name, system_user: nil, document_root: nil}

        restore_web_files_restructured(domain, item, subdomains, ssh_opts, web_files_path)
    end
  end

  defp restore_category("mail_accounts", domain, _subscription, inventory, restore_opts) do
    accounts = Map.get(inventory, "mail_accounts", [])
    mail_passwords = get_in(restore_opts, [:backup_credentials, :mail_passwords]) || %{}

    Logger.info(
      "[Importer] Restoring #{length(accounts)} mail account(s) for #{domain.name}, " <>
        "#{map_size(mail_passwords)} password(s) available (keys: #{inspect(Map.keys(mail_passwords))})"
    )

    do_restore_items(accounts, fn item -> restore_mail_account(domain, item, mail_passwords) end)
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
    extract_dir = Map.get(restore_opts, :backup_extract_dir)

    if ssh_opts != nil and dbs != [] do
      restore_databases_via_pleskbackup(domain, dbs, ssh_opts, extract_dir)
    else
      do_restore_items(dbs, fn item -> restore_database(domain, item) end)
    end
  end

  defp restore_category("db_users", domain, _subscription, inventory, restore_opts) do
    users = Map.get(inventory, "db_users", [])
    db_passwords = get_in(restore_opts, [:backup_credentials, :db_passwords]) || %{}
    do_restore_items(users, fn item -> restore_db_user(domain, item, db_passwords) end)
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

  defp restore_mail_account(domain, item, mail_passwords) do
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
      # Use the original password from the backup XML when available.
      # Fall back to a random password when the backup password is empty
      # or too short for our validation (min 8 chars).
      # Try both local-part ("info") and full-email ("info@example.com")
      # keys since Plesk XML format varies between backup types.
      backup_password =
        Map.get(mail_passwords, username) ||
          Map.get(mail_passwords, item.address)

      password =
        if is_binary(backup_password) and String.length(backup_password) >= 8 do
          Logger.info("[Importer] Using Plesk password for mail account #{item.address}")
          backup_password
        else
          Logger.info(
            "[Importer] No suitable Plesk password for #{item.address} " <>
              "(found: #{inspect(is_binary(backup_password) && String.length(backup_password))}), using random"
          )

          generate_random_password()
        end

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

  @plesk_docroot_dirs ~w(httpdocs htdocs public public_html)

  defp restore_web_files_restructured(domain, item, subdomains, ssh_opts, local_base_path) do
    # Plesk groups all domains for a system user under one home directory.
    # Example: megaplushie has home /var/www/vhosts/bakalair.com, so omgwtf.moe
    # lives at /var/www/vhosts/bakalair.com/omgwtf.moe/ with its subdomains
    # alongside it (mimi.omgwtf.moe/, toast.omgwtf.moe/, etc.).
    #
    # We restructure into our flat layout:
    #   /var/www/{domain}/httpdocs/     ← domain document root
    #   /var/www/{domain}/{sub}.{domain}/ ← each subdomain directory
    #
    # Strategy:
    #   1) Determine the remote "home dir" that contains this domain's files
    #   2) Rsync the docroot dir → local httpdocs/
    #   3) For each subdomain, rsync its dir → local {sub}.{domain}/

    domain_name = domain.name

    # Determine the remote document root and home directory.
    # document_root examples:
    #   /var/www/vhosts/bakalair.com/httpdocs         → primary domain
    #   /var/www/vhosts/bakalair.com/omgwtf.moe       → additional domain (no docroot subdir)
    #   /var/www/vhosts/bakalair.com/omgwtf.moe/httpdocs → additional domain with docroot subdir
    {remote_docroot, remote_home_dir} =
      if is_binary(item.document_root) and item.document_root != "" do
        docroot = item.document_root
        basename = Path.basename(docroot)

        if basename in @plesk_docroot_dirs do
          # e.g. /var/www/vhosts/bakalair.com/httpdocs → home is parent
          {docroot, Path.dirname(docroot)}
        else
          # e.g. /var/www/vhosts/bakalair.com/omgwtf.moe → docroot IS the dir
          # Check inside for httpdocs/
          {docroot, Path.dirname(docroot)}
        end
      else
        home = "/var/www/vhosts/#{domain_name}"
        {home <> "/httpdocs", home}
      end

    Logger.info(
      "[Importer] web_files #{domain_name}: " <>
        "docroot=#{remote_docroot}, home_dir=#{remote_home_dir}, " <>
        "subdomains=#{length(subdomains)}"
    )

    errors = []

    # 1) Rsync the domain's document root → local httpdocs/
    local_httpdocs = Path.join(local_base_path, "httpdocs")

    errors =
      case ensure_local_directory(local_httpdocs) do
        :ok ->
          case do_rsync(ssh_opts, remote_docroot, local_httpdocs,
                 timeout: 3600,
                 excludes: @plesk_rsync_excludes,
                 chown: "www-data:www-data"
               ) do
            :ok ->
              Logger.info("[Importer] web_files #{domain_name}: docroot synced")
              errors

            {:error, reason} ->
              ["#{domain_name} docroot: rsync failed - #{reason}" | errors]
          end

        {:error, reason} ->
          ["#{domain_name} docroot: #{reason}" | errors]
      end

    # 2) Rsync each subdomain directory
    errors =
      Enum.reduce(subdomains, errors, fn sub, acc ->
        sub_dir_name = "#{sub.name}.#{domain_name}"
        remote_sub = "#{remote_home_dir}/#{sub_dir_name}"
        local_sub = Path.join(local_base_path, sub_dir_name)

        case ensure_local_directory(local_sub) do
          :ok ->
            case do_rsync(ssh_opts, remote_sub, local_sub,
                   timeout: 3600,
                   excludes: @plesk_rsync_excludes,
                   chown: "www-data:www-data"
                 ) do
              :ok ->
                Logger.info(
                  "[Importer] web_files #{domain_name}: subdomain #{sub.full_name} synced"
                )

                acc

              {:error, reason} ->
                ["#{sub.full_name}: rsync failed - #{reason}" | acc]
            end

          {:error, reason} ->
            ["#{sub.full_name}: #{reason}" | acc]
        end
      end)

    errors = Enum.reverse(errors)
    total = 1 + length(subdomains)
    failed = length(errors)

    %{
      created: total - failed,
      skipped: 0,
      failed: failed,
      errors: errors
    }
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

  defp restore_databases_via_pleskbackup(domain, dbs, ssh_opts, extract_dir) do
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
        restore_mysql_databases_via_pleskbackup(domain, mysql_dbs, ssh_opts, extract_dir)
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

  defp restore_mysql_databases_via_pleskbackup(domain, dbs, ssh_opts, pre_extract_dir) do
    # Step 1: Create all database entries in hostctl
    db_statuses =
      Enum.map(dbs, fn item ->
        {item, restore_database(domain, item)}
      end)

    # Step 2: Use pre-downloaded backup dir if available, otherwise download now
    {extract_dir, should_cleanup} =
      if pre_extract_dir != nil and File.exists?(pre_extract_dir) do
        {pre_extract_dir, false}
      else
        case download_plesk_db_backup(domain.name, ssh_opts) do
          {:ok, dir} -> {dir, true}
          {:error, _} = err -> {err, false}
        end
      end

    case extract_dir do
      {:error, reason} ->
        results =
          Enum.map(db_statuses, fn
            {_item, {:failed, _} = status} -> status
            {item, :created} -> {:failed, "#{item.name}: created but backup failed - #{reason}"}
            {item, _} -> {:failed, "#{item.name}: backup failed - #{reason}"}
          end)

        tally_restore_results(results)

      dir when is_binary(dir) ->
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

        if should_cleanup, do: File.rm_rf(dir)
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

  # ---------------------------------------------------------------------------
  # PostgreSQL: pg_dump via sudo -u postgres over SSH
  # ---------------------------------------------------------------------------
  # pleskbackup doesn't include PostgreSQL dumps. We run pg_dump on the
  # remote as the `postgres` system user (peer auth via Unix socket) which
  # has superuser access to all databases. We query Plesk for the correct
  # PG port since Plesk may run PostgreSQL on a non-default port/cluster.
  # ---------------------------------------------------------------------------

  defp restore_pg_databases_via_ssh(domain, dbs, ssh_opts) do
    # Get the PG server connection info from Plesk's DatabaseServers table.
    # Plesk may host PG on a separate server (different IP from the Plesk box).
    pg_creds = get_plesk_pg_credentials(ssh_opts)

    Logger.info(
      "[Importer] Plesk PG server: host=#{pg_creds.host}, port=#{pg_creds.port}, " <>
        "admin=#{pg_creds.admin_login}, password=#{if pg_creds.admin_password != "", do: "(set)", else: "(empty)"}"
    )

    results =
      Enum.map(dbs, fn item ->
        create_status = restore_database(domain, item)

        case create_status do
          {:failed, _} = status ->
            status

          _ ->
            plesk_domain = Map.get(item, :domain) || Map.get(item, "domain")

            case dump_pg_database_via_ssh(item.name, plesk_domain, ssh_opts, pg_creds) do
              {:ok, local_dir, dump_file} ->
                result = import_sql_file(dump_file, item.name, "postgresql")
                File.rm_rf(local_dir)

                case result do
                  :ok ->
                    :created

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

  defp get_plesk_pg_credentials(ssh_opts) do
    sudo = sudo_prefix(ssh_opts)

    # Query Plesk's internal MySQL DB for the PostgreSQL server connection info.
    # The DatabaseServers table contains host, port, admin_login, admin_password
    # for each database server type (mysql, postgresql).
    query_cmd =
      "#{sudo}plesk db " <>
        "-Ne \"SELECT host, port, admin_login, admin_password " <>
        "FROM DatabaseServers WHERE type='postgresql' LIMIT 1\" 2>/dev/null"

    creds =
      case ssh_exec_output(ssh_opts, query_cmd) do
        {:ok, output} ->
          trimmed = String.trim(output)

          case String.split(trimmed, "\t", parts: 4) do
            [host, port_str, admin_login, admin_password] ->
              port =
                case Integer.parse(port_str) do
                  {p, _} -> p
                  :error -> 5432
                end

              %{
                host: String.trim(host),
                port: port,
                admin_login: String.trim(admin_login),
                admin_password: String.trim(admin_password)
              }

            _ ->
              Logger.warning(
                "[Importer] Could not parse PG credentials from DatabaseServers: #{inspect(trimmed)}"
              )

              nil
          end

        _ ->
          nil
      end

    # If we got credentials with a password, use them
    if creds && creds.admin_password != "" do
      creds
    else
      # Fallback: try reading PG admin password from /etc/psa/private/pgsql.passwd
      passwd =
        case ssh_exec_output(ssh_opts, "#{sudo}cat /etc/psa/private/pgsql.passwd 2>/dev/null") do
          {:ok, output} -> String.trim(output)
          _ -> ""
        end

      base =
        creds ||
          %{host: "localhost", port: 5432, admin_login: "postgres", admin_password: ""}

      if passwd != "" do
        Logger.info("[Importer] Using PG password from /etc/psa/private/pgsql.passwd")
        %{base | admin_password: passwd}
      else
        Logger.warning("[Importer] No PG admin password found — pg_dump may fail")
        base
      end
    end
  end

  defp dump_pg_database_via_ssh(db_name, plesk_domain, ssh_opts, pg_creds) do
    rand =
      :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false) |> String.slice(0, 8)

    remote_dump = "/tmp/hostctl_pgdump_#{rand}.sql"
    local_dir = Path.join(System.tmp_dir!(), "hostctl_pgdump_#{rand}")
    local_dump = Path.join(local_dir, "#{db_name}.sql")

    File.mkdir_p!(local_dir)

    # Locate pg_dump on the remote
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

    escaped_pg_dump = shell_escape(pg_dump_bin)
    escaped_db = shell_escape(db_name)
    escaped_out = shell_escape(remote_dump)
    remote_err = "/tmp/hostctl_pgdump_err_#{rand}.log"
    escaped_err = shell_escape(remote_err)

    # Strategy: Create a temporary Plesk DB user with superuser-like access,
    # pg_dump with PGPASSWORD, then remove the temp user. Plesk manages
    # pg_hba.conf so users it creates can authenticate via md5/scram.
    result =
      case create_plesk_temp_pg_user(ssh_opts, db_name, plesk_domain, pg_creds, rand) do
        {:ok, tmp_user, tmp_pass} ->
          Logger.info(
            "[Importer] Dumping PG DB '#{db_name}' with Plesk temp user '#{tmp_user}' " <>
              "(host=#{pg_creds.host}, port=#{pg_creds.port})"
          )

          dump_result =
            do_pg_dump_tcp(
              ssh_opts,
              pg_creds.host,
              pg_creds.port,
              tmp_user,
              tmp_pass,
              db_name,
              escaped_pg_dump,
              escaped_db,
              escaped_out,
              escaped_err
            )

          # Always clean up the temp user
          remove_plesk_temp_pg_user(ssh_opts, tmp_user)

          dump_result

        {:error, reason} ->
          Logger.warning(
            "[Importer] Could not create Plesk temp PG user: #{reason}. " <>
              "Trying admin credentials..."
          )

          # Fallback: try with admin credentials from DatabaseServers
          do_pg_dump_tcp(
            ssh_opts,
            pg_creds.host,
            pg_creds.port,
            pg_creds.admin_login,
            pg_creds.admin_password,
            db_name,
            escaped_pg_dump,
            escaped_db,
            escaped_out,
            escaped_err
          )
      end

    case result do
      {:ok, _output} ->
        case scp_download(ssh_opts, remote_dump, local_dump) do
          :ok ->
            ssh_exec(ssh_opts, "rm -f #{escaped_out}")
            validate_pg_dump(local_dir, local_dump, db_name)

          {:error, reason} ->
            File.rm_rf(local_dir)
            ssh_exec(ssh_opts, "rm -f #{escaped_out}")
            {:error, "SCP download failed: #{reason}"}
        end

      {:error, reason} ->
        File.rm_rf(local_dir)
        ssh_exec(ssh_opts, "rm -f #{escaped_out}")
        {:error, reason}
    end
  end

  defp create_plesk_temp_pg_user(ssh_opts, db_name, plesk_domain, pg_creds, rand) do
    sudo = sudo_prefix(ssh_opts)
    tmp_user = "hostctl_tmp_#{rand}"
    tmp_pass = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
    escaped_db = String.replace(db_name, "'", "'\\''")
    escaped_pass = String.replace(tmp_pass, "'", "'\\''")
    escaped_domain = String.replace(plesk_domain || "", "'", "'\\''")
    server_spec = "#{pg_creds.host}:#{pg_creds.port}"

    Logger.info(
      "[Importer] Creating Plesk temp PG user '#{tmp_user}' " <>
        "for DB '#{db_name}' (domain=#{plesk_domain}, server=#{server_spec})"
    )

    # Create a Plesk DB user bound to the specific database and domain.
    # Plesk manages pg_hba.conf for users it creates, so they can auth via md5.
    create_cmd =
      "#{sudo}plesk bin database --create-dbuser " <>
        "'#{tmp_user}' " <>
        "-passwd '#{escaped_pass}' " <>
        "-type postgresql " <>
        "-domain '#{escaped_domain}' " <>
        "-server #{server_spec} " <>
        "-database '#{escaped_db}' " <>
        "-all-databases 2>&1"

    case ssh_exec_output(ssh_opts, create_cmd) do
      {:ok, output} ->
        Logger.info("[Importer] Plesk temp user created: #{String.trim(output)}")
        {:ok, tmp_user, tmp_pass}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp remove_plesk_temp_pg_user(ssh_opts, tmp_user) do
    sudo = sudo_prefix(ssh_opts)

    remove_cmd =
      "#{sudo}plesk bin database --remove-dbuser '#{tmp_user}' -type postgresql 2>&1"

    case ssh_exec_output(ssh_opts, remove_cmd) do
      {:ok, _} ->
        Logger.info("[Importer] Removed Plesk temp PG user '#{tmp_user}'")

      {:error, reason} ->
        Logger.warning("[Importer] Failed to remove temp PG user '#{tmp_user}': #{reason}")
    end
  end

  # Run pg_dump via TCP with explicit credentials
  defp do_pg_dump_tcp(
         ssh_opts,
         host,
         port,
         username,
         password,
         db_name,
         escaped_pg_dump,
         escaped_db,
         escaped_out,
         escaped_err
       ) do
    # Force 127.0.0.1 for localhost to guarantee TCP (avoid Unix socket ident auth)
    tcp_host = if host in ["localhost", "localhost.localdomain"], do: "127.0.0.1", else: host
    escaped_host = shell_escape(tcp_host)
    escaped_user = shell_escape(username)
    escaped_pg_pass = shell_escape(password)

    Logger.info(
      "[Importer] pg_dump '#{db_name}' via TCP (host=#{host}, port=#{port}, user=#{username})"
    )

    dump_cmd =
      "cd /tmp && " <>
        "PGPASSWORD=#{escaped_pg_pass} " <>
        "#{escaped_pg_dump} --no-owner --no-acl " <>
        "-h #{escaped_host} -p #{port} -U #{escaped_user} " <>
        "#{escaped_db} > #{escaped_out} 2>#{escaped_err}; " <>
        "RC=$?; " <>
        "ERR=$(cat #{escaped_err} 2>/dev/null); rm -f #{escaped_err}; " <>
        "if [ $RC -ne 0 ]; then echo \"$ERR\" >&2; exit $RC; fi"

    ssh_exec_output(ssh_opts, dump_cmd)
  end

  defp validate_pg_dump(local_dir, local_dump, db_name) do
    case File.stat(local_dump) do
      {:ok, %{size: size}} when size > 100 ->
        # Log the first few lines for diagnostics
        head =
          case File.open(local_dump, [:read, :utf8]) do
            {:ok, file} ->
              lines =
                Enum.reduce_while(1..15, [], fn _, acc ->
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
          Logger.warning(
            "[Importer] PG dump for '#{db_name}' has no CREATE TABLE or COPY statements"
          )

          {:ok, local_dir, local_dump}
        end

      {:ok, %{size: size}} ->
        Logger.warning("[Importer] PG dump for '#{db_name}' is suspiciously small: #{size} bytes")

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

  @doc """
  Downloads a server-wide config-only backup from a remote Plesk server.

  Runs `pleskbackup --server -include-server-settings` with all content
  excluded (files, mail, logs, databases) so only configuration/credentials
  are captured. The backup is downloaded, extracted, and all credentials are
  parsed from every `backup_info_*.xml` across domains, resellers, and clients.

  Returns `{:ok, credentials}` where credentials is a map with keys:
    - `:db_passwords`   — `%{{db_name, username} => password}`
    - `:mail_passwords` — `%{email_username => password}`
    - `:sysuser_passwords` — `%{system_username => password}`
  """
  def download_plesk_server_config_backup(ssh_opts) do
    rand = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false) |> String.slice(0, 8)
    remote_tar = "/tmp/hostctl_serverconf_#{rand}.tar"
    local_dir = Path.join(System.tmp_dir!(), "hostctl_serverconf_#{rand}")
    local_tar = Path.join(local_dir, "backup.tar")

    File.mkdir_p!(local_dir)

    sudo_prefix = sudo_prefix(ssh_opts)

    backup_cmd =
      "#{sudo_prefix}plesk bin pleskbackup --server" <>
        " -include-server-settings" <>
        " -exclude-files -exclude-mail -exclude-logs -exclude-databases" <>
        " -output-file #{shell_escape(remote_tar)}"

    with :ok <- ssh_exec(ssh_opts, backup_cmd),
         :ok <- scp_download(ssh_opts, remote_tar, local_tar),
         _ <- ssh_exec(ssh_opts, "rm -f #{shell_escape(remote_tar)}"),
         :ok <- extract_backup_archives(local_dir) do
      credentials = parse_backup_credentials(local_dir)
      File.rm_rf(local_dir)
      {:ok, credentials}
    else
      {:error, reason} ->
        File.rm_rf(local_dir)
        ssh_exec(ssh_opts, "rm -f #{shell_escape(remote_tar)}")
        {:error, reason}
    end
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
      "echo #{shell_escape(password)} | sudo -S -p '' "
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
        "printf \"#!/bin/sh\\necho " <>
        "'\"'\"'" <>
        escaped <>
        "'\"'\"'" <>
        "\\n\" > $AP; " <>
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

  # ---------------------------------------------------------------------------
  # Backup credential extraction
  # ---------------------------------------------------------------------------
  # Plesk backup_info_*.xml files contain plaintext passwords for database
  # users (inside <dbuser>) and email accounts (inside <mailuser>).
  # We parse these so we can preserve the original passwords during import.
  # ---------------------------------------------------------------------------

  @doc false
  def parse_backup_credentials(extract_dir) do
    xml_files =
      Path.wildcard("#{extract_dir}/**/backup_info_*.xml") ++
        Path.wildcard("#{extract_dir}/**/dump.xml")

    Logger.info(
      "[Importer] Found #{length(xml_files)} XML file(s) for credential extraction: #{inspect(Enum.map(xml_files, &Path.relative_to(&1, extract_dir)))}"
    )

    credentials =
      Enum.reduce(
        xml_files,
        %{db_passwords: %{}, mail_passwords: %{}, sysuser_passwords: %{}, client_passwords: %{}},
        fn xml_file, acc ->
          case File.read(xml_file) do
            {:ok, content} ->
              creds = extract_credentials_from_xml(content)

              Logger.info(
                "[Importer] #{Path.relative_to(xml_file, extract_dir)}: " <>
                  "#{map_size(creds.db_passwords)} DB, " <>
                  "#{map_size(creds.mail_passwords)} mail, " <>
                  "#{map_size(creds.sysuser_passwords)} sysuser, " <>
                  "#{map_size(creds.client_passwords)} client/reseller password(s)"
              )

              merge_credentials(acc, creds)

            {:error, _} ->
              acc
          end
        end
      )

    Logger.info(
      "[Importer] Parsed backup credentials: " <>
        "#{map_size(credentials.db_passwords)} DB user(s), " <>
        "#{map_size(credentials.mail_passwords)} mail account(s), " <>
        "#{map_size(credentials.sysuser_passwords)} system user(s), " <>
        "#{map_size(credentials.client_passwords)} client/reseller(s)"
    )

    credentials
  end

  defp extract_credentials_from_xml(content) do
    db_passwords = extract_db_passwords(content)
    mail_passwords = extract_mail_passwords(content)
    sysuser_passwords = extract_sysuser_passwords(content)
    client_passwords = extract_client_passwords(content)

    # Count total password elements vs plain-text for diagnostics
    total_mail_users = length(Regex.scan(~r/<mailuser\s/, content))
    total_sys_users = length(Regex.scan(~r/<sysuser\s/, content))

    if total_mail_users > map_size(mail_passwords) or
         total_sys_users > map_size(sysuser_passwords) do
      Logger.warning(
        "[Importer] Some passwords may be hashed (not type=\"plain\") in backup XML. " <>
          "Mail: #{map_size(mail_passwords)}/#{total_mail_users} plain, " <>
          "Sysuser: #{map_size(sysuser_passwords)}/#{total_sys_users} plain. " <>
          "Run 'plesk bin server_pref --update -plain-backups true' on the " <>
          "Plesk server to include plaintext passwords in backups."
      )
    end

    %{
      db_passwords: db_passwords,
      mail_passwords: mail_passwords,
      sysuser_passwords: sysuser_passwords,
      client_passwords: client_passwords
    }
  end

  # Extract DB user passwords from <database>...<dbuser> elements
  # Structure: <database name="dbname" type="mysql|postgresql">
  #              <dbuser name="username">
  #                <password type="plain">thepassword</password>
  #              </dbuser>
  #            </database>
  defp extract_db_passwords(content) do
    # Match each <database ...>...</database> block
    ~r/<database\s[^>]*name="([^"]+)"[^>]*>(.+?)<\/database>/s
    |> Regex.scan(content)
    |> Enum.flat_map(fn [_full, db_name, db_block] ->
      # Find all <dbuser> entries within this database block
      ~r/<dbuser\s[^>]*name="([^"]+)"[^>]*>(.+?)<\/dbuser>/s
      |> Regex.scan(db_block)
      |> Enum.flat_map(fn [_full, user_name, user_block] ->
        case extract_plain_password(user_block) do
          nil -> []
          password -> [{{db_name, user_name}, password}]
        end
      end)
    end)
    |> Map.new()
  end

  # Extract mail user passwords from <mailuser> elements
  # Structure: <mailuser name="username" ...>
  #              <properties>
  #                <password type="plain">thepassword</password>
  #              </properties>
  #            </mailuser>
  defp extract_mail_passwords(content) do
    ~r/<mailuser\s[^>]*name="([^"]+)"[^>]*>(.+?)<\/mailuser>/s
    |> Regex.scan(content)
    |> Enum.flat_map(fn [_full, username, user_block] ->
      case extract_plain_password(user_block) do
        nil -> []
        password -> [{username, password}]
      end
    end)
    |> Map.new()
  end

  # Extract system user passwords from <sysuser> elements
  # Structure: <sysuser name="username" quota="0" shell="/bin/false">
  #              <password type="plain">thepassword</password>
  #            </sysuser>
  defp extract_sysuser_passwords(content) do
    ~r/<sysuser\s[^>]*name="([^"]+)"[^>]*>(.+?)<\/sysuser>/s
    |> Regex.scan(content)
    |> Enum.flat_map(fn [_full, username, user_block] ->
      case extract_plain_password(user_block) do
        nil -> []
        password -> [{username, password}]
      end
    end)
    |> Map.new()
  end

  # Extract client/reseller passwords from <client> and <reseller> elements.
  # In Plesk server backups, each client/reseller has its own password:
  #   <client name="clientlogin" ...>
  #     <password type="plain">thepassword</password>
  #     ...
  #   </client>
  # These are keyed by the client/reseller login name which corresponds
  # to the subscription's owner_login field from the SSH probe.
  defp extract_client_passwords(content) do
    clients =
      ~r/<client\s[^>]*name="([^"]+)"[^>]*>(.+?)<\/client>/s
      |> Regex.scan(content)
      |> Enum.flat_map(fn [_full, name, block] ->
        case extract_plain_password(block) do
          nil -> []
          password -> [{name, password}]
        end
      end)

    resellers =
      ~r/<reseller\s[^>]*name="([^"]+)"[^>]*>(.+?)<\/reseller>/s
      |> Regex.scan(content)
      |> Enum.flat_map(fn [_full, name, block] ->
        case extract_plain_password(block) do
          nil -> []
          password -> [{name, password}]
        end
      end)

    Map.new(clients ++ resellers)
  end

  # Extract a plaintext password from an XML block.
  # Prefers <password type="plain">, falls back to untyped <password>.
  # Skips hashed passwords (type="crypt", type="sym", etc.) to avoid
  # double-hashing when the password is later bcrypt-hashed on our side.
  defp extract_plain_password(block) do
    cond do
      match = Regex.run(~r/<password[^>]*type="plain"[^>]*>([^<]+)<\/password>/, block) ->
        Enum.at(match, 1)

      match = Regex.run(~r/<password>([^<]+)<\/password>/, block) ->
        Enum.at(match, 1)

      true ->
        nil
    end
  end

  defp merge_credentials(acc, new) do
    %{
      db_passwords: Map.merge(acc.db_passwords, new.db_passwords),
      mail_passwords: Map.merge(acc.mail_passwords, new.mail_passwords),
      sysuser_passwords:
        Map.merge(Map.get(acc, :sysuser_passwords, %{}), Map.get(new, :sysuser_passwords, %{})),
      client_passwords:
        Map.merge(Map.get(acc, :client_passwords, %{}), Map.get(new, :client_passwords, %{}))
    }
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
            System.cmd(
              "/bin/sh",
              [
                "-c",
                "zstd -d -c #{shell_escape(tar_path)} | tar xf - -C #{shell_escape(dest_dir)}"
              ], stderr_to_stdout: true)
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
          String.ends_with?(dump_file, ".gz") ->
            "zcat"

          String.ends_with?(dump_file, ".zst") or String.ends_with?(dump_file, ".tzst") ->
            "zstd -d -c"

          true ->
            "cat"
        end

      full_cmd = "#{cat_cmd} #{shell_escape(dump_file)} | #{import_cmd}"

      Logger.info("[Importer] Importing DB dump: #{full_cmd}")

      case System.cmd("/bin/sh", ["-c", full_cmd], stderr_to_stdout: true) do
        {output, 0} ->
          if output != "" do
            Logger.info(
              "[Importer] DB import output for '#{db_name}': #{String.slice(String.trim(output), 0, 2000)}"
            )
          end

          :ok

        {output, code} ->
          Logger.warning(
            "[Importer] DB import failed for '#{db_name}' (exit #{code}): #{String.trim(output)}"
          )

          {:error, String.trim(output)}
      end
    end
  end

  defp restore_db_user(domain, item, db_passwords) do
    databases = Hosting.list_databases(domain)
    target_db = Enum.find(databases, &(&1.name == item.database))

    cond do
      is_nil(target_db) ->
        {:failed, "#{item.login}: database #{item.database} not found"}

      Hosting.list_db_users(target_db) |> Enum.any?(&(&1.username == item.login)) ->
        :skipped

      true ->
        # Use the original password from the backup XML when available.
        # The key is {db_name, username} as parsed from the <database>/<dbuser> XML.
        # Fall back to a random password when the backup password is empty
        # or too short for our validation (min 8 chars).
        backup_password = Map.get(db_passwords, {item.database, item.login})

        password =
          if is_binary(backup_password) and String.length(backup_password) >= 8 do
            backup_password
          else
            generate_random_password()
          end

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
            Logger.info(
              "[Importer] Could not query remote IPs via SSH (#{reason}), falling back to DNS resolution"
            )

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
        Logger.info("[Importer] DNS IP replacements: #{inspect(replacements)}")
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
