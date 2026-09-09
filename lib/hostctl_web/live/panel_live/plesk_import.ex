defmodule HostctlWeb.PanelLive.PleskImport do
  use HostctlWeb, :live_view

  require Logger

  alias Hostctl.Accounts
  alias Hostctl.Accounts.Scope
  alias Hostctl.Hosting
  alias Hostctl.Plesk
  alias Hostctl.Plesk.Importer
  alias Hostctl.Plesk.SSHProbe
  alias Hostctl.Repo

  @data_type_options [
    {"domains", "Domains and subscriptions"},
    {"dns", "DNS zones and records"},
    {"web_files", "Web files and document roots"},
    {"mail_accounts", "Mail accounts and aliases"},
    {"mail_content", "Mailboxes and stored mail"},
    {"databases", "Databases"},
    {"db_users", "Database users and grants"},
    {"cron_jobs", "Cron jobs"},
    {"ftp_accounts", "FTP accounts"},
    {"ssl_certificates", "SSL certificates"},
    {"system_users", "Plesk system users"}
  ]

  @default_data_types Enum.map(@data_type_options, fn {key, _label} -> key end)

  @restore_categories [
    {"web_files", "Web Files", "hero-document-duplicate"},
    {"subdomains", "Subdomains", "hero-rectangle-group"},
    {"dns", "DNS Records", "hero-globe-alt"},
    {"mail_accounts", "Mail Accounts", "hero-envelope"},
    {"mail_content", "Mail Content", "hero-inbox-stack"},
    {"databases", "Databases", "hero-circle-stack"},
    {"db_users", "Database Users", "hero-user-circle"},
    {"cron_jobs", "Cron Jobs", "hero-clock"},
    {"ftp_accounts", "FTP Accounts", "hero-arrow-up-tray"},
    {"ssl_certificates", "SSL Certificates", "hero-lock-closed"}
  ]

  # Categories that are discovered but not yet fully imported — show a warning
  @limited_categories %{
    "cron_jobs" =>
      "Cron jobs are discovered but not yet imported. You will need to recreate them manually.",
    "ssl_certificates" =>
      "SSL certificate names are discovered but certificate content is not imported. Use Let's Encrypt or re-upload certificates manually."
  }

  @restore_category_keys Enum.map(@restore_categories, fn {key, _, _} -> key end)

  @default_params %{
    "source" => "backup",
    "backup_path" => "",
    "owner_login" => "",
    "system_user" => "",
    "api_url" => "",
    "api_key" => "",
    "api_username" => "",
    "api_password" => "",
    "ssh_host" => "",
    "ssh_port" => "22",
    "ssh_username" => "",
    "ssh_auth_method" => "key",
    "ssh_private_key_path" => "",
    "ssh_password" => "",
    "apply_dns_template" => "false",
    "selected_data_types" => @default_data_types
  }

  # ── Mount ──────────────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    # Subscribe to upload job progress
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Hostctl.PubSub, "upload_jobs")
    end

    {:ok,
     socket
     |> assign(:page_title, "Plesk Import")
     |> assign(:active_tab, :panel_plesk_import)
     |> assign(:form_params, @default_params)
     |> assign(:form, to_form(@default_params, as: :import))
     |> assign(:phase, :discovery)
     |> assign(:import_step, "source")
     |> assign(:review_domain, nil)
     |> assign(:discovering, false)
     |> assign(:discover_task_ref, nil)
     |> assign(:ssh_discovery, nil)
     |> assign(:subscriptions, [])
     |> assign(:domain_configs, %{})
     |> assign(:domain_s3_backends, %{})
     |> assign(:s3_connections, Hostctl.S3Connections.list(socket.assigns.current_scope))
     |> assign(:s3_bucket_lists, %{})
     |> assign(:s3_busy, MapSet.new())
     |> assign(:restore_results, %{})
     |> assign(:restore_progress, %{})
     |> assign(:restore_task_refs, %{})
     |> assign(:server_credentials, nil)
     |> assign(:server_creds_task_ref, nil)
     |> assign(:server_creds_loading, false)
     |> assign(:accounts, load_accounts())
     |> assign(:creating_account, false)
     |> assign(:new_account_form, to_form(%{"name" => "", "email" => ""}, as: :account))
     |> assign(:data_type_options, @data_type_options)
     |> assign(:restore_categories, @restore_categories)
     |> assign(:limited_categories, @limited_categories)
     |> assign(:saved_migrations, [])
     |> assign(:show_saved, false)
     |> assign(:ssh_needs_password, false)
     |> assign(:upload_jobs, [])
     |> load_saved_migrations()
     |> load_upload_jobs()}
  end

  # ── Events ─────────────────────────────────────────────────────────────

  @impl true
  def handle_event("validate", %{"import" => params}, socket) do
    params = normalize_form_params(params)

    ssh_needs_password =
      socket.assigns.ssh_needs_password and
        params["ssh_password"] in [nil, ""]

    {:noreply,
     socket
     |> assign(:form_params, params)
     |> assign(:form, to_form(params, as: :import))
     |> assign(:ssh_needs_password, ssh_needs_password)}
  end

  @impl true
  def handle_event("discover", %{"import" => params}, socket) do
    params = normalize_form_params(params)

    socket =
      socket
      |> assign(:form_params, params)
      |> assign(:form, to_form(params, as: :import))

    # Run discovery asynchronously
    task =
      Task.async(fn ->
        run_discovery(params)
      end)

    {:noreply,
     socket
     |> assign(:discovering, true)
     |> assign(:discover_task_ref, task.ref)}
  end

  @impl true
  def handle_event("reset", _params, socket) do
    {:noreply,
     socket
     |> assign(:phase, :discovery)
     |> assign(:import_step, "source")
     |> assign(:review_domain, nil)
     |> assign(:discovering, false)
     |> assign(:discover_task_ref, nil)
     |> assign(:ssh_discovery, nil)
     |> assign(:subscriptions, [])
     |> assign(:domain_configs, %{})
     |> assign(:domain_s3_backends, %{})
     |> assign(:restore_results, %{})
     |> assign(:restore_progress, %{})
     |> assign(:restore_task_refs, %{})
     |> assign(:server_credentials, nil)
     |> assign(:server_creds_task_ref, nil)
     |> assign(:server_creds_loading, false)
     |> assign(:ssh_needs_password, false)}
  end

  @impl true
  def handle_event("toggle_category", %{"domain" => domain, "category" => category}, socket) do
    configs = socket.assigns.domain_configs
    config = Map.get(configs, domain, %{})
    categories = Map.get(config, :categories, MapSet.new())

    categories =
      if MapSet.member?(categories, category),
        do: MapSet.delete(categories, category),
        else: MapSet.put(categories, category)

    config = Map.put(config, :categories, categories)

    {:noreply, assign(socket, :domain_configs, Map.put(configs, domain, config))}
  end

  @impl true
  def handle_event("select_all_categories", %{"domain" => domain}, socket) do
    configs = socket.assigns.domain_configs
    config = Map.get(configs, domain, %{})
    counts = Map.get(config, :inventory_counts, %{})

    categories =
      @restore_category_keys
      |> Enum.filter(fn key -> Map.get(counts, key, 0) > 0 end)
      |> MapSet.new()

    config = Map.put(config, :categories, categories)

    {:noreply, assign(socket, :domain_configs, Map.put(configs, domain, config))}
  end

  @impl true
  def handle_event("deselect_all_categories", %{"domain" => domain}, socket) do
    configs = socket.assigns.domain_configs
    config = Map.get(configs, domain, %{})
    config = Map.put(config, :categories, MapSet.new())

    {:noreply, assign(socket, :domain_configs, Map.put(configs, domain, config))}
  end

  @impl true
  def handle_event("set_account", %{"domain" => domain, "email" => email}, socket) do
    configs = socket.assigns.domain_configs
    config = Map.get(configs, domain, %{})
    config = Map.put(config, :account_email, normalize_string(email))

    {:noreply, assign(socket, :domain_configs, Map.put(configs, domain, config))}
  end

  @impl true
  def handle_event("set_web_path", %{"domain" => domain, "path" => path}, socket) do
    configs = socket.assigns.domain_configs
    config = Map.get(configs, domain, %{})
    config = Map.put(config, :web_files_path, String.trim(path))

    {:noreply, assign(socket, :domain_configs, Map.put(configs, domain, config))}
  end

  def handle_event("set_s3_config", %{"destination" => params}, socket),
    do: handle_event("set_s3_config", params, socket)

  def handle_event("use_s3_connection", %{"connection" => params}, socket) do
    case Hostctl.S3Connections.get(socket.assigns.current_scope, params["id"]) do
      nil ->
        {:noreply, put_flash(socket, :error, "Select one of your saved S3 connections")}

      connection ->
        tc = s3_target(socket, params)

        tc =
          Map.merge(tc, %{
            s3_endpoint: connection.endpoint_url,
            s3_region: connection.region,
            s3_access_key: connection.access_key_id,
            s3_secret_key: connection.secret_access_key
          })

        {:noreply, put_s3_target(socket, params, tc)}
    end
  end

  def handle_event("choose_s3_bucket", %{"selection" => params}, socket) do
    tc = Map.put(s3_target(socket, params), :s3_bucket, params["bucket"])
    {:noreply, put_s3_target(socket, params, tc)}
  end

  def handle_event("save_s3_connection", %{"destination" => params}, socket) do
    {:noreply, socket} = handle_event("set_s3_config", params, socket)
    tc = s3_target(socket, params)

    attrs = %{
      name: params["connection_name"],
      endpoint_url: tc[:s3_endpoint],
      region: tc[:s3_region],
      access_key_id: tc[:s3_access_key],
      secret_access_key: tc[:s3_secret_key]
    }

    case Hostctl.S3Connections.save(socket.assigns.current_scope, attrs) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:s3_connections, Hostctl.S3Connections.list(socket.assigns.current_scope))
         |> put_flash(:info, "S3 connection saved. You can reuse it on another destination.")}

      {:error, cs} ->
        {:noreply, put_flash(socket, :error, changeset_error_summary(cs))}
    end
  end

  def handle_event(event, %{"domain" => _, "target" => _} = params, socket)
      when event in ["list_s3_buckets", "create_s3_bucket"] do
    tc = s3_target(socket, params)
    key = {params["domain"], params["target"]}
    opts = build_s3_backend_opts_from_config(Map.put_new(tc, :s3_bucket, "placeholder"))
    # Bucket listing does not require a bucket name.
    opts =
      opts ||
        %{
          endpoint: tc[:s3_endpoint],
          access_key_id: tc[:s3_access_key],
          secret_access_key: tc[:s3_secret_key],
          region: tc[:s3_region] || "us-east-1"
        }

    if MapSet.member?(socket.assigns.s3_busy, key) do
      {:noreply, socket}
    else
      bucket = tc[:s3_bucket] || ""

      {:noreply,
       socket
       |> assign(:s3_busy, MapSet.put(socket.assigns.s3_busy, key))
       |> start_async({:s3_operation, key}, fn ->
         case event do
           "list_s3_buckets" ->
             Hostctl.S3Client.list_buckets(opts)

           "create_s3_bucket" ->
             case Hostctl.S3Client.create_bucket(opts, bucket) do
               :ok -> {:created, bucket}
               error -> error
             end
         end
       end)}
    end
  end

  @impl true
  def handle_event("set_s3_config", %{"domain" => domain} = params, socket) do
    target = Map.get(params, "target", "")
    configs = socket.assigns.domain_configs
    config = Map.get(configs, domain, %{})
    s3_targets = Map.get(config, :s3_targets, %{})
    target_config = Map.get(s3_targets, target, %{})

    target_config =
      target_config
      |> put_s3_field(:s3_endpoint, params["endpoint"])
      |> put_s3_field(:s3_bucket, params["bucket"])
      |> put_s3_field(:s3_region, params["region"])
      |> put_s3_field(:s3_access_key, params["access_key"])
      |> put_s3_field(:s3_secret_key, params["secret_key"])
      |> put_s3_field(:s3_prefix, params["prefix"])
      |> put_s3_field(:connection_name, params["connection_name"])
      |> put_s3_field(:ftp_enabled, params["ftp_enabled"] == "true")
      |> put_s3_field(:directory_listing, params["directory_listing"] == "true")

    s3_targets = Map.put(s3_targets, target, target_config)
    config = Map.put(config, :s3_targets, s3_targets)
    {:noreply, assign(socket, :domain_configs, Map.put(configs, domain, config))}
  end

  @impl true
  def handle_event("toggle_s3_import", %{"domain" => domain} = params, socket) do
    target = Map.get(params, "target", "")
    configs = socket.assigns.domain_configs
    config = Map.get(configs, domain, %{})
    s3_targets = Map.get(config, :s3_targets, %{})
    target_config = Map.get(s3_targets, target, %{})
    target_config = Map.update(target_config, :s3_import, true, fn current -> not current end)
    s3_targets = Map.put(s3_targets, target, target_config)
    config = Map.put(config, :s3_targets, s3_targets)
    {:noreply, assign(socket, :domain_configs, Map.put(configs, domain, config))}
  end

  @impl true
  def handle_event("set_all_accounts", %{"email" => email}, socket) do
    email = normalize_string(email)

    configs =
      Map.new(socket.assigns.domain_configs, fn {domain, config} ->
        {domain, Map.put(config, :account_email, email)}
      end)

    {:noreply, assign(socket, :domain_configs, configs)}
  end

  @impl true
  def handle_event("set_account_for_group", %{"group_key" => group_key, "email" => email}, socket) do
    email = normalize_string(email)

    group_subs =
      Enum.filter(socket.assigns.subscriptions, fn sub ->
        (Map.get(sub, :owner_login) || Map.get(sub, :system_user) || sub.domain) == group_key
      end)

    configs =
      Enum.reduce(group_subs, socket.assigns.domain_configs, fn sub, acc ->
        config = Map.get(acc, sub.domain, %{})
        Map.put(acc, sub.domain, Map.put(config, :account_email, email))
      end)

    {:noreply, assign(socket, :domain_configs, configs)}
  end

  @impl true
  def handle_event("show_create_account", _params, socket) do
    {:noreply, assign(socket, :creating_account, true)}
  end

  @impl true
  def handle_event("cancel_create_account", _params, socket) do
    {:noreply,
     socket
     |> assign(:creating_account, false)
     |> assign(:new_account_form, to_form(%{"name" => "", "email" => ""}, as: :account))}
  end

  @impl true
  def handle_event("validate_account", %{"account" => params}, socket) do
    {:noreply, assign(socket, :new_account_form, to_form(params, as: :account))}
  end

  @impl true
  def handle_event("create_account", %{"account" => params}, socket) do
    name = normalize_string(params["name"])
    email = normalize_string(params["email"])

    cond do
      name == "" or email == "" ->
        {:noreply, put_flash(socket, :error, "Name and email are required to create an account.")}

      true ->
        case Accounts.create_import_user(%{name: name, email: email}) do
          {:ok, _user} ->
            {:noreply,
             socket
             |> assign(:accounts, load_accounts())
             |> assign(:creating_account, false)
             |> assign(
               :new_account_form,
               to_form(%{"name" => "", "email" => ""}, as: :account)
             )
             |> put_flash(:info, "Account created for #{email}.")}

          {:error, changeset} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Failed to create account: #{changeset_error_summary(changeset)}"
             )}
        end
    end
  end

  @impl true
  def handle_event("auto_create_accounts", _params, socket) do
    subscriptions = socket.assigns.subscriptions
    existing_accounts = Map.new(socket.assigns.accounts, &{&1.email, &1})
    existing_emails = MapSet.new(Map.keys(existing_accounts))

    # System user and client/reseller passwords from server config backup
    {sysuser_passwords, client_passwords} =
      case socket.assigns.server_credentials do
        %{sysuser_passwords: sys, client_passwords: cli} -> {sys, cli}
        %{sysuser_passwords: sys} -> {sys, %{}}
        _ -> {%{}, %{}}
      end

    # Group domains by owner identity (prefer owner_email, fall back to owner_login)
    owner_groups =
      subscriptions
      |> Enum.group_by(fn sub ->
        Map.get(sub, :owner_email) || Map.get(sub, :owner_login)
      end)
      |> Map.delete(nil)

    {created, skipped, pw_updated, failed, configs} =
      Enum.reduce(owner_groups, {0, 0, 0, 0, socket.assigns.domain_configs}, fn
        {_key, subs}, {created, skipped, pw_updated, failed, configs} ->
          sample = hd(subs)
          email = Map.get(sample, :owner_email)
          name = Map.get(sample, :owner_name) || Map.get(sample, :owner_login) || "User"
          system_user = Map.get(sample, :system_user)

          # Synthesize email from owner_login@first_domain if no email from Plesk
          email =
            if is_nil(email) or email == "" do
              login = Map.get(sample, :owner_login, "user")
              "#{login}@#{sample.domain}"
            else
              email
            end

          # Look up the Plesk password: try system user first, then
          # client/reseller login name (which matches owner_login).
          owner_login = Map.get(sample, :owner_login)

          plesk_password =
            Map.get(sysuser_passwords, system_user) ||
              Map.get(client_passwords, owner_login) ||
              Map.get(client_passwords, system_user)

          if MapSet.member?(existing_emails, email) do
            # Account exists — assign domains
            configs =
              Enum.reduce(subs, configs, fn sub, acc ->
                config = Map.get(acc, sub.domain, %{})
                Map.put(acc, sub.domain, Map.put(config, :account_email, email))
              end)

            # If account has no password yet and we have one, set it now
            existing_user = Map.get(existing_accounts, email)

            pw_bump =
              if is_binary(plesk_password) and String.length(plesk_password) >= 8 and
                   existing_user != nil do
                case Accounts.set_panel_user_password(existing_user, plesk_password) do
                  {:ok, _user} ->
                    Logger.info("[PleskImport] Set Plesk password on existing account #{email}")
                    1

                  _ ->
                    0
                end
              else
                0
              end

            {created, skipped + 1, pw_updated + pw_bump, failed, configs}
          else
            Logger.info(
              "[PleskImport] Auto-create account #{email}: " <>
                "system_user=#{inspect(system_user)}, " <>
                "owner_login=#{inspect(owner_login)}, " <>
                "password_found=#{is_binary(plesk_password)}, " <>
                "sysuser_keys=#{inspect(Map.keys(sysuser_passwords))}, " <>
                "client_keys=#{inspect(Map.keys(client_passwords))}"
            )

            user_attrs =
              if is_binary(plesk_password) and String.length(plesk_password) >= 8 do
                %{name: name, email: email, password: plesk_password}
              else
                %{name: name, email: email}
              end

            user_attrs =
              case Map.get(sample, :owner_cr_date) do
                s when is_binary(s) ->
                  case Date.from_iso8601(s) do
                    {:ok, d} -> Map.put(user_attrs, :cr_date, d)
                    _ -> user_attrs
                  end

                _ ->
                  user_attrs
              end

            case Accounts.create_import_user(user_attrs) do
              {:ok, _user} ->
                configs =
                  Enum.reduce(subs, configs, fn sub, acc ->
                    config = Map.get(acc, sub.domain, %{})
                    Map.put(acc, sub.domain, Map.put(config, :account_email, email))
                  end)

                {created + 1, skipped, pw_updated, failed, configs}

              {:error, changeset} ->
                Logger.error(
                  "[PleskImport] Account enrollment failed: #{changeset_error_summary(changeset)}"
                )

                {created, skipped, pw_updated, failed + 1, configs}
            end
          end
      end)

    flash_parts =
      if failed > 0,
        do: ["#{failed} account enrollment(s) failed; retry isolation before importing"],
        else: []

    flash_parts =
      if created > 0, do: flash_parts ++ ["created #{created}"], else: flash_parts

    flash_parts =
      if skipped > 0, do: flash_parts ++ ["#{skipped} already existed"], else: flash_parts

    flash_parts =
      if pw_updated > 0,
        do: flash_parts ++ ["#{pw_updated} password(s) updated from Plesk"],
        else: flash_parts

    flash =
      if flash_parts == [] do
        "No Plesk owner information available to create accounts."
      else
        parts = Enum.join(flash_parts, ", ")
        "Accounts: #{parts}. Domains assigned."
      end

    {:noreply,
     socket
     |> assign(:accounts, load_accounts())
     |> assign(:domain_configs, configs)
     |> put_flash(:info, flash)}
  end

  @impl true
  def handle_event("download_server_credentials", _params, socket) do
    if socket.assigns.server_creds_loading || socket.assigns.server_credentials do
      {:noreply, socket}
    else
      ssh_opts = build_ssh_opts(socket.assigns.form_params)

      task =
        Task.async(fn ->
          {:server_creds_result, Importer.download_plesk_server_config_backup(ssh_opts)}
        end)

      {:noreply,
       socket
       |> assign(:server_creds_loading, true)
       |> assign(:server_creds_task_ref, task.ref)}
    end
  end

  def handle_event("import_step", %{"step" => step}, socket)
      when step in ["source", "mapping", "review", "progress"] do
    allowed = socket.assigns.phase != :discovery or step == "source"
    {:noreply, if(allowed, do: assign(socket, :import_step, step), else: socket)}
  end

  def handle_event("review_domain", %{"domain" => domain}, socket) do
    if Enum.any?(socket.assigns.subscriptions, &(&1.domain == domain)) do
      {:noreply, assign(socket, import_step: "review", review_domain: domain)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("review_all", _, socket),
    do: {:noreply, assign(socket, import_step: "review", review_domain: nil)}

  def handle_event("confirm_import", _, socket) do
    if socket.assigns.import_step == "review" do
      result =
        if socket.assigns.review_domain,
          do: handle_event("restore_domain", %{"domain" => socket.assigns.review_domain}, socket),
          else: handle_event("restore_all", %{}, socket)

      {:noreply, updated} = result
      {:noreply, assign(updated, :import_step, "progress")}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("restore_domain", %{"domain" => domain}, socket) do
    # Ignore if already restoring or restored
    if Map.has_key?(socket.assigns.restore_task_refs, domain) or
         Map.has_key?(socket.assigns.restore_results, domain) do
      {:noreply, socket}
    else
      configs = socket.assigns.domain_configs
      config = Map.get(configs, domain, %{})
      account_email = Map.get(config, :account_email, "")
      categories = config |> Map.get(:categories, MapSet.new()) |> MapSet.to_list()

      case resolve_scope(account_email) do
        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "#{domain}: #{reason}")}

        {:ok, scope} ->
          socket = launch_restore_task(socket, domain, scope, config, categories)
          {:noreply, socket}
      end
    end
  end

  @impl true
  def handle_event("restore_all", _params, socket) do
    socket =
      Enum.reduce(socket.assigns.subscriptions, socket, fn sub, sock ->
        # Skip already-restored or in-progress domains
        if Map.has_key?(sock.assigns.restore_results, sub.domain) or
             Map.has_key?(sock.assigns.restore_task_refs, sub.domain) do
          sock
        else
          config = Map.get(sock.assigns.domain_configs, sub.domain, %{})
          account_email = Map.get(config, :account_email, "")
          categories = config |> Map.get(:categories, MapSet.new()) |> MapSet.to_list()

          case resolve_scope(account_email) do
            {:error, _reason} ->
              results =
                Map.put(sock.assigns.restore_results, sub.domain, {
                  :error,
                  %{
                    domain: sub.domain,
                    domain_status: {:failed, "No account selected"},
                    categories: %{}
                  }
                })

              assign(sock, :restore_results, results)

            {:ok, scope} ->
              launch_restore_task(sock, sub.domain, scope, config, categories)
          end
        end
      end)

    {:noreply, socket}
  end

  # ── Save / Load migrations ────────────────────────────────────────────

  @impl true
  def handle_event("toggle_saved_migrations", _params, socket) do
    {:noreply, assign(socket, :show_saved, !socket.assigns.show_saved)}
  end

  @impl true
  def handle_event("save_migration", %{"name" => name}, socket) do
    name = normalize_string(name)

    if name == "" do
      {:noreply, put_flash(socket, :error, "Migration name is required.")}
    else
      attrs = %{
        name: name,
        source: socket.assigns.form_params["source"],
        status: migration_status(socket.assigns.restore_results, socket.assigns.subscriptions),
        source_params: sanitize_source_params(socket.assigns.form_params),
        subscriptions: serialize_subscriptions(socket.assigns.subscriptions),
        inventory: serialize_inventory(socket.assigns.ssh_discovery),
        domain_configs: serialize_domain_configs(socket.assigns.domain_configs),
        restore_results: serialize_restore_results(socket.assigns.restore_results),
        server_credentials: serialize_server_credentials(socket.assigns.server_credentials)
      }

      case Plesk.create_migration(socket.assigns.current_scope, attrs) do
        {:ok, _migration} ->
          {:noreply,
           socket
           |> load_saved_migrations()
           |> put_flash(:info, "Migration \"#{name}\" saved.")}

        {:error, changeset} ->
          {:noreply,
           put_flash(socket, :error, "Failed to save: #{changeset_error_summary(changeset)}")}
      end
    end
  end

  @impl true
  def handle_event("load_migration", %{"id" => id}, socket) do
    migration = Plesk.get_migration!(socket.assigns.current_scope, id)

    subscriptions = deserialize_subscriptions(migration.subscriptions)
    ssh_discovery = deserialize_inventory(migration.inventory)
    domain_configs = deserialize_domain_configs(migration.domain_configs)
    restore_results = deserialize_restore_results(migration.restore_results)

    # Restore source params (sans passwords)
    form_params = Map.merge(@default_params, migration.source_params)

    # Restore server credentials if saved
    server_credentials = deserialize_server_credentials(migration.server_credentials)

    creds_flash =
      if server_credentials do
        db_count = map_size(server_credentials.db_passwords)
        mail_count = map_size(server_credentials.mail_passwords)
        sys_count = map_size(server_credentials.sysuser_passwords)
        cli_count = map_size(Map.get(server_credentials, :client_passwords, %{}))
        ftp_count = map_size(Map.get(server_credentials, :ftpuser_passwords, %{}))

        "Loaded migration \"#{migration.name}\" with #{db_count} DB, #{mail_count} mail, " <>
          "#{sys_count} system user, #{cli_count} client/reseller, #{ftp_count} FTP password(s)."
      else
        "Loaded migration \"#{migration.name}\"."
      end

    {:noreply,
     socket
     |> assign(:phase, :restore)
     |> assign(:import_step, "mapping")
     |> assign(:review_domain, nil)
     |> assign(:form_params, form_params)
     |> assign(:form, to_form(form_params, as: :import))
     |> assign(:ssh_discovery, ssh_discovery)
     |> assign(:subscriptions, subscriptions)
     |> assign(:domain_configs, domain_configs)
     |> assign(:domain_s3_backends, load_domain_s3_backends(subscriptions))
     |> assign(:restore_results, restore_results)
     |> assign(:server_credentials, server_credentials)
     |> assign(
       :ssh_needs_password,
       form_params["source"] == "ssh" and form_params["ssh_auth_method"] == "password"
     )
     |> put_flash(:info, creds_flash)}
  end

  @impl true
  def handle_event("delete_migration", %{"id" => id}, socket) do
    migration = Plesk.get_migration!(socket.assigns.current_scope, id)

    case Plesk.delete_migration(migration) do
      {:ok, _} ->
        {:noreply,
         socket
         |> load_saved_migrations()
         |> put_flash(:info, "Migration \"#{migration.name}\" deleted.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete migration.")}
    end
  end

  @impl true
  def handle_event("update_migration", %{"id" => id}, socket) do
    migration = Plesk.get_migration!(socket.assigns.current_scope, id)

    attrs = %{
      status: migration_status(socket.assigns.restore_results, socket.assigns.subscriptions),
      domain_configs: serialize_domain_configs(socket.assigns.domain_configs),
      restore_results: serialize_restore_results(socket.assigns.restore_results),
      server_credentials: serialize_server_credentials(socket.assigns.server_credentials)
    }

    case Plesk.update_migration(migration, attrs) do
      {:ok, _} ->
        {:noreply,
         socket
         |> load_saved_migrations()
         |> put_flash(:info, "Migration \"#{migration.name}\" updated.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update migration.")}
    end
  end

  @impl true
  def handle_event("resume_upload_job", %{"id" => job_id}, socket) do
    case Hostctl.UploadWorker.resume_upload(String.to_integer(job_id)) do
      {:ok, _job} ->
        {:noreply, load_upload_jobs(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to resume: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("cancel_upload_job", %{"id" => job_id}, socket) do
    Hostctl.UploadWorker.cancel(String.to_integer(job_id))
    {:noreply, load_upload_jobs(socket)}
  end

  @impl true
  def handle_event("delete_upload_job", %{"id" => job_id}, socket) do
    job = Hosting.get_upload_job!(String.to_integer(job_id))
    Hosting.delete_upload_job(job)
    {:noreply, load_upload_jobs(socket)}
  end

  # Upload job progress from PubSub
  @impl true
  def handle_info({:upload_progress, _job}, socket) do
    {:noreply, load_upload_jobs(socket)}
  end

  # ── Async task result ──────────────────────────────────────────────────

  @impl true
  def handle_info({ref, result}, socket) when ref == socket.assigns.discover_task_ref do
    Process.demonitor(ref, [:flush])

    socket =
      socket
      |> assign(:discovering, false)
      |> assign(:discover_task_ref, nil)

    case result do
      {:ok, ssh_discovery, subscriptions} ->
        domain_configs = build_domain_configs(subscriptions, ssh_discovery)

        {:noreply,
         socket
         |> assign(:phase, :restore)
         |> assign(:import_step, "mapping")
         |> assign(:review_domain, nil)
         |> assign(:ssh_discovery, ssh_discovery)
         |> assign(:subscriptions, subscriptions)
         |> assign(:domain_configs, domain_configs)
         |> assign(:domain_s3_backends, load_domain_s3_backends(subscriptions))
         |> assign(:restore_results, %{})
         |> assign(:restore_progress, %{})
         |> put_flash(:info, "Discovered #{length(subscriptions)} domain(s).")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, socket)
      when ref == socket.assigns.discover_task_ref do
    {:noreply,
     socket
     |> assign(:discovering, false)
     |> assign(:discover_task_ref, nil)
     |> put_flash(:error, "Discovery failed unexpectedly: #{inspect(reason)}")}
  end

  # Server config backup credentials completed
  @impl true
  def handle_info({ref, {:server_creds_result, result}}, socket)
      when ref == socket.assigns.server_creds_task_ref do
    Process.demonitor(ref, [:flush])

    socket =
      socket
      |> assign(:server_creds_loading, false)
      |> assign(:server_creds_task_ref, nil)

    case result do
      {:ok, credentials} ->
        db_count = map_size(credentials.db_passwords)
        mail_count = map_size(credentials.mail_passwords)
        sys_count = map_size(credentials.sysuser_passwords)
        cli_count = map_size(Map.get(credentials, :client_passwords, %{}))
        ftp_count = map_size(Map.get(credentials, :ftpuser_passwords, %{}))

        socket =
          socket
          |> assign(:server_credentials, credentials)
          |> put_flash(
            :info,
            "Server credentials loaded: #{db_count} DB, #{mail_count} mail, " <>
              "#{sys_count} system user, #{cli_count} client/reseller, #{ftp_count} FTP password(s)."
          )

        socket =
          if mail_count == 0 and sys_count == 0 and cli_count == 0 and ftp_count == 0 do
            put_flash(
              socket,
              :warning,
              "No plaintext passwords found in server backup. " <>
                "Run 'plesk bin server_pref --update -plain-backups true' on the Plesk server, " <>
                "then re-download. Per-domain backups will also be tried during import."
            )
          else
            socket
          end

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Server config backup failed: #{reason}")}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, socket)
      when ref == socket.assigns.server_creds_task_ref do
    {:noreply,
     socket
     |> assign(:server_creds_loading, false)
     |> assign(:server_creds_task_ref, nil)
     |> put_flash(:error, "Server config backup crashed: #{inspect(reason)}")}
  end

  # Restore task completed
  @impl true
  def handle_info({ref, {:restore_result, domain, result}}, socket) do
    Process.demonitor(ref, [:flush])

    task_refs = Map.delete(socket.assigns.restore_task_refs, domain)
    progress = Map.delete(socket.assigns.restore_progress, domain)

    {status, flash_type, flash_msg} =
      case result do
        {:ok, r} ->
          {{:ok, r}, :info,
           "Import configuration finished for #{domain}. Check the transfer jobs below for file upload status."}

        {:error, r} ->
          {{:error, r}, :error, "Failed to restore #{domain}."}
      end

    results = Map.put(socket.assigns.restore_results, domain, status)

    # The importer persists mappings before transfers; reload them even after partial failures.
    socket =
      assign(socket, :domain_s3_backends, load_domain_s3_backends(socket.assigns.subscriptions))

    {:noreply,
     socket
     |> assign(:restore_task_refs, task_refs)
     |> assign(:restore_progress, progress)
     |> assign(:restore_results, results)
     |> put_flash(flash_type, flash_msg)}
  end

  # Restore progress update from importer
  @impl true
  def handle_info({:restore_progress, domain, category, index, total, status}, socket) do
    current = Map.get(socket.assigns.restore_progress, domain, %{completed: %{}})
    completed = Map.get(current, :completed, %{})

    # When status is a result map (not :in_progress), this category is done
    completed =
      if is_map(status),
        do: Map.put(completed, category, status),
        else: completed

    progress =
      Map.put(socket.assigns.restore_progress, domain, %{
        category: category,
        index: index,
        total: total,
        status: status,
        completed: completed
      })

    {:noreply, assign(socket, :restore_progress, progress)}
  end

  # Restore task crashed
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, socket) do
    case Enum.find(socket.assigns.restore_task_refs, fn {_domain, r} -> r == ref end) do
      {domain, _} ->
        task_refs = Map.delete(socket.assigns.restore_task_refs, domain)
        progress = Map.delete(socket.assigns.restore_progress, domain)

        results =
          Map.put(socket.assigns.restore_results, domain, {
            :error,
            %{
              domain: domain,
              domain_status: {:failed, "Restore crashed: #{inspect(reason)}"},
              categories: %{}
            }
          })

        {:noreply,
         socket
         |> assign(:restore_task_refs, task_refs)
         |> assign(:restore_progress, progress)
         |> assign(:restore_results, results)
         |> put_flash(:error, "Restore of #{domain} crashed.")}

      nil ->
        {:noreply, socket}
    end
  end

  # Ignore unknown messages
  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Restore task launcher ─────────────────────────────────────────────

  defp launch_restore_task(socket, domain, scope, config, categories) do
    subscription = Enum.find(socket.assigns.subscriptions, &(&1.domain == domain))
    inventory = filter_inventory_for_domain(socket.assigns.ssh_discovery, domain, subscription)
    apply_dns = normalize_boolean(socket.assigns.form_params["apply_dns_template"])
    ssh_opts = build_ssh_opts(socket.assigns.form_params)
    web_files_path = Map.get(config, :web_files_path, "/var/www/#{domain}")
    server_credentials = socket.assigns.server_credentials
    lv_pid = self()

    # Build a per-target S3 opts map from the `s3_targets` config. Each target
    # ("" = main domain, "sub1" = subdomain) that has S3 import enabled gets an
    # entry in the map. Targets without S3 enabled are absent (fall back to local).
    s3_backend_opts =
      config
      |> Map.get(:s3_targets, %{})
      |> Enum.reduce(%{}, fn {target, tc}, acc ->
        if Map.get(tc, :s3_import, false) do
          opts =
            case get_in(socket.assigns.domain_s3_backends, [domain, target]) do
              nil ->
                build_s3_backend_opts_from_config(tc)

              backend ->
                %{
                  endpoint: backend.endpoint_url,
                  bucket: backend.bucket,
                  prefix: backend.path_prefix || "",
                  exact_prefix: true,
                  ftp_mount_enabled: backend.ftp_mount_enabled,
                  directory_listing: backend.directory_listing,
                  access_key_id: backend.access_key_id,
                  secret_access_key: backend.secret_access_key,
                  region: backend.region || "us-east-1"
                }
            end

          Map.put(acc, target, opts)
        else
          acc
        end
      end)
      |> then(fn map -> if map == %{}, do: nil, else: map end)

    task =
      Task.async(fn ->
        result =
          Importer.restore_domain(scope, subscription, inventory,
            categories: categories,
            apply_dns_template: apply_dns,
            ssh_opts: ssh_opts,
            web_files_path: web_files_path,
            s3_backend_opts: s3_backend_opts,
            progress_pid: lv_pid,
            server_credentials: server_credentials,
            user_id: scope.user.id
          )

        {:restore_result, domain, result}
      end)

    progress =
      Map.put(socket.assigns.restore_progress, domain, %{
        category: nil,
        index: 0,
        total: length(categories),
        status: :starting
      })

    task_refs = Map.put(socket.assigns.restore_task_refs, domain, task.ref)

    socket
    |> assign(:restore_progress, progress)
    |> assign(:restore_task_refs, task_refs)
  end

  # Builds S3 backend opts from inline credentials stored in the domain config
  # (entered directly in the import UI when no pre-configured backend exists).
  defp build_s3_backend_opts_from_config(config) do
    endpoint = Map.get(config, :s3_endpoint, "")
    bucket = Map.get(config, :s3_bucket, "")

    if is_binary(endpoint) && endpoint != "" && is_binary(bucket) && bucket != "" do
      %{
        endpoint: Hostctl.S3Client.normalize_endpoint_change(endpoint),
        ftp_mount_enabled: Map.get(config, :ftp_enabled, false),
        directory_listing: Map.get(config, :directory_listing, false),
        bucket: bucket,
        prefix: Map.get(config, :s3_prefix, ""),
        access_key_id: Map.get(config, :s3_access_key, ""),
        secret_access_key: Map.get(config, :s3_secret_key, ""),
        region:
          case Map.get(config, :s3_region, "") do
            "" -> "us-east-1"
            r -> r
          end
      }
    else
      nil
    end
  end

  defp s3_destination(assigns) do
    tc = assigns.config

    params = %{
      "domain" => assigns.domain,
      "target" => assigns.target,
      "endpoint" => Map.get(tc, :s3_endpoint, ""),
      "bucket" => Map.get(tc, :s3_bucket, ""),
      "region" => Map.get(tc, :s3_region, "us-east-1"),
      "access_key" => Map.get(tc, :s3_access_key, ""),
      "secret_key" => Map.get(tc, :s3_secret_key, ""),
      "prefix" => Map.get(tc, :s3_prefix, ""),
      "ftp_enabled" => Map.get(tc, :ftp_enabled, false),
      "directory_listing" => Map.get(tc, :directory_listing, false),
      "connection_name" => Map.get(tc, :connection_name, "")
    }

    assigns =
      assigns
      |> assign(:form, to_form(params, as: :destination))
      |> assign(
        :connection_form,
        to_form(%{"id" => "", "domain" => assigns.domain, "target" => assigns.target},
          as: :connection
        )
      )
      |> assign(
        :bucket_form,
        to_form(
          %{"bucket" => params["bucket"], "domain" => assigns.domain, "target" => assigns.target},
          as: :selection
        )
      )
      |> assign(:uid, "s3-#{assigns.domain}-#{assigns.target}")
      |> assign(:connection_options, Enum.map(assigns.connections, &{&1.name, &1.id}))

    ~H"""
    <div
      id={@uid}
      class="ml-4 rounded-xl border border-sky-200 bg-sky-50/40 p-4 space-y-3 dark:border-sky-800 dark:bg-sky-950/20"
    >
      <.form for={@connection_form} id={"#{@uid}-connection"} phx-change="use_s3_connection">
        <.input field={@connection_form[:domain]} type="hidden" />
        <.input field={@connection_form[:target]} type="hidden" />
        <.input
          field={@connection_form[:id]}
          id={"#{@uid}-saved"}
          type="select"
          label="Use a saved S3 connection"
          prompt="Enter credentials below or select a connection"
          options={@connection_options}
        />
      </.form>
      <.form
        for={@form}
        id={"s3-config-form-#{@domain}-#{@target}"}
        phx-change="set_s3_config"
        phx-submit="save_s3_connection"
        class="grid grid-cols-2 gap-3"
      >
        <.input field={@form[:domain]} type="hidden" />
        <.input field={@form[:target]} type="hidden" />
        <.input
          field={@form[:endpoint]}
          id={"#{@uid}-endpoint"}
          label="Endpoint"
          placeholder="https://s3.wasabisys.com"
        />
        <.input field={@form[:region]} id={"#{@uid}-region"} label="Region" />
        <.input
          field={@form[:access_key]}
          id={"#{@uid}-access"}
          label="Access key"
          autocomplete="off"
        />
        <.input
          field={@form[:secret_key]}
          id={"#{@uid}-secret"}
          type="password"
          label="Secret key"
          autocomplete="new-password"
        />
        <.input
          field={@form[:bucket]}
          id={"#{@uid}-bucket"}
          label="Bucket name"
          placeholder="Existing or new bucket"
        />
        <.input field={@form[:prefix]} id={"#{@uid}-prefix"} label="Parent key prefix (optional)" />
        <p class="col-span-2 text-xs text-gray-500">
          Files and serving settings use this prefix followed by {if @target == "",
            do: "httpdocs",
            else: @target <> "." <> @domain}.
        </p>
        <.input
          field={@form[:ftp_enabled]}
          id={"#{@uid}-ftp"}
          type="checkbox"
          label="Transparent FTP access"
        />
        <.input
          field={@form[:directory_listing]}
          id={"#{@uid}-listing"}
          type="checkbox"
          label="Directory listings"
        />
        <.input
          field={@form[:connection_name]}
          id={"#{@uid}-name"}
          label="Save connection as"
          placeholder="Wasabi account"
        />
        <button
          id={"#{@uid}-save"}
          type="submit"
          class="self-end rounded-lg bg-sky-700 px-3 py-2 text-sm text-white hover:bg-sky-600 transition-colors"
        >
          Save connection
        </button>
      </.form>
      <div class="flex gap-3">
        <button
          id={"#{@uid}-load"}
          type="button"
          phx-click="list_s3_buckets"
          phx-value-domain={@domain}
          phx-value-target={@target}
          disabled={@busy}
          class="text-sm text-sky-700 hover:underline disabled:opacity-50"
        >
          {if @busy, do: "Working…", else: "Load existing buckets"}
        </button>
        <button
          id={"#{@uid}-create"}
          type="button"
          phx-click="create_s3_bucket"
          phx-value-domain={@domain}
          phx-value-target={@target}
          disabled={@busy}
          class="text-sm text-sky-700 hover:underline disabled:opacity-50"
        >
          Create named bucket
        </button>
      </div>
      <.form
        :if={@buckets != []}
        for={@bucket_form}
        id={"#{@uid}-buckets"}
        phx-change="choose_s3_bucket"
      >
        <.input field={@bucket_form[:domain]} type="hidden" />
        <.input field={@bucket_form[:target]} type="hidden" />
        <.input
          field={@bucket_form[:bucket]}
          id={"#{@uid}-existing"}
          type="select"
          label="Existing bucket"
          prompt="Choose a bucket"
          options={@buckets}
        />
      </.form>
      <p class="text-xs text-gray-500">
        You can enter an existing bucket manually if this key cannot list buckets. Creating a bucket requires provider permission.
      </p>
    </div>
    """
  end

  defp s3_target(socket, params) do
    get_in(socket.assigns.domain_configs, [params["domain"], :s3_targets, params["target"] || ""]) ||
      %{}
  end

  defp put_s3_target(socket, params, tc) do
    domain = params["domain"]
    config = Map.get(socket.assigns.domain_configs, domain, %{})
    targets = Map.put(Map.get(config, :s3_targets, %{}), params["target"] || "", tc)

    assign(
      socket,
      :domain_configs,
      Map.put(socket.assigns.domain_configs, domain, Map.put(config, :s3_targets, targets))
    )
  end

  @impl true
  def handle_async({:s3_operation, key}, result, socket) do
    socket = assign(socket, :s3_busy, MapSet.delete(socket.assigns.s3_busy, key))

    case result do
      {:ok, {:ok, buckets}} ->
        {:noreply,
         socket
         |> assign(:s3_bucket_lists, Map.put(socket.assigns.s3_bucket_lists, key, buckets))
         |> put_flash(:info, "Found #{length(buckets)} buckets")}

      {:ok, {:created, bucket}} ->
        buckets =
          [bucket | Map.get(socket.assigns.s3_bucket_lists, key, [])]
          |> Enum.uniq()
          |> Enum.sort()

        {:noreply,
         socket
         |> assign(:s3_bucket_lists, Map.put(socket.assigns.s3_bucket_lists, key, buckets))
         |> put_flash(:info, "Created bucket #{bucket}")}

      {:ok, {:error, reason}} ->
        {:noreply, put_flash(socket, :error, reason)}

      {:exit, _} ->
        {:noreply,
         put_flash(socket, :error, "S3 request failed; check the connection and try again")}
    end
  end

  # ── Render ─────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      update_status={assigns[:update_status]}
      flash={@flash}
      current_scope={@current_scope}
      active_tab={@active_tab}
    >
      <div class="max-w-6xl mx-auto space-y-6">
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-bold text-gray-900 dark:text-white">Plesk Import</h1>
            <p class="mt-1 text-sm text-gray-500 dark:text-gray-400">
              Discover and selectively restore domains from an extracted Plesk backup, the Plesk API, or a live Plesk server over SSH.
            </p>
          </div>
          <button
            id="toggle-saved-btn"
            type="button"
            phx-click="toggle_saved_migrations"
            class={[
              "inline-flex items-center gap-1.5 px-3 py-2 rounded-lg border text-sm font-medium transition-colors",
              if(@show_saved,
                do:
                  "border-indigo-300 dark:border-indigo-700 bg-indigo-50 dark:bg-indigo-950/30 text-indigo-700 dark:text-indigo-300",
                else:
                  "border-gray-300 dark:border-gray-600 text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-800"
              )
            ]}
          >
            <.icon name="hero-bookmark" class="w-4 h-4" /> Saved
            <span
              :if={@saved_migrations != []}
              class="text-[10px] font-semibold rounded-full px-1.5 py-0.5 bg-gray-100 dark:bg-gray-800 text-gray-600 dark:text-gray-400"
            >
              {length(@saved_migrations)}
            </span>
          </button>
        </div>

        <%= if @show_saved do %>
          {render_saved_migrations(assigns)}
        <% end %>

        <nav id="plesk-steps" aria-label="Import steps" class="flex flex-wrap gap-2">
          <button
            :for={
              {step, label} <- [
                {"source", "1 · Source"},
                {"mapping", "2 · Map & select"},
                {"review", "3 · Review"},
                {"progress", "4 · Progress"}
              ]
            }
            id={"plesk-step-#{step}"}
            phx-click="import_step"
            phx-value-step={step}
            disabled={@phase == :discovery && step != "source"}
            aria-current={if @import_step == step, do: "step"}
            class={[
              "app-button disabled:opacity-40",
              @import_step == step && "!border-indigo-500 !text-indigo-600 dark:!text-indigo-300"
            ]}
          >
            {label}
          </button>
        </nav>
        <%= cond do %>
          <% @discovering -> %>
            {render_discovering(assigns)}
          <% @import_step == "source" -> %>
            {render_discovery_phase(assigns)}
          <% @import_step == "review" -> %>
            {render_import_review(assigns)}
          <% @import_step == "progress" -> %>
            {render_import_progress(assigns)}
          <% true -> %>
            {render_restore_phase(assigns)}
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  defp render_import_review(assigns) do
    plans =
      Enum.filter(
        assigns.subscriptions,
        &(assigns.review_domain == nil || &1.domain == assigns.review_domain)
      )

    assigns = assign(assigns, :plans, plans)

    ~H"""
    <div id="plesk-review" class="space-y-5">
      <div>
        <h2 class="text-lg font-semibold">Review import plan</h2>
        <p class="mt-1 text-sm text-gray-500">
          Review owners, categories, and storage destinations. Source discovery does not verify the finished website.
        </p>
      </div>
      <div
        :for={sub <- @plans}
        id={"review-#{sub.domain}"}
        class="rounded-xl border border-gray-200 bg-white p-5 dark:border-gray-800 dark:bg-gray-900"
      >
        <% config = Map.get(@domain_configs, sub.domain, %{}) %>
        <div class="flex flex-wrap items-center justify-between gap-3">
          <h3 class="font-semibold">{sub.domain}</h3>
          <span class="text-sm text-gray-500">Owner: {Map.get(config, :account_email, "")}</span>
        </div>
        <p :if={Map.get(config, :account_email, "") == ""} class="mt-2 text-sm text-red-600">
          Assign an account before importing this domain.
        </p>
        <p class="mt-3 text-sm">
          Selected: {config
          |> Map.get(:categories, MapSet.new())
          |> Enum.sort()
          |> Enum.map_join(", ", &category_display_name/1)}
        </p>
        <p class="mt-2 text-xs text-gray-500">Unselected categories will not be imported.</p>
        <div
          :for={{target, storage} <- Map.get(config, :s3_targets, %{})}
          class="mt-3 border-t border-gray-100 pt-3 text-sm dark:border-gray-800"
        >
          <p>{target} → {if Map.get(storage, :s3_import, false), do: "S3", else: "Local files"}</p>
          <p :if={Map.get(storage, :s3_import, false)} class="break-all text-xs text-gray-500">
            Bucket: {Map.get(storage, :s3_bucket, "")} · Prefix: {Map.get(storage, :s3_prefix, "")}
          </p>
        </div>
      </div>
      <p class="rounded-lg bg-indigo-50 p-4 text-sm text-indigo-800 dark:bg-indigo-950/30 dark:text-indigo-200">
        Required services and destination validation run before restore. Configuration and background uploads have separate results. Verify sites and mail before changing public traffic.
      </p>
      <div class="flex flex-wrap justify-between gap-4">
        <button phx-click="import_step" phx-value-step="mapping" class="app-button">
          ← Edit mappings
        </button>
        <button
          id="confirm-plesk-import"
          phx-click="confirm_import"
          disabled={
            @plans == [] ||
              Enum.any?(
                @plans,
                &(Map.get(Map.get(@domain_configs, &1.domain, %{}), :account_email, "") == "")
              )
          }
          data-confirm="Start this import using the reviewed owners, categories, and destinations?"
          class="rounded-lg bg-indigo-600 px-4 py-2 text-sm font-medium text-white disabled:opacity-50"
        >
          Start import
        </button>
      </div>
    </div>
    """
  end

  defp render_import_progress(assigns) do
    ~H"""
    <div id="plesk-progress" class="space-y-5">
      <div>
        <h2 class="text-lg font-semibold">Import progress</h2>
        <p class="mt-1 text-sm text-gray-500">
          Configuration, transfers, and verification are separate stages.
        </p>
      </div>
      <div
        :for={sub <- @subscriptions}
        id={"import-progress-#{sub.domain}"}
        class="rounded-xl border border-gray-200 bg-white p-5 dark:border-gray-800 dark:bg-gray-900"
      >
        <% result = Map.get(@restore_results, sub.domain) %>
        <% progress = Map.get(@restore_progress, sub.domain) %>
        <h3 class="font-semibold">{sub.domain}</h3>
        <div class="mt-4 flex justify-between gap-3 text-sm">
          <span>Configuration</span><span>{cond do
          Map.has_key?(@restore_task_refs, sub.domain) -> "In progress"
          match?({:ok, _}, result) -> "Finished — review transfers"
          match?({:error, _}, result) -> "Failed — review result"
          true -> "Not started"
        end}</span>
        </div>
        <p :if={progress} class="mt-2 text-xs text-gray-500">
          {Map.get(progress, :status, "Working")}
        </p>
        <p class="mt-3 text-sm text-gray-500">
          Verification: not recorded. Check the destination website, data, and mail delivery.
        </p>
      </div>
      <%= if @upload_jobs != [] do %>
        {render_upload_jobs(assigns)}
      <% else %>
        <p class="text-sm text-gray-500">No background S3 transfer jobs recorded.</p>
      <% end %>
      <button phx-click="import_step" phx-value-step="mapping" class="app-button">
        View detailed configuration results
      </button>
    </div>
    """
  end

  # ── Discovering progress ───────────────────────────────────────────────

  defp render_discovering(assigns) do
    ~H"""
    <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800 p-8">
      <div class="flex flex-col items-center justify-center gap-4">
        <div class="relative">
          <div class="w-12 h-12 rounded-full border-4 border-gray-200 dark:border-gray-700"></div>
          <div class="absolute inset-0 w-12 h-12 rounded-full border-4 border-t-indigo-500 animate-spin">
          </div>
        </div>
        <div class="text-center">
          <h3 class="text-sm font-semibold text-gray-900 dark:text-white">Discovering...</h3>
          <p class="text-xs text-gray-500 dark:text-gray-400 mt-1">
            Connecting to the remote server and inventorying domains, mail, databases, and more.
          </p>
        </div>
        <div class="w-full max-w-sm">
          <div class="h-1.5 w-full rounded-full bg-gray-100 dark:bg-gray-800 overflow-hidden">
            <div class="h-full rounded-full bg-indigo-500 animate-pulse" style="width: 100%"></div>
          </div>
        </div>
        <p class="text-[11px] text-gray-400 dark:text-gray-500">
          This may take a few seconds depending on the server size.
        </p>
      </div>
    </div>
    """
  end

  # ── Upload Jobs ────────────────────────────────────────────────────────

  defp render_upload_jobs(assigns) do
    ~H"""
    <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800 p-5">
      <h2 class="text-sm font-semibold text-gray-900 dark:text-white mb-3">
        <.icon name="hero-cloud-arrow-up" class="w-4 h-4 inline -mt-0.5" /> Background S3 Uploads
      </h2>
      <div class="space-y-3">
        <%= for job <- @upload_jobs do %>
          <% pct =
            if(job.total_files > 0, do: round(job.uploaded_files / job.total_files * 100), else: 0) %>
          <div class="rounded-lg border border-gray-100 dark:border-gray-800 p-3 text-xs">
            <div class="flex items-center justify-between gap-2 mb-1.5">
              <div class="flex items-center gap-1.5 min-w-0">
                <span class={[
                  "inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-[10px] font-medium shrink-0",
                  case job.status do
                    "completed" ->
                      "bg-emerald-100 dark:bg-emerald-900/30 text-emerald-700 dark:text-emerald-300"

                    "running" ->
                      "bg-indigo-100 dark:bg-indigo-900/30 text-indigo-700 dark:text-indigo-300"

                    "failed" ->
                      "bg-red-100 dark:bg-red-900/30 text-red-700 dark:text-red-300"

                    _ ->
                      "bg-gray-100 dark:bg-gray-800 text-gray-500 dark:text-gray-400"
                  end
                ]}>
                  <%= case job.status do %>
                    <% "running" -> %>
                      <span class="w-1.5 h-1.5 rounded-full bg-indigo-500 animate-pulse inline-block">
                      </span>
                    <% "completed" -> %>
                      <.icon name="hero-check" class="w-2.5 h-2.5" />
                    <% "failed" -> %>
                      <.icon name="hero-x-mark" class="w-2.5 h-2.5" />
                    <% _ -> %>
                      <span class="w-1.5 h-1.5 rounded-full bg-gray-400 inline-block"></span>
                  <% end %>
                  {job.status}
                </span>
                <span class="font-mono text-gray-700 dark:text-gray-300 truncate">
                  {job.s3_bucket}/{job.s3_prefix || ""}
                </span>
                <span class="text-gray-400 dark:text-gray-500 shrink-0">
                  · {job.domain && job.domain.name}
                </span>
              </div>
              <div class="flex items-center gap-2 shrink-0">
                <span class="text-gray-500 dark:text-gray-400">
                  {job.uploaded_files}/{job.total_files} files ({pct}%)
                </span>
                <%= if job.status in ["paused", "failed", "pending"] do %>
                  <button
                    type="button"
                    phx-click="resume_upload_job"
                    phx-value-id={job.id}
                    class="text-indigo-600 dark:text-indigo-400 hover:underline"
                  >
                    Resume
                  </button>
                <% end %>
                <%= if job.status == "running" do %>
                  <button
                    type="button"
                    phx-click="cancel_upload_job"
                    phx-value-id={job.id}
                    class="text-amber-600 dark:text-amber-400 hover:underline"
                  >
                    Pause
                  </button>
                <% end %>
                <%= if job.status in ["completed", "failed", "paused"] do %>
                  <button
                    type="button"
                    phx-click="delete_upload_job"
                    phx-value-id={job.id}
                    class="text-gray-400 hover:text-red-500 dark:hover:text-red-400"
                  >
                    <.icon name="hero-trash" class="w-3.5 h-3.5" />
                  </button>
                <% end %>
              </div>
            </div>

            <%!-- Progress bar --%>
            <div class="h-1 w-full rounded-full bg-gray-100 dark:bg-gray-800 overflow-hidden">
              <div
                class={[
                  "h-full rounded-full transition-all duration-300",
                  case job.status do
                    "completed" -> "bg-emerald-500"
                    "failed" -> "bg-red-500"
                    _ -> "bg-indigo-500"
                  end
                ]}
                style={"width: #{pct}%"}
              >
              </div>
            </div>

            <%!-- Current file / error message --%>
            <%= if job.status == "running" && job.current_file do %>
              <div class="mt-1 text-[10px] text-gray-400 dark:text-gray-500 font-mono truncate">
                ↑ {job.current_file}
              </div>
            <% end %>
            <%= if job.status == "failed" && job.error_message do %>
              <div
                class="mt-1 text-[10px] text-red-600 dark:text-red-400 truncate"
                title={job.error_message}
              >
                {String.slice(job.error_message, 0, 120)}
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # ── Saved migrations ──────────────────────────────────────────────────

  defp render_saved_migrations(assigns) do
    ~H"""
    <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800 p-5">
      <h2 class="text-sm font-semibold text-gray-900 dark:text-white mb-3">
        <.icon name="hero-bookmark" class="w-4 h-4 inline -mt-0.5" /> Saved Migrations
      </h2>
      <%= if @saved_migrations == [] do %>
        <p class="text-xs text-gray-500 dark:text-gray-400">
          No saved migrations yet. Run a discovery and save it to resume later.
        </p>
      <% else %>
        <div class="space-y-2">
          <div
            :for={m <- @saved_migrations}
            class="flex items-center justify-between rounded-lg border border-gray-100 dark:border-gray-800 px-4 py-3 hover:bg-gray-50 dark:hover:bg-gray-800/50 transition-colors"
          >
            <div class="flex items-center gap-3 min-w-0">
              <span class={[
                "inline-flex items-center rounded-full px-2 py-0.5 text-[10px] font-semibold shrink-0",
                migration_status_class(m.status)
              ]}>
                {if m.status == "completed", do: "Configuration finished", else: m.status}
              </span>
              <div class="min-w-0">
                <p class="text-sm font-medium text-gray-900 dark:text-white truncate">{m.name}</p>
                <p class="text-[11px] text-gray-400 dark:text-gray-500">
                  {m.source} · {length(m.subscriptions)} domain(s) · {Calendar.strftime(
                    m.updated_at,
                    "%b %d, %Y %H:%M"
                  )}
                </p>
              </div>
            </div>
            <div class="flex items-center gap-1.5 shrink-0 ml-3">
              <button
                type="button"
                phx-click="load_migration"
                phx-value-id={m.id}
                class="inline-flex items-center gap-1 px-2.5 py-1.5 rounded-md text-xs font-medium text-indigo-700 dark:text-indigo-300 hover:bg-indigo-50 dark:hover:bg-indigo-900/30 transition-colors"
              >
                <.icon name="hero-arrow-up-tray" class="w-3.5 h-3.5" /> Load
              </button>
              <button
                type="button"
                phx-click="delete_migration"
                phx-value-id={m.id}
                data-confirm={"Delete migration \"#{m.name}\"?"}
                class="inline-flex items-center gap-1 px-2.5 py-1.5 rounded-md text-xs font-medium text-red-600 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-900/30 transition-colors"
              >
                <.icon name="hero-trash" class="w-3.5 h-3.5" />
              </button>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # ── Discovery phase ────────────────────────────────────────────────────

  defp render_discovery_phase(assigns) do
    ~H"""
    <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800 p-6">
      <.form for={@form} id="plesk-import-form" phx-change="validate" phx-submit="discover">
        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <.input
            field={@form[:source]}
            type="select"
            label="Source"
            options={[
              {"Extracted backup folder", "backup"},
              {"Plesk API", "api"},
              {"Direct SSH", "ssh"}
            ]}
          />

          <div></div>

          <%= if @form[:source].value == "backup" do %>
            <.input
              field={@form[:backup_path]}
              type="text"
              label="Extracted Backup Path"
              placeholder="/Users/you/Downloads/backup_2603260012"
            />

            <.input
              field={@form[:owner_login]}
              type="text"
              label="Filter: Plesk Owner Login (optional)"
              placeholder="admin"
            />

            <.input
              field={@form[:system_user]}
              type="text"
              label="Filter: Plesk System User (optional)"
              placeholder="example_site_abc123"
            />
          <% else %>
            <%= if @form[:source].value == "api" do %>
              <.input
                field={@form[:api_url]}
                type="url"
                label="Plesk API URL"
                placeholder="https://plesk.example.com:8443"
              />

              <.input
                field={@form[:api_key]}
                type="text"
                label="Plesk API Key"
                placeholder="Optional if using username/password"
              />

              <.input
                field={@form[:api_username]}
                type="text"
                label="API Username"
                placeholder="Optional if using API key"
              />

              <.input
                field={@form[:api_password]}
                type="password"
                label="API Password"
                placeholder="Optional if using API key"
              />
            <% else %>
              <div class="md:col-span-2 rounded-xl border border-sky-200 bg-sky-50 px-4 py-3 text-sm text-sky-900 dark:border-sky-900/40 dark:bg-sky-950/30 dark:text-sky-100">
                SSH discovery connects to the Plesk server and inventories domains, mail, databases, and more.
              </div>

              <.input
                field={@form[:ssh_host]}
                type="text"
                label="SSH Host"
                placeholder="plesk.example.com"
              />

              <.input
                field={@form[:ssh_port]}
                type="number"
                label="SSH Port"
                placeholder="22"
              />

              <.input
                field={@form[:ssh_username]}
                type="text"
                label="SSH Username"
                placeholder="root"
              />

              <.input
                field={@form[:ssh_auth_method]}
                type="select"
                label="SSH Auth Method"
                options={[{"Private key", "key"}, {"Password", "password"}]}
              />

              <%= if @form[:ssh_auth_method].value == "password" do %>
                <.input
                  field={@form[:ssh_password]}
                  type="password"
                  label="SSH Password"
                  placeholder="Password or sudo-capable login password"
                />
              <% else %>
                <.input
                  field={@form[:ssh_private_key_path]}
                  type="text"
                  label="SSH Private Key Path"
                  placeholder="~/.ssh/id_ed25519"
                />
              <% end %>
            <% end %>
          <% end %>

          <.input
            field={@form[:apply_dns_template]}
            type="checkbox"
            label="Apply default DNS template when creating domains"
          />
        </div>

        <%= if @form[:source].value == "ssh" do %>
          <div class="mt-6 rounded-xl border border-gray-200 dark:border-gray-700 p-4">
            <div>
              <h2 class="text-sm font-semibold text-gray-900 dark:text-white">Discovery Scope</h2>
              <p class="text-xs text-gray-500 dark:text-gray-400">
                Choose the data categories to discover from the Plesk server.
              </p>
            </div>

            <div class="mt-4 grid grid-cols-1 md:grid-cols-2 gap-3">
              <label
                :for={{key, label} <- @data_type_options}
                class="flex items-start gap-3 rounded-lg border border-gray-100 dark:border-gray-800 px-3 py-3 hover:bg-gray-50 dark:hover:bg-gray-800/50 transition-colors cursor-pointer"
              >
                <input
                  type="checkbox"
                  name="import[selected_data_types][]"
                  value={key}
                  checked={key in @form_params["selected_data_types"]}
                  class="checkbox checkbox-sm mt-0.5"
                />
                <div>
                  <p class="text-sm font-medium text-gray-900 dark:text-white">{label}</p>
                  <p class="text-xs text-gray-500 dark:text-gray-400">{key}</p>
                </div>
              </label>
            </div>
          </div>
        <% end %>

        <div class="mt-4">
          <button
            id="plesk-discover-btn"
            type="submit"
            disabled={@discovering}
            class={[
              "inline-flex items-center gap-2 px-5 py-2.5 rounded-lg text-white text-sm font-medium transition-colors shadow-sm",
              if(@discovering,
                do: "bg-indigo-400 cursor-not-allowed",
                else: "bg-indigo-600 hover:bg-indigo-500"
              )
            ]}
          >
            <%= if @discovering do %>
              <svg
                class="animate-spin w-4 h-4"
                xmlns="http://www.w3.org/2000/svg"
                fill="none"
                viewBox="0 0 24 24"
              >
                <circle
                  class="opacity-25"
                  cx="12"
                  cy="12"
                  r="10"
                  stroke="currentColor"
                  stroke-width="4"
                >
                </circle>
                <path
                  class="opacity-75"
                  fill="currentColor"
                  d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"
                >
                </path>
              </svg>
              Discovering...
            <% else %>
              <.icon name="hero-magnifying-glass" class="w-4 h-4" /> Discover
            <% end %>
          </button>
        </div>
      </.form>
    </div>

    <%!-- Create account (available during discovery) --%>
    <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800 p-6">
      <div class="flex items-center justify-between mb-3">
        <div>
          <h2 class="text-sm font-semibold text-gray-900 dark:text-white">Accounts</h2>
          <p class="text-xs text-gray-500 dark:text-gray-400">
            {length(@accounts)} account(s) available. Create new accounts before or after discovery.
          </p>
        </div>
        <button
          :if={not @creating_account}
          id="plesk-create-account-btn-discovery"
          type="button"
          phx-click="show_create_account"
          class="inline-flex items-center gap-1.5 px-3 py-2 rounded-lg border border-indigo-300 dark:border-indigo-700 text-sm font-medium text-indigo-700 dark:text-indigo-300 hover:bg-indigo-50 dark:hover:bg-indigo-900/30 transition-colors"
        >
          <.icon name="hero-user-plus" class="w-4 h-4" /> New Account
        </button>
      </div>

      <%= if @creating_account do %>
        <.form
          for={@new_account_form}
          id="create-account-form-discovery"
          phx-change="validate_account"
          phx-submit="create_account"
        >
          <div class="grid grid-cols-1 sm:grid-cols-3 gap-3 items-end">
            <.input field={@new_account_form[:name]} type="text" label="Name" placeholder="Jane Doe" />
            <.input
              field={@new_account_form[:email]}
              type="email"
              label="Email"
              placeholder="jane@example.com"
            />
            <div class="flex items-center gap-2 pb-1">
              <button
                id="create-account-submit-btn-discovery"
                type="submit"
                class="inline-flex items-center gap-1.5 px-4 py-2 rounded-lg bg-indigo-600 hover:bg-indigo-500 text-white text-sm font-medium transition-colors"
              >
                <.icon name="hero-check" class="w-4 h-4" /> Create
              </button>
              <button
                id="create-account-cancel-btn-discovery"
                type="button"
                phx-click="cancel_create_account"
                class="inline-flex items-center gap-1.5 px-3 py-2 rounded-lg border border-gray-300 dark:border-gray-600 text-sm font-medium text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-800 transition-colors"
              >
                Cancel
              </button>
            </div>
          </div>
        </.form>
      <% end %>

      <%= if @accounts != [] do %>
        <div class="mt-3 max-h-40 overflow-y-auto rounded-lg border border-gray-100 dark:border-gray-800">
          <div
            :for={account <- @accounts}
            class="flex items-center justify-between px-3 py-2 border-b border-gray-100 dark:border-gray-800 last:border-b-0 text-sm"
          >
            <span class="text-gray-800 dark:text-gray-200">{account.name}</span>
            <div class="flex items-center gap-2">
              <span class="text-xs text-gray-500 dark:text-gray-400">{account.email}</span>
              <span class={[
                "text-[10px] font-medium rounded-full px-1.5 py-0.5",
                if(account.role == "admin",
                  do: "bg-amber-100 dark:bg-amber-900/30 text-amber-700 dark:text-amber-300",
                  else: "bg-gray-100 dark:bg-gray-800 text-gray-500 dark:text-gray-400"
                )
              ]}>
                {account.role}
              </span>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # ── Restore phase ──────────────────────────────────────────────────────

  defp render_restore_phase(assigns) do
    total = length(assigns.subscriptions)
    restored = Enum.count(assigns.restore_results, fn {_, {s, _}} -> s == :ok end)
    failed = Enum.count(assigns.restore_results, fn {_, {s, _}} -> s == :error end)
    in_progress = map_size(assigns.restore_task_refs)

    assigns =
      assigns
      |> Map.put(:total_domains, total)
      |> Map.put(:restored_count, restored)
      |> Map.put(:failed_count, failed)
      |> Map.put(:in_progress_count, in_progress)

    ~H"""
    <%!-- Action bar --%>
    <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800 px-6 py-4">
      <div class="flex flex-col sm:flex-row items-start sm:items-center justify-between gap-4">
        <div>
          <h2 class="text-base font-semibold text-gray-900 dark:text-white">
            {@total_domains} domain(s) discovered
          </h2>
          <p class="text-xs text-gray-500 dark:text-gray-400 mt-0.5">
            Select categories per domain and assign accounts, then restore.
            <%= if @restored_count > 0 or @failed_count > 0 or @in_progress_count > 0 do %>
              <span class="ml-1 font-medium">
                <span :if={@in_progress_count > 0} class="text-indigo-600 dark:text-indigo-400">
                  {@in_progress_count} in progress
                </span>
                <span :if={@in_progress_count > 0 and @restored_count > 0}> · </span>
                <span :if={@restored_count > 0} class="text-emerald-600 dark:text-emerald-400">
                  {@restored_count} restored
                </span>
                <span :if={@restored_count > 0 and @failed_count > 0}> · </span>
                <span :if={@failed_count > 0} class="text-red-600 dark:text-red-400">
                  {@failed_count} failed
                </span>
              </span>
            <% end %>
          </p>
        </div>

        <div class="flex items-center gap-2">
          <button
            id="plesk-back-btn"
            phx-click="reset"
            class="inline-flex items-center gap-1.5 px-3 py-2 rounded-lg border border-gray-300 dark:border-gray-600 text-sm font-medium text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-800 transition-colors"
          >
            <.icon name="hero-arrow-left" class="w-4 h-4" /> Back
          </button>

          <button
            id="plesk-auto-create-accounts-btn"
            phx-click="auto_create_accounts"
            class="inline-flex items-center gap-1.5 px-3 py-2 rounded-lg border border-amber-300 dark:border-amber-700 text-sm font-medium text-amber-700 dark:text-amber-300 hover:bg-amber-50 dark:hover:bg-amber-900/30 transition-colors"
          >
            <.icon name="hero-user-group" class="w-4 h-4" /> Auto-create Accounts
          </button>

          <button
            id="plesk-create-account-btn"
            phx-click="show_create_account"
            class="inline-flex items-center gap-1.5 px-3 py-2 rounded-lg border border-indigo-300 dark:border-indigo-700 text-sm font-medium text-indigo-700 dark:text-indigo-300 hover:bg-indigo-50 dark:hover:bg-indigo-900/30 transition-colors"
          >
            <.icon name="hero-user-plus" class="w-4 h-4" /> New Account
          </button>

          <button
            id="plesk-download-server-creds-btn"
            phx-click="download_server_credentials"
            disabled={
              @server_creds_loading || @server_credentials != nil || @form_params["source"] != "ssh"
            }
            class={[
              "inline-flex items-center gap-1.5 px-3 py-2 rounded-lg border text-sm font-medium transition-colors",
              cond do
                @server_credentials != nil ->
                  "border-green-300 dark:border-green-700 text-green-700 dark:text-green-300 bg-green-50 dark:bg-green-900/20 cursor-default"

                @server_creds_loading ->
                  "border-gray-300 dark:border-gray-600 text-gray-400 cursor-not-allowed"

                true ->
                  "border-purple-300 dark:border-purple-700 text-purple-700 dark:text-purple-300 hover:bg-purple-50 dark:hover:bg-purple-900/30"
              end
            ]}
          >
            <%= cond do %>
              <% @server_creds_loading -> %>
                <svg
                  class="animate-spin w-4 h-4"
                  xmlns="http://www.w3.org/2000/svg"
                  fill="none"
                  viewBox="0 0 24 24"
                >
                  <circle
                    class="opacity-25"
                    cx="12"
                    cy="12"
                    r="10"
                    stroke="currentColor"
                    stroke-width="4"
                  >
                  </circle>
                  <path
                    class="opacity-75"
                    fill="currentColor"
                    d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"
                  >
                  </path>
                </svg>
                Downloading server credentials...
              <% @server_credentials != nil -> %>
                <.icon name="hero-check-circle" class="w-4 h-4" /> Credentials Loaded
              <% true -> %>
                <.icon name="hero-key" class="w-4 h-4" /> Download Server Credentials
            <% end %>
          </button>

          <button
            id="plesk-restore-all-btn"
            phx-click="review_all"
            disabled={@restore_task_refs != %{}}
            class={[
              "inline-flex items-center gap-1.5 px-4 py-2 rounded-lg text-white text-sm font-medium transition-colors shadow-sm",
              if(@restore_task_refs != %{},
                do: "bg-indigo-400 cursor-not-allowed",
                else: "bg-emerald-600 hover:bg-emerald-500"
              )
            ]}
          >
            <%= if @restore_task_refs != %{} do %>
              <svg
                class="animate-spin w-4 h-4"
                xmlns="http://www.w3.org/2000/svg"
                fill="none"
                viewBox="0 0 24 24"
              >
                <circle
                  class="opacity-25"
                  cx="12"
                  cy="12"
                  r="10"
                  stroke="currentColor"
                  stroke-width="4"
                >
                </circle>
                <path
                  class="opacity-75"
                  fill="currentColor"
                  d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"
                >
                </path>
              </svg>
              Restoring {map_size(@restore_task_refs)} domain(s)...
            <% else %>
              <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> Review all domains
            <% end %>
          </button>
        </div>
      </div>
    </div>

    <%!-- SSH credentials (shown when a loaded migration is missing its SSH password) --%>
    <%= if @ssh_needs_password do %>
      <div class="bg-amber-50 dark:bg-amber-900/20 rounded-xl border border-amber-200 dark:border-amber-700 px-6 py-4">
        <div class="flex flex-col sm:flex-row items-start sm:items-center gap-4">
          <div class="flex items-center gap-2 shrink-0">
            <.icon name="hero-key" class="w-4 h-4 text-amber-600 dark:text-amber-400" />
            <span class="text-sm font-medium text-amber-800 dark:text-amber-300">
              SSH password required
            </span>
          </div>
          <p class="text-xs text-amber-700 dark:text-amber-400 sm:flex-1">
            The SSH password was not saved. Enter it to enable file and mail content transfers.
          </p>
          <.form
            for={@form}
            id="ssh-creds-form"
            phx-change="validate"
            class="flex items-center gap-2 w-full sm:w-auto"
          >
            <.input
              field={@form[:ssh_password]}
              type="password"
              placeholder="SSH password"
              class="block w-full sm:w-64 rounded-lg border border-amber-300 dark:border-amber-600 bg-white dark:bg-gray-800 px-3 py-2 text-sm text-gray-900 dark:text-gray-100 focus:ring-2 focus:ring-amber-500 focus:border-amber-500"
            />
          </.form>
        </div>
      </div>
    <% end %>

    <%!-- Save migration --%>
    <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800 px-6 py-4">
      <form id="save-migration-form" phx-submit="save_migration" class="flex items-center gap-3">
        <.icon name="hero-bookmark" class="w-4 h-4 text-gray-400 shrink-0" />
        <input
          type="text"
          name="name"
          placeholder="Migration name (e.g. &quot;Production server 2026-04&quot;)"
          class="block w-full rounded-lg border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-800 px-3 py-2 text-sm text-gray-900 dark:text-gray-100 focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500"
        />
        <button
          id="save-migration-btn"
          type="submit"
          class="inline-flex items-center gap-1.5 px-4 py-2 rounded-lg border border-gray-300 dark:border-gray-600 text-sm font-medium text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-800 transition-colors shrink-0"
        >
          <.icon name="hero-bookmark" class="w-4 h-4" /> Save
        </button>
      </form>
    </div>

    <%!-- Assign all domains to one account --%>
    <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800 px-6 py-4">
      <div class="flex flex-col sm:flex-row items-start sm:items-center gap-3">
        <label class="text-sm font-medium text-gray-700 dark:text-gray-300 shrink-0">
          Assign all domains to:
        </label>
        <div class="flex items-center gap-2 w-full sm:w-auto">
          <select
            id="bulk-account-select"
            phx-change="set_all_accounts"
            name="email"
            class="block w-full sm:w-72 rounded-lg border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-800 px-3 py-2 text-sm text-gray-900 dark:text-gray-100 focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500"
          >
            <option value="">— Select account —</option>
            <option :for={account <- @accounts} value={account.email}>
              {account.name} ({account.email}) [{account.role}]
            </option>
          </select>
        </div>
      </div>
    </div>

    <%!-- Create account inline --%>
    <%= if @creating_account do %>
      <div class="bg-indigo-50 dark:bg-indigo-950/30 rounded-xl border border-indigo-200 dark:border-indigo-800 p-6">
        <h3 class="text-sm font-semibold text-indigo-900 dark:text-indigo-200 mb-3">
          Create New Account
        </h3>
        <.form
          for={@new_account_form}
          id="create-account-form"
          phx-change="validate_account"
          phx-submit="create_account"
        >
          <div class="grid grid-cols-1 sm:grid-cols-3 gap-3 items-end">
            <.input field={@new_account_form[:name]} type="text" label="Name" placeholder="Jane Doe" />
            <.input
              field={@new_account_form[:email]}
              type="email"
              label="Email"
              placeholder="jane@example.com"
            />
            <div class="flex items-center gap-2 pb-1">
              <button
                id="create-account-submit-btn"
                type="submit"
                class="inline-flex items-center gap-1.5 px-4 py-2 rounded-lg bg-indigo-600 hover:bg-indigo-500 text-white text-sm font-medium transition-colors"
              >
                <.icon name="hero-check" class="w-4 h-4" /> Create
              </button>
              <button
                id="create-account-cancel-btn"
                type="button"
                phx-click="cancel_create_account"
                class="inline-flex items-center gap-1.5 px-3 py-2 rounded-lg border border-gray-300 dark:border-gray-600 text-sm font-medium text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-800 transition-colors"
              >
                Cancel
              </button>
            </div>
          </div>
        </.form>
      </div>
    <% end %>

    <%!-- Warnings --%>
    <%= if @ssh_discovery && @ssh_discovery.warnings != [] do %>
      <div class="rounded-xl border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-900 dark:border-amber-900/40 dark:bg-amber-950/30 dark:text-amber-100">
        <h3 class="font-semibold">Discovery Warnings</h3>
        <ul class="mt-2 space-y-1 text-xs">
          <li :for={warning <- @ssh_discovery.warnings}>{warning}</li>
        </ul>
      </div>
    <% end %>

    <%!-- Domain restore cards grouped by owner --%>
    <% sub_groups =
      @subscriptions
      |> Enum.group_by(fn sub ->
        Map.get(sub, :owner_login) || Map.get(sub, :system_user) || sub.domain
      end)
      |> Enum.sort_by(fn {k, _} -> String.downcase(k) end) %>
    <div class="space-y-6">
      <%= for {group_key, group_subs} <- sub_groups do %>
        <% sample = hd(group_subs) %>
        <% g_name = Map.get(sample, :owner_name) %>
        <% g_email = Map.get(sample, :owner_email) %>
        <% g_login = Map.get(sample, :owner_login) %>
        <% g_sysusers =
          group_subs
          |> Enum.map(&Map.get(&1, :system_user))
          |> Enum.filter(&is_binary/1)
          |> Enum.uniq()
          |> Enum.sort() %>
        <% g_assigned =
          group_subs
          |> Enum.map(&get_in(@domain_configs, [&1.domain, :account_email]))
          |> Enum.filter(&(is_binary(&1) and &1 != ""))
          |> List.first() %>
        <div class="rounded-xl border border-gray-200 dark:border-gray-700 overflow-hidden">
          <%!-- Group header --%>
          <div class="px-5 py-3 bg-gray-50 dark:bg-gray-800/60 border-b border-gray-200 dark:border-gray-700 flex flex-col sm:flex-row sm:items-center gap-3 justify-between">
            <div class="min-w-0">
              <div class="flex items-center gap-2 flex-wrap">
                <.icon name="hero-user-circle" class="w-4 h-4 text-gray-400 shrink-0" />
                <span class="text-sm font-semibold text-gray-900 dark:text-white">
                  {g_name || g_login || group_key}
                </span>
                <%= if g_email do %>
                  <span class="text-xs text-gray-400">{g_email}</span>
                <% end %>
                <span class="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-gray-100 dark:bg-gray-800 text-gray-600 dark:text-gray-300 shrink-0">
                  {length(group_subs)} {if length(group_subs) == 1, do: "domain", else: "domains"}
                </span>
              </div>
              <%= if g_sysusers != [] do %>
                <p class="text-xs text-gray-400 dark:text-gray-500 mt-1 ml-6">
                  <.icon name="hero-command-line" class="w-3 h-3 inline mr-1" />{Enum.join(
                    g_sysusers,
                    ", "
                  )}
                </p>
              <% end %>
            </div>
            <form
              id={"group-account-form-#{group_key}"}
              phx-change="set_account_for_group"
              class="shrink-0"
            >
              <input type="hidden" name="group_key" value={group_key} />
              <select
                id={"group-account-select-#{group_key}"}
                name="email"
                class="block w-full sm:w-56 rounded-lg border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-800 px-2.5 py-1.5 text-xs text-gray-900 dark:text-gray-100 focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500"
              >
                <option value="">— Assign all to account —</option>
                <option
                  :for={account <- @accounts}
                  value={account.email}
                  selected={g_assigned == account.email}
                >
                  {account.name} ({account.email}) [{account.role}]
                </option>
              </select>
            </form>
          </div>
          <%!-- Domain cards within group --%>
          <div class="p-4 space-y-4">
            <%= for sub <- group_subs do %>
              <% config = Map.get(@domain_configs, sub.domain, %{}) %>
              <% categories = Map.get(config, :categories, MapSet.new()) %>
              <% counts = Map.get(config, :inventory_counts, %{}) %>
              <% result = Map.get(@restore_results, sub.domain) %>
              <% progress = Map.get(@restore_progress, sub.domain) %>
              <% restoring = progress != nil %>
              <% has_result = result != nil %>
              <% result_ok = match?({:ok, _}, result) %>
              <div
                id={"domain-card-#{sub.domain}"}
                class={[
                  "bg-white dark:bg-gray-900 rounded-xl border p-5 transition-all",
                  if(has_result and result_ok,
                    do: "border-emerald-300 dark:border-emerald-700",
                    else: ""
                  ),
                  if(has_result and not result_ok,
                    do: "border-red-300 dark:border-red-700",
                    else: ""
                  ),
                  if(restoring, do: "border-indigo-300 dark:border-indigo-700", else: ""),
                  if(not has_result and not restoring,
                    do: "border-gray-200 dark:border-gray-800",
                    else: ""
                  )
                ]}
              >
                <%!-- Header --%>
                <div class="flex flex-col sm:flex-row items-start sm:items-center justify-between gap-3">
                  <div class="flex items-center gap-3">
                    <div class={[
                      "w-2 h-2 rounded-full shrink-0",
                      if(has_result and result_ok, do: "bg-emerald-500", else: ""),
                      if(has_result and not result_ok, do: "bg-red-500", else: ""),
                      if(restoring, do: "bg-indigo-500 animate-pulse", else: ""),
                      if(not has_result and not restoring,
                        do: "bg-gray-300 dark:bg-gray-600",
                        else: ""
                      )
                    ]}>
                    </div>
                    <div>
                      <div class="flex items-center gap-2">
                        <h3 class="text-sm font-semibold text-gray-900 dark:text-white">
                          {sub.domain}
                        </h3>
                        <%= if Map.get(sub, :system_user) do %>
                          <span class="text-xs font-mono text-gray-400 dark:text-gray-500">
                            {sub.system_user}
                          </span>
                        <% end %>
                      </div>
                      <%= if Map.get(sub, :subdomains, []) != [] do %>
                        <p class="text-xs text-gray-400 dark:text-gray-500 mt-0.5">
                          <.icon name="hero-arrow-turn-down-right" class="w-3 h-3 inline" />
                          {sub.subdomains |> Enum.map(& &1.name) |> Enum.join(", ")}
                        </p>
                      <% end %>
                    </div>
                  </div>
                </div>

                <%!-- Categories --%>
                <div class="mt-3 grid grid-cols-2 md:grid-cols-4 gap-2">
                  <%= for {key, label, icon} <- @restore_categories do %>
                    <% count = Map.get(counts, key, 0) %>
                    <% selected = MapSet.member?(categories, key) %>
                    <% limited_warning = Map.get(@limited_categories, key) %>
                    <button
                      type="button"
                      phx-click="toggle_category"
                      phx-value-domain={sub.domain}
                      phx-value-category={key}
                      disabled={count == 0}
                      title={limited_warning}
                      class={[
                        "flex items-center gap-2 rounded-lg border px-3 py-2 text-left text-xs transition-all",
                        if(count == 0,
                          do: "opacity-40 cursor-not-allowed border-gray-100 dark:border-gray-800",
                          else: "cursor-pointer"
                        ),
                        if(selected and count > 0,
                          do:
                            "border-indigo-300 dark:border-indigo-700 bg-indigo-50 dark:bg-indigo-950/30 text-indigo-700 dark:text-indigo-300",
                          else: ""
                        ),
                        if(not selected and count > 0,
                          do:
                            "border-gray-200 dark:border-gray-700 hover:border-gray-300 dark:hover:border-gray-600 text-gray-600 dark:text-gray-400",
                          else: ""
                        )
                      ]}
                    >
                      <.icon name={icon} class="w-3.5 h-3.5 shrink-0" />
                      <span class="truncate">{label}</span>
                      <.icon
                        :if={limited_warning && count > 0}
                        name="hero-exclamation-triangle"
                        class="w-3 h-3 text-amber-500 shrink-0"
                      />
                      <span class={[
                        "ml-auto text-[10px] font-semibold rounded-full px-1.5 py-0.5 shrink-0",
                        if(selected and count > 0,
                          do: "bg-indigo-200 dark:bg-indigo-800 text-indigo-700 dark:text-indigo-300",
                          else: "bg-gray-100 dark:bg-gray-800 text-gray-500 dark:text-gray-400"
                        )
                      ]}>
                        {count}
                      </span>
                    </button>
                  <% end %>
                </div>

                <%!-- Web files destination — one row per target (main domain + each subdomain) --%>
                <%= if MapSet.member?(categories, "web_files") do %>
                  <% web_targets = [
                    {"", sub.domain}
                    | Enum.map(Map.get(sub, :subdomains, []), fn sd -> {sd.name, sd.full_name} end)
                  ] %>
                  <div class="mt-3 space-y-2">
                    <%= for {target, target_label} <- web_targets do %>
                      <% t_config = get_in(config, [:s3_targets, target]) || %{} %>
                      <% t_s3_import = Map.get(t_config, :s3_import, false) %>
                      <% has_backend = not is_nil(get_in(@domain_s3_backends, [sub.domain, target])) %>
                      <div class="flex items-center gap-2">
                        <span
                          class="text-xs text-gray-500 dark:text-gray-400 w-28 truncate shrink-0"
                          title={target_label}
                        >
                          <.icon name="hero-folder" class="w-3 h-3 inline" />
                          {if(target == "", do: "(root)", else: target)}
                        </span>
                        <%= if t_s3_import do %>
                          <span class="flex-1 rounded-lg border border-sky-300 dark:border-sky-700 bg-sky-50 dark:bg-sky-950/30 px-2.5 py-1.5 text-xs text-sky-700 dark:text-sky-300 font-mono">
                            <.icon name="hero-cloud-arrow-up" class="w-3 h-3 inline" />
                            <%= if has_backend do %>
                              {get_in(@domain_s3_backends, [sub.domain, target]).bucket}
                            <% else %>
                              {Map.get(t_config, :s3_bucket, "S3 bucket")}
                            <% end %>
                          </span>
                        <% else %>
                          <%= if target == "" do %>
                            <form
                              id={"web-path-form-#{sub.domain}"}
                              phx-change="set_web_path"
                              class="flex-1"
                            >
                              <input type="hidden" name="domain" value={sub.domain} />
                              <input
                                type="text"
                                id={"web-path-#{sub.domain}"}
                                name="path"
                                value={Map.get(config, :web_files_path, "/var/www/#{sub.domain}")}
                                class="block w-full rounded-lg border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-800 px-2.5 py-1.5 text-xs text-gray-900 dark:text-gray-100 font-mono focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500"
                                placeholder="/var/www/#{sub.domain}"
                              />
                            </form>
                          <% else %>
                            <span class="flex-1 px-2.5 py-1.5 text-xs text-gray-400 dark:text-gray-500 font-mono truncate">
                              {Map.get(config, :web_files_path, "/var/www/#{sub.domain}")}/{target}.{sub.domain}/
                            </span>
                          <% end %>
                        <% end %>
                        <button
                          id={"s3-import-toggle-#{sub.domain}-#{target}"}
                          type="button"
                          phx-click="toggle_s3_import"
                          phx-value-domain={sub.domain}
                          phx-value-target={target}
                          title={
                            if(t_s3_import, do: "Switch to local path", else: "Upload to S3 bucket")
                          }
                          class={[
                            "flex-shrink-0 inline-flex items-center gap-1 px-2 py-1.5 rounded-lg border text-xs font-medium transition-colors",
                            if(t_s3_import,
                              do:
                                "border-sky-300 dark:border-sky-700 bg-sky-100 dark:bg-sky-900/40 text-sky-700 dark:text-sky-300",
                              else:
                                "border-gray-300 dark:border-gray-600 text-gray-500 dark:text-gray-400 hover:bg-sky-50 dark:hover:bg-sky-950/30 hover:border-sky-300 dark:hover:border-sky-700 hover:text-sky-700 dark:hover:text-sky-300"
                            )
                          ]}
                        >
                          <.icon name="hero-cloud-arrow-up" class="w-3 h-3" /> S3
                        </button>
                      </div>
                      <%!-- Inline S3 credentials for this target --%>
                      <%= if t_s3_import && not has_backend do %>
                        <.s3_destination
                          domain={sub.domain}
                          target={target}
                          config={t_config}
                          connections={@s3_connections}
                          buckets={Map.get(@s3_bucket_lists, {sub.domain, target}, [])}
                          busy={MapSet.member?(@s3_busy, {sub.domain, target})}
                        />
                      <% end %>
                    <% end %>
                  </div>
                <% end %>

                <%!-- Select/deselect all and restore --%>
                <div class="mt-3 flex items-center justify-between">
                  <div class="flex items-center gap-2">
                    <button
                      type="button"
                      phx-click="select_all_categories"
                      phx-value-domain={sub.domain}
                      class="text-xs text-indigo-600 dark:text-indigo-400 hover:underline"
                    >
                      Select all
                    </button>
                    <span class="text-gray-300 dark:text-gray-600">·</span>
                    <button
                      type="button"
                      phx-click="deselect_all_categories"
                      phx-value-domain={sub.domain}
                      class="text-xs text-gray-500 dark:text-gray-400 hover:underline"
                    >
                      Clear
                    </button>
                  </div>

                  <button
                    id={"restore-btn-#{sub.domain}"}
                    type="button"
                    phx-click="review_domain"
                    phx-value-domain={sub.domain}
                    disabled={restoring or (has_result and result_ok)}
                    class={[
                      "inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-medium transition-colors",
                      if(has_result and result_ok,
                        do:
                          "bg-emerald-100 dark:bg-emerald-900/30 text-emerald-700 dark:text-emerald-300 cursor-default",
                        else: ""
                      ),
                      if(restoring,
                        do:
                          "bg-indigo-100 dark:bg-indigo-900/30 text-indigo-700 dark:text-indigo-300 cursor-not-allowed",
                        else: ""
                      ),
                      if(not restoring and not (has_result and result_ok),
                        do: "bg-emerald-600 hover:bg-emerald-500 text-white shadow-sm",
                        else: ""
                      )
                    ]}
                  >
                    <%= cond do %>
                      <% has_result and result_ok -> %>
                        <.icon name="hero-check" class="w-3.5 h-3.5" /> Configuration finished
                      <% restoring -> %>
                        <svg
                          class="animate-spin w-3.5 h-3.5"
                          xmlns="http://www.w3.org/2000/svg"
                          fill="none"
                          viewBox="0 0 24 24"
                        >
                          <circle
                            class="opacity-25"
                            cx="12"
                            cy="12"
                            r="10"
                            stroke="currentColor"
                            stroke-width="4"
                          >
                          </circle>
                          <path
                            class="opacity-75"
                            fill="currentColor"
                            d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"
                          >
                          </path>
                        </svg>
                        Restoring...
                      <% true -> %>
                        <.icon name="hero-arrow-down-tray" class="w-3.5 h-3.5" /> Review import
                    <% end %>
                  </button>
                </div>

                <%!-- Restore progress --%>
                <%= if restoring do %>
                  <% completed = Map.get(progress, :completed, %{}) %>
                  <div class="mt-3 rounded-lg px-4 py-3 bg-indigo-50 dark:bg-indigo-950/20 border border-indigo-100 dark:border-indigo-900/40">
                    <%!-- Completed categories --%>
                    <%= for {cat, cat_result} <- completed do %>
                      <div class="flex items-center gap-1.5 mb-1">
                        <.icon
                          name="hero-check-circle-solid"
                          class={[
                            "w-3.5 h-3.5 shrink-0",
                            if(cat_result.failed > 0,
                              do: "text-amber-500",
                              else: "text-emerald-500"
                            )
                          ]}
                        />
                        <span class="text-xs text-gray-600 dark:text-gray-400">
                          {category_display_name(cat)}
                          <span class="text-[10px] text-gray-400 dark:text-gray-500 ml-1">
                            {cat_result.created} created{if(cat_result.skipped > 0,
                              do: ", #{cat_result.skipped} skipped",
                              else: ""
                            )}{if(cat_result.failed > 0,
                              do: ", #{cat_result.failed} failed",
                              else: ""
                            )}
                          </span>
                        </span>
                      </div>
                    <% end %>

                    <%!-- Current category --%>
                    <div class="flex items-center gap-1.5 mb-2">
                      <svg
                        class="w-3.5 h-3.5 shrink-0 animate-spin text-indigo-500"
                        xmlns="http://www.w3.org/2000/svg"
                        fill="none"
                        viewBox="0 0 24 24"
                      >
                        <circle
                          class="opacity-25"
                          cx="12"
                          cy="12"
                          r="10"
                          stroke="currentColor"
                          stroke-width="4"
                        >
                        </circle>
                        <path
                          class="opacity-75"
                          fill="currentColor"
                          d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"
                        >
                        </path>
                      </svg>
                      <div class="flex-1">
                        <span class="text-xs font-medium text-indigo-800 dark:text-indigo-200 block">
                          <%= if progress.category do %>
                            {category_display_name(progress.category)}...
                          <% else %>
                            Starting...
                          <% end %>
                        </span>
                        <%= if is_binary(progress.status) do %>
                          <span class="text-[10px] text-indigo-600 dark:text-indigo-400 block mt-0.5">
                            {progress.status}
                          </span>
                        <% end %>
                      </div>
                      <span class="text-[10px] text-indigo-500 dark:text-indigo-400 ml-auto">
                        {progress.index}/{progress.total}
                      </span>
                    </div>

                    <div class="h-1.5 w-full rounded-full bg-indigo-100 dark:bg-indigo-900/40 overflow-hidden">
                      <div
                        class="h-full rounded-full bg-indigo-500 transition-all duration-500 ease-out"
                        style={"width: #{if(progress.total > 0, do: round(progress.index / progress.total * 100), else: 0)}%"}
                      >
                      </div>
                    </div>
                  </div>
                <% end %>

                <%!-- Restore result --%>
                <%= if has_result do %>
                  <% {status, result_data} = result %>
                  <div class={[
                    "mt-3 rounded-lg px-4 py-3 text-xs",
                    if(status == :ok,
                      do:
                        "bg-emerald-50 dark:bg-emerald-950/20 border border-emerald-100 dark:border-emerald-900/40",
                      else:
                        "bg-red-50 dark:bg-red-950/20 border border-red-100 dark:border-red-900/40"
                    )
                  ]}>
                    <p class={[
                      "font-semibold mb-1",
                      if(status == :ok,
                        do: "text-emerald-800 dark:text-emerald-200",
                        else: "text-red-800 dark:text-red-200"
                      )
                    ]}>
                      <%= cond do %>
                        <% status == :ok -> %>
                          Domain {format_domain_status(result_data.domain_status)}
                        <% true -> %>
                          Failed: {format_domain_status(result_data.domain_status)}
                      <% end %>
                    </p>

                    <div class="grid grid-cols-2 md:grid-cols-4 gap-1 mt-2">
                      <%= for {cat, cat_result} <- Map.get(result_data, :categories, %{}) do %>
                        <div class="flex items-center justify-between rounded px-2 py-1 bg-white/60 dark:bg-gray-900/40">
                          <span class="text-gray-600 dark:text-gray-400">{cat}</span>
                          <span>
                            <span
                              :if={Map.get(cat_result, :created, 0) > 0}
                              class="text-emerald-600 dark:text-emerald-400"
                            >
                              {cat_result.created}✓
                            </span>
                            <span
                              :if={Map.get(cat_result, :skipped, 0) > 0}
                              class="text-amber-600 dark:text-amber-400 ml-1"
                            >
                              {cat_result.skipped}⊘
                            </span>
                            <span
                              :if={Map.get(cat_result, :failed, 0) > 0}
                              class="text-red-600 dark:text-red-400 ml-1"
                            >
                              {cat_result.failed}✗
                            </span>
                            <span
                              :if={Map.get(cat_result, :note)}
                              class="text-gray-400 ml-1"
                              title={cat_result.note}
                            >
                              ℹ
                            </span>
                          </span>
                        </div>
                      <% end %>
                    </div>

                    <%!-- Show errors --%>
                    <% all_errors =
                      result_data
                      |> Map.get(:categories, %{})
                      |> Enum.flat_map(fn {cat, r} ->
                        Enum.map(Map.get(r, :errors, []), &"#{cat}: #{&1}")
                      end) %>
                    <%= if all_errors != [] do %>
                      <details class="mt-2">
                        <summary class="text-red-600 dark:text-red-400 cursor-pointer">
                          {length(all_errors)} error(s)
                        </summary>
                        <ul class="mt-1 space-y-0.5 text-red-600 dark:text-red-300">
                          <li :for={err <- all_errors}>{err}</li>
                        </ul>
                      </details>
                    <% end %>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # ── Discovery logic ────────────────────────────────────────────────────

  defp run_discovery(params) do
    source = normalize_string(params["source"])

    case source_domain_names_with_groups(source, params) do
      {:ok, _names, _owner_groups, ssh_discovery, subscriptions} ->
        {:ok, ssh_discovery, subscriptions}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp source_domain_names_with_groups("backup", params) do
    backup_path = normalize_string(params["backup_path"])

    if backup_path == "" do
      {:error, "Backup path is required for backup source."}
    else
      with {:ok, subscriptions} <- Importer.backup_subscriptions(backup_path) do
        subscriptions =
          filter_subscriptions(
            subscriptions,
            normalize_string(params["owner_login"]),
            normalize_string(params["system_user"])
          )

        # Merge subdomains under parent domains
        merged = SSHProbe.merge_subdomains(subscriptions)
        names = merged |> Enum.map(& &1.domain) |> Enum.uniq() |> Enum.sort()

        owner_groups =
          subscriptions
          |> Enum.group_by(fn sub -> {sub.owner_login, sub.owner_type, sub.system_user} end)
          |> Enum.map(fn {{owner_login, owner_type, system_user}, subs} ->
            %{
              owner_login: owner_login,
              owner_type: owner_type,
              system_user: system_user,
              count: length(subs)
            }
          end)
          |> Enum.sort_by(&{&1.owner_login || "", &1.system_user || ""})

        {:ok, names, owner_groups, nil, merged}
      end
    end
  end

  defp source_domain_names_with_groups("api", params) do
    api_url = normalize_string(params["api_url"])

    if api_url == "" do
      {:error, "API URL is required for API source."}
    else
      auth_opts = [
        api_key: normalize_string(params["api_key"]),
        username: normalize_string(params["api_username"]),
        password: normalize_string(params["api_password"])
      ]

      case Importer.api_domain_names(api_url, auth_opts) do
        {:ok, names} ->
          subscriptions =
            Enum.map(names, fn name ->
              %{
                domain: name,
                owner_login: nil,
                owner_type: nil,
                owner_name: nil,
                owner_email: nil,
                system_user: nil,
                subdomains: []
              }
            end)

          {:ok, names, [], nil, subscriptions}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp source_domain_names_with_groups("ssh", params) do
    ssh_opts = %{
      host: normalize_string(params["ssh_host"]),
      port: normalize_string(params["ssh_port"]),
      username: normalize_string(params["ssh_username"]),
      auth_method: normalize_string(params["ssh_auth_method"]),
      private_key_path: normalize_string(params["ssh_private_key_path"]),
      password: normalize_string(params["ssh_password"])
    }

    cond do
      params["selected_data_types"] == [] ->
        {:error, "Select at least one data type for SSH discovery."}

      true ->
        with {:ok, %{subscriptions: subscriptions} = ssh_discovery} <-
               SSHProbe.discover(ssh_opts, selected_data_types_from_params(params)) do
          names = subscriptions |> Enum.map(& &1.domain) |> Enum.uniq() |> Enum.sort()

          owner_groups =
            subscriptions
            |> Enum.group_by(fn sub -> {sub.owner_login, sub.owner_type, sub.system_user} end)
            |> Enum.map(fn {{owner_login, owner_type, system_user}, subs} ->
              %{
                owner_login: owner_login,
                owner_type: owner_type,
                system_user: system_user,
                count: length(subs)
              }
            end)
            |> Enum.sort_by(&{&1.owner_login || "", &1.system_user || ""})

          {:ok, names, owner_groups, ssh_discovery, subscriptions}
        end
    end
  end

  defp source_domain_names_with_groups(_other, _params),
    do: {:error, "Unsupported source. Choose backup, api, or ssh."}

  # ── Domain config helpers ──────────────────────────────────────────────

  defp build_domain_configs(subscriptions, ssh_discovery) do
    Map.new(subscriptions, fn sub ->
      counts = count_inventory_per_domain(sub, ssh_discovery)

      selected =
        @restore_category_keys
        |> Enum.filter(fn key -> Map.get(counts, key, 0) > 0 end)
        |> MapSet.new()

      config = %{
        categories: selected,
        account_email: "",
        inventory_counts: counts
      }

      {sub.domain, config}
    end)
  end

  defp count_inventory_per_domain(subscription, nil) do
    %{
      "subdomains" => subscription |> Map.get(:subdomains, []) |> length(),
      "dns" => 0,
      "web_files" => 0,
      "mail_accounts" => 0,
      "mail_content" => 0,
      "databases" => 0,
      "db_users" => 0,
      "cron_jobs" => 0,
      "ftp_accounts" => 0,
      "ssl_certificates" => 0
    }
  end

  defp count_inventory_per_domain(subscription, discovery) do
    domain = subscription.domain
    system_user = Map.get(subscription, :system_user)
    inv = discovery.inventory

    %{
      "subdomains" => subscription |> Map.get(:subdomains, []) |> length(),
      "dns" => inv |> Map.get("dns_records", []) |> Enum.count(&(&1.domain == domain)),
      "web_files" => inv |> Map.get("web_files", []) |> Enum.count(&(&1.domain == domain)),
      "mail_accounts" =>
        inv |> Map.get("mail_accounts", []) |> Enum.count(&(&1.domain == domain)),
      "mail_content" => inv |> Map.get("mail_content", []) |> Enum.count(&(&1.domain == domain)),
      "databases" => inv |> Map.get("databases", []) |> Enum.count(&(&1.domain == domain)),
      "db_users" => inv |> Map.get("db_users", []) |> Enum.count(&(&1.domain == domain)),
      "cron_jobs" => inv |> Map.get("cron_jobs", []) |> Enum.count(&(&1.domain == domain)),
      "ftp_accounts" =>
        inv
        |> Map.get("ftp_accounts", [])
        |> Enum.count(fn item ->
          Map.get(item, :domain) == domain ||
            (system_user != nil && Map.get(item, :login) == system_user)
        end),
      "ssl_certificates" =>
        inv |> Map.get("ssl_certificates", []) |> Enum.count(&(&1.domain == domain))
    }
  end

  defp filter_inventory_for_domain(nil, _domain, _subscription), do: %{}

  defp filter_inventory_for_domain(discovery, domain, subscription) do
    system_user = if subscription, do: Map.get(subscription, :system_user)

    Map.new(discovery.inventory, fn {key, items} ->
      filtered =
        Enum.filter(items, fn item ->
          Map.get(item, :domain) == domain ||
            (key == "ftp_accounts" && system_user != nil &&
               Map.get(item, :login) == system_user)
        end)

      {key, filtered}
    end)
  end

  defp build_ssh_opts(params) do
    case params["source"] do
      "ssh" ->
        %{
          host: normalize_string(params["ssh_host"]),
          port: normalize_string(params["ssh_port"]),
          username: normalize_string(params["ssh_username"]),
          auth_method: normalize_string(params["ssh_auth_method"]),
          private_key_path: normalize_string(params["ssh_private_key_path"]),
          password: normalize_string(params["ssh_password"])
        }

      _ ->
        nil
    end
  end

  # ── Account & scope helpers ────────────────────────────────────────────

  defp load_accounts do
    Accounts.list_users()
    |> Enum.map(fn user ->
      %{id: user.id, name: user.name, email: user.email, role: user.role}
    end)
  end

  # Returns a nested map of %{domain_name => %{target => backend}} for domains
  # that have S3 backends configured with credentials. `target` is the subdomain
  # name (empty string "" = whole-domain backend, "sub1" = per-subdomain backend).
  # Only backends with url_path="" are included (path-scoped backends are not used
  # for import).
  defp load_domain_s3_backends(subscriptions) do
    import Ecto.Query

    alias Hostctl.Repo
    alias Hostctl.Hosting.{Domain, DomainS3Backend}

    domain_names = Enum.map(subscriptions, & &1.domain)

    if domain_names == [] do
      %{}
    else
      domains =
        Repo.all(from d in Domain, where: d.name in ^domain_names, select: {d.name, d.id})

      domain_id_map = Map.new(domains)

      backends =
        Repo.all(
          from b in DomainS3Backend,
            where: b.domain_id in ^Map.values(domain_id_map),
            where: b.url_path == "",
            where: not is_nil(b.access_key_id),
            where: b.access_key_id != ""
        )

      Enum.reduce(domains, %{}, fn {name, id}, acc ->
        domain_backends =
          backends
          |> Enum.filter(&(&1.domain_id == id))
          |> Map.new(fn b -> {b.subdomain, b} end)

        if domain_backends == %{} do
          acc
        else
          Map.put(acc, name, domain_backends)
        end
      end)
    end
  end

  defp resolve_scope(""), do: {:error, "No account selected. Assign an account to this domain."}

  defp resolve_scope(email) when is_binary(email) do
    case Accounts.get_user_by_email(email) do
      nil ->
        {:error, "User not found: #{email}"}

      user ->
        scope = Scope.for_user(user)

        case Hostctl.Isolation.get_identity(scope) do
          %{state: state} when state in [:provisioning, :failed] ->
            case Hostctl.Isolation.Runtime.provision_identity(scope) do
              {:ok, _} ->
                {:ok, scope}

              {:error, _} ->
                {:error, "Account isolation is not ready. Retry enrollment before importing."}
            end

          _ ->
            {:ok, scope}
        end
    end
  end

  defp format_domain_status(:created), do: "created"
  defp format_domain_status(:exists), do: "already existed"
  defp format_domain_status({:failed, reason}), do: reason
  defp format_domain_status(other), do: inspect(other)

  defp category_display_name(key) do
    case Enum.find(@restore_categories, fn {k, _, _} -> k == key end) do
      {_, label, _} -> label
      nil -> key
    end
  end

  # ── Shared helpers ─────────────────────────────────────────────────────

  defp normalize_string(value) when is_binary(value), do: String.trim(value)
  defp normalize_string(_), do: ""

  # Updates a config field only when the value is a non-nil string.
  defp put_s3_field(config, _key, nil), do: config
  defp put_s3_field(config, key, value) when is_binary(value), do: Map.put(config, key, value)
  defp put_s3_field(config, key, value) when is_boolean(value), do: Map.put(config, key, value)

  defp normalize_form_params(params) when is_map(params) do
    @default_params
    |> Map.merge(params)
    |> Map.put("selected_data_types", selected_data_types_from_params(params))
  end

  defp selected_data_types_from_params(params) do
    case Map.get(params, "selected_data_types") do
      list when is_list(list) ->
        list
        |> Enum.map(&normalize_string/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()

      value when is_binary(value) ->
        value
        |> normalize_string()
        |> case do
          "" -> @default_data_types
          item -> [item]
        end

      _ ->
        @default_data_types
    end
  end

  defp normalize_boolean(value) when value in [true, "true", "on", "1", 1], do: true
  defp normalize_boolean(_), do: false

  defp filter_subscriptions(subscriptions, owner_login_filter, system_user_filter) do
    normalized_owner = normalize_filter_value(owner_login_filter)
    normalized_system = normalize_filter_value(system_user_filter)

    Enum.filter(subscriptions, fn sub ->
      owner_ok? =
        is_nil(normalized_owner) or
          String.downcase(sub.owner_login || "") == normalized_owner

      system_ok? =
        is_nil(normalized_system) or
          String.downcase(sub.system_user || "") == normalized_system

      owner_ok? and system_ok?
    end)
  end

  defp normalize_filter_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_filter_value(_), do: nil

  defp changeset_error_summary(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join("; ", fn {field, errors} ->
      "#{field}: #{Enum.join(errors, ", ")}"
    end)
  end

  # ── Migration persistence helpers ──────────────────────────────────────

  defp load_saved_migrations(socket) do
    migrations = Plesk.list_migrations(socket.assigns.current_scope)
    assign(socket, :saved_migrations, migrations)
  end

  defp sanitize_source_params(params) do
    # Strip passwords/keys from saved params for security
    params
    |> Map.take([
      "source",
      "backup_path",
      "owner_login",
      "system_user",
      "api_url",
      "ssh_host",
      "ssh_port",
      "ssh_username",
      "ssh_auth_method",
      "apply_dns_template"
    ])
  end

  defp serialize_subscriptions(subscriptions) do
    Enum.map(subscriptions, fn sub ->
      sub
      |> Map.from_struct()
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
    end)
  rescue
    # subscriptions may already be plain maps
    _ -> Enum.map(subscriptions, &ensure_string_keys/1)
  end

  defp serialize_inventory(nil), do: %{}

  defp serialize_inventory(discovery) do
    Map.new(discovery.inventory, fn {key, items} ->
      {key, Enum.map(items, &ensure_string_keys/1)}
    end)
  end

  defp serialize_domain_configs(configs) do
    Map.new(configs, fn {domain, config} ->
      {domain,
       %{
         "account_email" => Map.get(config, :account_email, ""),
         "web_files_path" => Map.get(config, :web_files_path, "/var/www/#{domain}"),
         "s3_targets" => Hostctl.Plesk.S3Import.encode_targets(Map.get(config, :s3_targets, %{})),
         "categories" => config |> Map.get(:categories, MapSet.new()) |> MapSet.to_list(),
         "inventory_counts" => config |> Map.get(:inventory_counts, %{}) |> ensure_string_keys()
       }}
    end)
  end

  defp serialize_restore_results(results) do
    Map.new(results, fn {domain, {status, data}} ->
      categories =
        data
        |> Map.get(:categories, %{})
        |> Map.new(fn {cat, r} -> {cat, ensure_string_keys(r)} end)

      {domain,
       %{
         "status" => to_string(status),
         "domain_status" => serialize_domain_status(data.domain_status),
         "categories" => categories
       }}
    end)
  end

  defp serialize_domain_status(:created), do: "created"
  defp serialize_domain_status(:exists), do: "exists"
  defp serialize_domain_status({:failed, reason}), do: %{"failed" => reason}
  defp serialize_domain_status(other), do: inspect(other)

  defp deserialize_subscriptions(subscriptions) do
    Enum.map(subscriptions, fn sub ->
      sub = ensure_atom_keys(sub)

      subdomains =
        sub
        |> Map.get(:subdomains, [])
        |> Enum.map(&ensure_atom_keys/1)

      Map.put(sub, :subdomains, subdomains)
    end)
  end

  defp deserialize_inventory(inventory) when inventory == %{}, do: nil

  defp deserialize_inventory(inventory) do
    inv =
      Map.new(inventory, fn {key, items} ->
        {key, Enum.map(items, &ensure_atom_keys/1)}
      end)

    %{inventory: inv, subscriptions: [], warnings: []}
  end

  defp deserialize_domain_configs(configs) do
    Map.new(configs, fn {domain, config} ->
      config = ensure_atom_keys(config)

      categories =
        config
        |> Map.get(:categories, [])
        |> MapSet.new()

      inventory_counts =
        config
        |> Map.get(:inventory_counts, %{})
        |> ensure_string_keys()

      {domain,
       %{
         categories: categories,
         web_files_path: Map.get(config, :web_files_path, "/var/www/#{domain}"),
         s3_targets: Hostctl.Plesk.S3Import.decode_targets(Map.get(config, :s3_targets, %{})),
         account_email: Map.get(config, :account_email, ""),
         inventory_counts: inventory_counts
       }}
    end)
  end

  defp deserialize_restore_results(results) when results == %{}, do: %{}

  defp deserialize_restore_results(results) do
    Map.new(results, fn {domain, data} ->
      data = ensure_atom_keys(data)
      status = if data.status == "ok", do: :ok, else: :error

      domain_status =
        case data.domain_status do
          "created" -> :created
          "exists" -> :exists
          %{"failed" => reason} -> {:failed, reason}
          other -> {:failed, inspect(other)}
        end

      categories =
        data
        |> Map.get(:categories, %{})
        |> Map.new(fn {cat, r} -> {cat, ensure_atom_keys(r)} end)

      {domain, {status, %{domain: domain, domain_status: domain_status, categories: categories}}}
    end)
  end

  defp migration_status(restore_results, subscriptions) do
    total = length(subscriptions)

    cond do
      map_size(restore_results) == 0 -> "discovered"
      map_size(restore_results) < total -> "partial"
      Enum.all?(restore_results, fn {_, {s, _}} -> s == :ok end) -> "completed"
      true -> "partial"
    end
  end

  defp migration_status_class("discovered"),
    do: "bg-sky-100 dark:bg-sky-900/30 text-sky-700 dark:text-sky-300"

  defp migration_status_class("in_progress"),
    do: "bg-amber-100 dark:bg-amber-900/30 text-amber-700 dark:text-amber-300"

  defp migration_status_class("completed"),
    do: "bg-emerald-100 dark:bg-emerald-900/30 text-emerald-700 dark:text-emerald-300"

  defp migration_status_class("partial"),
    do: "bg-orange-100 dark:bg-orange-900/30 text-orange-700 dark:text-orange-300"

  defp migration_status_class(_),
    do: "bg-gray-100 dark:bg-gray-800 text-gray-600 dark:text-gray-400"

  defp serialize_server_credentials(nil), do: %{}

  defp serialize_server_credentials(credentials) do
    # Convert atom-keyed credential maps to string keys for JSON storage.
    # Tuple keys like {db_name, user_name} in db_passwords are serialized
    # as "db_name:user_name" strings.
    %{
      "db_passwords" =>
        Map.new(credentials.db_passwords, fn
          {{db, user}, pass} -> {"#{db}:#{user}", pass}
          {key, pass} -> {to_string(key), pass}
        end),
      "mail_passwords" => ensure_string_keys(credentials.mail_passwords),
      "sysuser_passwords" => ensure_string_keys(Map.get(credentials, :sysuser_passwords, %{})),
      "client_passwords" => ensure_string_keys(Map.get(credentials, :client_passwords, %{})),
      "ftpuser_passwords" => ensure_string_keys(Map.get(credentials, :ftpuser_passwords, %{}))
    }
  end

  defp deserialize_server_credentials(nil), do: nil
  defp deserialize_server_credentials(creds) when creds == %{}, do: nil

  defp deserialize_server_credentials(creds) do
    # Restore atom-keyed credential maps from JSON string keys.
    # db_passwords keys like "db_name:user_name" are restored to {db, user} tuples.
    db_passwords =
      creds
      |> Map.get("db_passwords", %{})
      |> Map.new(fn {key, pass} ->
        case String.split(key, ":", parts: 2) do
          [db, user] -> {{db, user}, pass}
          _ -> {key, pass}
        end
      end)

    %{
      db_passwords: db_passwords,
      mail_passwords: Map.get(creds, "mail_passwords", %{}),
      sysuser_passwords: Map.get(creds, "sysuser_passwords", %{}),
      client_passwords: Map.get(creds, "client_passwords", %{}),
      ftpuser_passwords: Map.get(creds, "ftpuser_passwords", %{})
    }
  end

  defp ensure_string_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp ensure_string_keys(other), do: other

  defp ensure_atom_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) ->
        {String.to_existing_atom(k), v}

      {k, v} ->
        {k, v}
    end)
  rescue
    # Fall back to string keys if atoms don't exist
    _ -> map
  end

  defp ensure_atom_keys(other), do: other

  defp load_upload_jobs(socket) do
    # Load active upload jobs (pending, running, or recent failures/completions)
    jobs =
      socket.assigns.current_scope.user.id
      |> Hosting.list_upload_jobs_by_user()
      |> Enum.take(20)
      |> Repo.preload(:domain)

    assign(socket, :upload_jobs, jobs)
  end
end
