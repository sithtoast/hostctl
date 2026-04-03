defmodule HostctlWeb.PanelLive.PleskImport do
  use HostctlWeb, :live_view

  alias Hostctl.Accounts
  alias Hostctl.Accounts.Scope
  alias Hostctl.Plesk
  alias Hostctl.Plesk.Importer
  alias Hostctl.Plesk.SSHProbe

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
    {"subdomains", "Subdomains", "hero-rectangle-group"},
    {"dns", "DNS Records", "hero-globe-alt"},
    {"web_files", "Web Files", "hero-document-duplicate"},
    {"mail_accounts", "Mail Accounts", "hero-envelope"},
    {"mail_content", "Mail Content", "hero-inbox-stack"},
    {"databases", "Databases", "hero-circle-stack"},
    {"db_users", "Database Users", "hero-user-circle"},
    {"cron_jobs", "Cron Jobs", "hero-clock"},
    {"ftp_accounts", "FTP Accounts", "hero-arrow-up-tray"},
    {"ssl_certificates", "SSL Certificates", "hero-lock-closed"}
  ]

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
    {:ok,
     socket
     |> assign(:page_title, "Plesk Import")
     |> assign(:active_tab, :panel_plesk_import)
     |> assign(:form_params, @default_params)
     |> assign(:form, to_form(@default_params, as: :import))
     |> assign(:phase, :discovery)
     |> assign(:discovering, false)
     |> assign(:discover_task_ref, nil)
     |> assign(:ssh_discovery, nil)
     |> assign(:subscriptions, [])
     |> assign(:domain_configs, %{})
     |> assign(:restore_results, %{})
     |> assign(:restore_progress, %{})
     |> assign(:restore_task_refs, %{})
     |> assign(:accounts, load_accounts())
     |> assign(:creating_account, false)
     |> assign(:new_account_form, to_form(%{"name" => "", "email" => ""}, as: :account))
     |> assign(:data_type_options, @data_type_options)
     |> assign(:restore_categories, @restore_categories)
     |> assign(:saved_migrations, [])
     |> assign(:show_saved, false)
     |> load_saved_migrations()}
  end

  # ── Events ─────────────────────────────────────────────────────────────

  @impl true
  def handle_event("validate", %{"import" => params}, socket) do
    params = normalize_form_params(params)

    {:noreply,
     socket
     |> assign(:form_params, params)
     |> assign(:form, to_form(params, as: :import))}
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
     |> assign(:discovering, false)
     |> assign(:discover_task_ref, nil)
     |> assign(:ssh_discovery, nil)
     |> assign(:subscriptions, [])
     |> assign(:domain_configs, %{})
     |> assign(:restore_results, %{})
     |> assign(:restore_progress, %{})
     |> assign(:restore_task_refs, %{})}
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
        case Accounts.create_panel_user(%{name: name, email: email}) do
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
    existing_emails = MapSet.new(socket.assigns.accounts, & &1.email)

    # Group domains by owner identity (prefer owner_email, fall back to owner_login)
    owner_groups =
      subscriptions
      |> Enum.group_by(fn sub ->
        Map.get(sub, :owner_email) || Map.get(sub, :owner_login)
      end)
      |> Map.delete(nil)

    {created, skipped, configs} =
      Enum.reduce(owner_groups, {0, 0, socket.assigns.domain_configs}, fn
        {_key, subs}, {created, skipped, configs} ->
          sample = hd(subs)
          email = Map.get(sample, :owner_email)
          name = Map.get(sample, :owner_name) || Map.get(sample, :owner_login) || "User"

          # Synthesize email from owner_login@first_domain if no email from Plesk
          email =
            if is_nil(email) or email == "" do
              login = Map.get(sample, :owner_login, "user")
              "#{login}@#{sample.domain}"
            else
              email
            end

          if MapSet.member?(existing_emails, email) do
            # Account exists — just assign domains
            configs =
              Enum.reduce(subs, configs, fn sub, acc ->
                config = Map.get(acc, sub.domain, %{})
                Map.put(acc, sub.domain, Map.put(config, :account_email, email))
              end)

            {created, skipped + 1, configs}
          else
            case Accounts.create_panel_user(%{name: name, email: email}) do
              {:ok, _user} ->
                configs =
                  Enum.reduce(subs, configs, fn sub, acc ->
                    config = Map.get(acc, sub.domain, %{})
                    Map.put(acc, sub.domain, Map.put(config, :account_email, email))
                  end)

                {created + 1, skipped, configs}

              {:error, _changeset} ->
                {created, skipped, configs}
            end
          end
      end)

    flash =
      cond do
        created > 0 and skipped > 0 ->
          "Created #{created} account(s), #{skipped} already existed. Domains assigned."

        created > 0 ->
          "Created #{created} account(s) and assigned domains."

        skipped > 0 ->
          "All #{skipped} account(s) already exist. Domains assigned."

        true ->
          "No Plesk owner information available to create accounts."
      end

    {:noreply,
     socket
     |> assign(:accounts, load_accounts())
     |> assign(:domain_configs, configs)
     |> put_flash(:info, flash)}
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
        restore_results: serialize_restore_results(socket.assigns.restore_results)
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

    {:noreply,
     socket
     |> assign(:phase, :restore)
     |> assign(:form_params, form_params)
     |> assign(:form, to_form(form_params, as: :import))
     |> assign(:ssh_discovery, ssh_discovery)
     |> assign(:subscriptions, subscriptions)
     |> assign(:domain_configs, domain_configs)
     |> assign(:restore_results, restore_results)
     |> put_flash(:info, "Loaded migration \"#{migration.name}\".")}
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
      restore_results: serialize_restore_results(socket.assigns.restore_results)
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
         |> assign(:ssh_discovery, ssh_discovery)
         |> assign(:subscriptions, subscriptions)
         |> assign(:domain_configs, domain_configs)
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

  # Restore task completed
  @impl true
  def handle_info({ref, {:restore_result, domain, result}}, socket) do
    Process.demonitor(ref, [:flush])

    task_refs = Map.delete(socket.assigns.restore_task_refs, domain)
    progress = Map.delete(socket.assigns.restore_progress, domain)

    {status, flash_type, flash_msg} =
      case result do
        {:ok, r} -> {{:ok, r}, :info, "Restored #{domain} successfully."}
        {:error, r} -> {{:error, r}, :error, "Failed to restore #{domain}."}
      end

    results = Map.put(socket.assigns.restore_results, domain, status)

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
    progress =
      Map.put(socket.assigns.restore_progress, domain, %{
        category: category,
        index: index,
        total: total,
        status: status
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
    inventory = filter_inventory_for_domain(socket.assigns.ssh_discovery, domain)
    apply_dns = normalize_boolean(socket.assigns.form_params["apply_dns_template"])
    ssh_opts = build_ssh_opts(socket.assigns.form_params)
    web_files_path = Map.get(config, :web_files_path, "/var/www/#{domain}")
    lv_pid = self()

    task =
      Task.async(fn ->
        result =
          Importer.restore_domain(scope, subscription, inventory,
            categories: categories,
            apply_dns_template: apply_dns,
            ssh_opts: ssh_opts,
            web_files_path: web_files_path,
            progress_pid: lv_pid
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

  # ── Render ─────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_tab={@active_tab}>
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

        <%= if @discovering do %>
          {render_discovering(assigns)}
        <% else %>
          <%= if @phase == :discovery do %>
            {render_discovery_phase(assigns)}
          <% else %>
            {render_restore_phase(assigns)}
          <% end %>
        <% end %>
      </div>
    </Layouts.app>
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
                {m.status}
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
            id="plesk-restore-all-btn"
            phx-click="restore_all"
            data-confirm="Restore all domains with their selected categories?"
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
              <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> Restore All
            <% end %>
          </button>
        </div>
      </div>
    </div>

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

    <%!-- Domain restore cards --%>
    <div class="space-y-4">
      <%= for sub <- @subscriptions do %>
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
            if(has_result and result_ok, do: "border-emerald-300 dark:border-emerald-700", else: ""),
            if(has_result and not result_ok, do: "border-red-300 dark:border-red-700", else: ""),
            if(restoring, do: "border-indigo-300 dark:border-indigo-700", else: ""),
            if(not has_result and not restoring, do: "border-gray-200 dark:border-gray-800", else: "")
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
                if(not has_result and not restoring, do: "bg-gray-300 dark:bg-gray-600", else: "")
              ]}>
              </div>
              <div>
                <h3 class="text-sm font-semibold text-gray-900 dark:text-white">{sub.domain}</h3>
                <%= if Map.get(sub, :owner_login) || Map.get(sub, :owner_email) do %>
                  <p class="text-xs text-gray-400 dark:text-gray-500 mt-0.5">
                    <.icon name="hero-user" class="w-3 h-3 inline" />
                    <span :if={Map.get(sub, :owner_name)}>{sub.owner_name}</span>
                    <span :if={Map.get(sub, :owner_email)} class="text-gray-400">
                      {sub.owner_email}
                    </span>
                    <span
                      :if={Map.get(sub, :owner_login) && !Map.get(sub, :owner_email)}
                      class="text-gray-400"
                    >
                      {sub.owner_login}
                    </span>
                  </p>
                <% end %>
                <%= if Map.get(sub, :subdomains, []) != [] do %>
                  <p class="text-xs text-gray-400 dark:text-gray-500 mt-0.5">
                    <.icon name="hero-arrow-turn-down-right" class="w-3 h-3 inline" />
                    {sub.subdomains |> Enum.map(& &1.name) |> Enum.join(", ")}
                  </p>
                <% end %>
              </div>
            </div>

            <div class="flex items-center gap-2 w-full sm:w-auto">
              <form id={"account-form-#{sub.domain}"} phx-change="set_account">
                <input type="hidden" name="domain" value={sub.domain} />
                <select
                  id={"account-select-#{sub.domain}"}
                  name="email"
                  class="block w-full sm:w-56 rounded-lg border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-800 px-2.5 py-1.5 text-xs text-gray-900 dark:text-gray-100 focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500"
                >
                  <option value="">— Account —</option>
                  <option
                    :for={account <- @accounts}
                    value={account.email}
                    selected={Map.get(config, :account_email) == account.email}
                  >
                    {account.name} ({account.email}) [{account.role}]
                  </option>
                </select>
              </form>
            </div>
          </div>

          <%!-- Categories --%>
          <div class="mt-3 grid grid-cols-2 md:grid-cols-4 gap-2">
            <%= for {key, label, icon} <- @restore_categories do %>
              <% count = Map.get(counts, key, 0) %>
              <% selected = MapSet.member?(categories, key) %>
              <button
                type="button"
                phx-click="toggle_category"
                phx-value-domain={sub.domain}
                phx-value-category={key}
                disabled={count == 0}
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

          <%!-- Web files destination path --%>
          <%= if MapSet.member?(categories, "web_files") do %>
            <div class="mt-3 flex items-center gap-2">
              <label
                for={"web-path-#{sub.domain}"}
                class="text-xs text-gray-500 dark:text-gray-400 whitespace-nowrap"
              >
                <.icon name="hero-folder" class="w-3.5 h-3.5 inline" /> Destination:
              </label>
              <form id={"web-path-form-#{sub.domain}"} phx-change="set_web_path" class="flex-1">
                <input type="hidden" name="domain" value={sub.domain} />
                <input
                  type="text"
                  id={"web-path-#{sub.domain}"}
                  name="path"
                  value={Map.get(config, :web_files_path, "/var/www/#{sub.domain}")}
                  class="block w-full rounded-lg border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-800 px-2.5 py-1.5 text-xs text-gray-900 dark:text-gray-100 font-mono focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500"
                  placeholder="/var/www/{sub.domain}"
                />
              </form>
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
              phx-click="restore_domain"
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
                  <.icon name="hero-check" class="w-3.5 h-3.5" /> Restored
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
                  <.icon name="hero-arrow-down-tray" class="w-3.5 h-3.5" /> Restore
              <% end %>
            </button>
          </div>

          <%!-- Restore progress --%>
          <%= if restoring do %>
            <div class="mt-3 rounded-lg px-4 py-3 bg-indigo-50 dark:bg-indigo-950/20 border border-indigo-100 dark:border-indigo-900/40">
              <div class="flex items-center justify-between mb-2">
                <p class="text-xs font-medium text-indigo-800 dark:text-indigo-200">
                  <%= if progress.category do %>
                    Restoring {category_display_name(progress.category)}...
                  <% else %>
                    Starting restore...
                  <% end %>
                </p>
                <span class="text-[10px] text-indigo-500 dark:text-indigo-400">
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
                else: "bg-red-50 dark:bg-red-950/20 border border-red-100 dark:border-red-900/40"
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
    inv = discovery.inventory

    %{
      "subdomains" => subscription |> Map.get(:subdomains, []) |> length(),
      "dns" => inv |> Map.get("dns", []) |> Enum.count(&(&1.domain == domain)),
      "mail_accounts" =>
        inv |> Map.get("mail_accounts", []) |> Enum.count(&(&1.domain == domain)),
      "mail_content" => inv |> Map.get("mail_content", []) |> Enum.count(&(&1.domain == domain)),
      "databases" => inv |> Map.get("databases", []) |> Enum.count(&(&1.domain == domain)),
      "db_users" => inv |> Map.get("db_users", []) |> Enum.count(&(&1.domain == domain)),
      "cron_jobs" => inv |> Map.get("cron_jobs", []) |> Enum.count(&(&1.domain == domain)),
      "ftp_accounts" =>
        inv |> Map.get("ftp_accounts", []) |> Enum.count(&(Map.get(&1, :domain) == domain)),
      "ssl_certificates" =>
        inv |> Map.get("ssl_certificates", []) |> Enum.count(&(&1.domain == domain))
    }
  end

  defp filter_inventory_for_domain(nil, _domain), do: %{}

  defp filter_inventory_for_domain(discovery, domain) do
    Map.new(discovery.inventory, fn {key, items} ->
      filtered = Enum.filter(items, fn item -> Map.get(item, :domain) == domain end)
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

  defp resolve_scope(""), do: {:error, "No account selected. Assign an account to this domain."}

  defp resolve_scope(email) when is_binary(email) do
    case Accounts.get_user_by_email(email) do
      nil -> {:error, "User not found: #{email}"}
      user -> {:ok, Scope.for_user(user)}
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
end
