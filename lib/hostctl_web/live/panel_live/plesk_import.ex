defmodule HostctlWeb.PanelLive.PleskImport do
  use HostctlWeb, :live_view

  alias Hostctl.Accounts
  alias Hostctl.Accounts.Scope
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
    {"mail_accounts", "Mail Accounts", "hero-envelope"},
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
     |> assign(:ssh_discovery, nil)
     |> assign(:subscriptions, [])
     |> assign(:domain_configs, %{})
     |> assign(:restore_results, %{})
     |> assign(:accounts, load_accounts())
     |> assign(:creating_account, false)
     |> assign(:new_account_form, to_form(%{"name" => "", "email" => ""}, as: :account))
     |> assign(:data_type_options, @data_type_options)
     |> assign(:restore_categories, @restore_categories)}
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

    case run_discovery(params) do
      {:ok, ssh_discovery, subscriptions} ->
        domain_configs = build_domain_configs(subscriptions, ssh_discovery)

        {:noreply,
         socket
         |> assign(:phase, :restore)
         |> assign(:ssh_discovery, ssh_discovery)
         |> assign(:subscriptions, subscriptions)
         |> assign(:domain_configs, domain_configs)
         |> assign(:restore_results, %{})
         |> put_flash(:info, "Discovered #{length(subscriptions)} domain(s).")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  @impl true
  def handle_event("reset", _params, socket) do
    {:noreply,
     socket
     |> assign(:phase, :discovery)
     |> assign(:ssh_discovery, nil)
     |> assign(:subscriptions, [])
     |> assign(:domain_configs, %{})
     |> assign(:restore_results, %{})}
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
  def handle_event("restore_domain", %{"domain" => domain}, socket) do
    configs = socket.assigns.domain_configs
    config = Map.get(configs, domain, %{})
    account_email = Map.get(config, :account_email, "")
    categories = config |> Map.get(:categories, MapSet.new()) |> MapSet.to_list()

    case resolve_scope(account_email) do
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "#{domain}: #{reason}")}

      {:ok, scope} ->
        subscription = Enum.find(socket.assigns.subscriptions, &(&1.domain == domain))
        inventory = filter_inventory_for_domain(socket.assigns.ssh_discovery, domain)
        apply_dns = normalize_boolean(socket.assigns.form_params["apply_dns_template"])

        case Importer.restore_domain(scope, subscription, inventory,
               categories: categories,
               apply_dns_template: apply_dns
             ) do
          {:ok, result} ->
            results = Map.put(socket.assigns.restore_results, domain, {:ok, result})

            {:noreply,
             socket
             |> assign(:restore_results, results)
             |> put_flash(:info, "Restored #{domain} successfully.")}

          {:error, result} ->
            results = Map.put(socket.assigns.restore_results, domain, {:error, result})

            {:noreply,
             socket
             |> assign(:restore_results, results)
             |> put_flash(:error, "Failed to restore #{domain}.")}
        end
    end
  end

  @impl true
  def handle_event("restore_all", _params, socket) do
    results =
      Enum.reduce(socket.assigns.subscriptions, socket.assigns.restore_results, fn sub, acc ->
        # Skip already-restored domains
        if Map.has_key?(acc, sub.domain) do
          acc
        else
          config = Map.get(socket.assigns.domain_configs, sub.domain, %{})
          account_email = Map.get(config, :account_email, "")
          categories = config |> Map.get(:categories, MapSet.new()) |> MapSet.to_list()

          case resolve_scope(account_email) do
            {:error, _reason} ->
              Map.put(
                acc,
                sub.domain,
                {:error,
                 %{
                   domain: sub.domain,
                   domain_status: {:failed, "No account selected"},
                   categories: %{}
                 }}
              )

            {:ok, scope} ->
              inventory = filter_inventory_for_domain(socket.assigns.ssh_discovery, sub.domain)
              apply_dns = normalize_boolean(socket.assigns.form_params["apply_dns_template"])

              case Importer.restore_domain(scope, sub, inventory,
                     categories: categories,
                     apply_dns_template: apply_dns
                   ) do
                {:ok, result} -> Map.put(acc, sub.domain, {:ok, result})
                {:error, result} -> Map.put(acc, sub.domain, {:error, result})
              end
          end
        end
      end)

    ok_count = Enum.count(results, fn {_, {status, _}} -> status == :ok end)
    err_count = Enum.count(results, fn {_, {status, _}} -> status == :error end)

    flash =
      cond do
        err_count == 0 -> {:info, "All #{ok_count} domain(s) restored successfully."}
        ok_count == 0 -> {:error, "All #{err_count} domain(s) failed to restore."}
        true -> {:info, "Restored #{ok_count} domain(s), #{err_count} failed."}
      end

    {:noreply,
     socket
     |> assign(:restore_results, results)
     |> put_flash(elem(flash, 0), elem(flash, 1))}
  end

  # ── Render ─────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_tab={@active_tab}>
      <div class="max-w-6xl mx-auto space-y-6">
        <div>
          <h1 class="text-2xl font-bold text-gray-900 dark:text-white">Plesk Import</h1>
          <p class="mt-1 text-sm text-gray-500 dark:text-gray-400">
            Discover and selectively restore domains from an extracted Plesk backup, the Plesk API, or a live Plesk server over SSH.
          </p>
        </div>

        <%= if @phase == :discovery do %>
          {render_discovery_phase(assigns)}
        <% else %>
          {render_restore_phase(assigns)}
        <% end %>
      </div>
    </Layouts.app>
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
            class="inline-flex items-center gap-2 px-5 py-2.5 rounded-lg bg-indigo-600 hover:bg-indigo-500 text-white text-sm font-medium transition-colors shadow-sm"
          >
            <.icon name="hero-magnifying-glass" class="w-4 h-4" /> Discover
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

    assigns =
      assigns
      |> Map.put(:total_domains, total)
      |> Map.put(:restored_count, restored)
      |> Map.put(:failed_count, failed)

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
            <%= if @restored_count > 0 or @failed_count > 0 do %>
              <span class="ml-1 font-medium">
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
            class="inline-flex items-center gap-1.5 px-4 py-2 rounded-lg bg-emerald-600 hover:bg-emerald-500 text-white text-sm font-medium transition-colors shadow-sm"
          >
            <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> Restore All
          </button>
        </div>
      </div>
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
        <% has_result = result != nil %>
        <% result_ok = match?({:ok, _}, result) %>
        <div
          id={"domain-card-#{sub.domain}"}
          class={[
            "bg-white dark:bg-gray-900 rounded-xl border p-5 transition-all",
            if(has_result and result_ok, do: "border-emerald-300 dark:border-emerald-700", else: ""),
            if(has_result and not result_ok, do: "border-red-300 dark:border-red-700", else: ""),
            if(not has_result, do: "border-gray-200 dark:border-gray-800", else: "")
          ]}
        >
          <%!-- Header --%>
          <div class="flex flex-col sm:flex-row items-start sm:items-center justify-between gap-3">
            <div class="flex items-center gap-3">
              <div class={[
                "w-2 h-2 rounded-full shrink-0",
                if(has_result and result_ok, do: "bg-emerald-500", else: ""),
                if(has_result and not result_ok, do: "bg-red-500", else: ""),
                if(not has_result, do: "bg-gray-300 dark:bg-gray-600", else: "")
              ]}>
              </div>
              <div>
                <h3 class="text-sm font-semibold text-gray-900 dark:text-white">{sub.domain}</h3>
                <%= if Map.get(sub, :subdomains, []) != [] do %>
                  <p class="text-xs text-gray-400 dark:text-gray-500 mt-0.5">
                    <.icon name="hero-arrow-turn-down-right" class="w-3 h-3 inline" />
                    {sub.subdomains |> Enum.map(& &1.name) |> Enum.join(", ")}
                  </p>
                <% end %>
              </div>
            </div>

            <div class="flex items-center gap-2 w-full sm:w-auto">
              <select
                id={"account-select-#{sub.domain}"}
                phx-change="set_account"
                phx-value-domain={sub.domain}
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
              disabled={has_result and result_ok}
              class={[
                "inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-medium transition-colors",
                if(has_result and result_ok,
                  do:
                    "bg-emerald-100 dark:bg-emerald-900/30 text-emerald-700 dark:text-emerald-300 cursor-default",
                  else: "bg-emerald-600 hover:bg-emerald-500 text-white shadow-sm"
                )
              ]}
            >
              <%= if has_result and result_ok do %>
                <.icon name="hero-check" class="w-3.5 h-3.5" /> Restored
              <% else %>
                <.icon name="hero-arrow-down-tray" class="w-3.5 h-3.5" /> Restore
              <% end %>
            </button>
          </div>

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
end
