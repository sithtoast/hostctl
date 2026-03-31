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
    "target_user_email" => "",
    "apply_dns_template" => "false",
    "selected_domains" => [],
    "selected_data_types" => @default_data_types
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Plesk Import")
     |> assign(:active_tab, :panel_plesk_import)
     |> assign(:form_params, @default_params)
     |> assign(:form, to_form(@default_params, as: :import))
     |> assign(:preview, nil)
     |> assign(:ssh_discovery, nil)
     |> assign(:owner_groups, [])
     |> assign(:available_domains, [])
     |> assign(:selected_domains, [])
     |> assign(:data_type_options, @data_type_options)}
  end

  @impl true
  def handle_event("validate", %{"import" => params}, socket) do
    params = normalize_form_params(params)

    {:noreply,
     socket
     |> assign(:form_params, params)
     |> assign(:form, to_form(params, as: :import))}
  end

  @impl true
  def handle_event("submit", %{"import" => params}, socket) do
    params = normalize_form_params(params)
    action = normalize_string(params["submit_action"])

    socket =
      socket
      |> assign(:form_params, params)
      |> assign(:form, to_form(params, as: :import))

    case action do
      "apply" ->
        case apply_import(params) do
          {:ok, result, selected_domains} ->
            summary =
              "Import complete. Created #{result.created_count}, skipped #{result.skipped_existing_count}, failed #{result.failed_count}."

            {:noreply,
             socket
             |> put_flash(:info, summary)
             |> assign(:preview, result)
             |> assign(:owner_groups, [])
             |> assign(:selected_domains, selected_domains)}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, reason)}
        end

      _ ->
        case build_preview(params) do
          {:ok, preview, owner_groups, available_domains, selected_domains, ssh_discovery} ->
            {:noreply,
             socket
             |> assign(:preview, preview)
             |> assign(:ssh_discovery, ssh_discovery)
             |> assign(:owner_groups, owner_groups)
             |> assign(:available_domains, available_domains)
             |> assign(:selected_domains, selected_domains)
             |> assign(:form_params, Map.put(params, "selected_domains", selected_domains))
             |> assign(
               :form,
               to_form(Map.put(params, "selected_domains", selected_domains), as: :import)
             )
             |> put_flash(:info, "Preview updated.")}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:preview, nil)
             |> assign(:ssh_discovery, nil)
             |> assign(:owner_groups, [])
             |> assign(:available_domains, [])
             |> assign(:selected_domains, [])
             |> put_flash(:error, reason)}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_tab={@active_tab}>
      <div class="max-w-6xl mx-auto space-y-6">
        <div>
          <h1 class="text-2xl font-bold text-gray-900 dark:text-white">Plesk Import</h1>
          <p class="mt-1 text-sm text-gray-500 dark:text-gray-400">
            Preview and import domains from an extracted Plesk backup, the Plesk API, or a live Plesk server over SSH.
          </p>
        </div>

        <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800 p-6">
          <.form for={@form} id="plesk-import-form" phx-change="validate" phx-submit="submit">
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

              <.input
                field={@form[:target_user_email]}
                type="email"
                label="Target Hostctl User Email (required for apply)"
                placeholder="owner@example.com"
              />

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
                    SSH discovery preview is enabled for domain inventory using key or password auth. Sudo is assumed.
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

              <input type="hidden" name="import[submit_action]" value="preview" />
            </div>

            <%= if @form[:source].value == "ssh" do %>
              <div class="mt-6 rounded-xl border border-gray-200 dark:border-gray-700 p-4">
                <div>
                  <h2 class="text-sm font-semibold text-gray-900 dark:text-white">Import Scope</h2>
                  <p class="text-xs text-gray-500 dark:text-gray-400">
                    Choose the data categories to discover and offer for import from the Plesk server.
                  </p>
                </div>

                <div class="mt-4 grid grid-cols-1 md:grid-cols-2 gap-3">
                  <label
                    :for={{key, label} <- @data_type_options}
                    class="flex items-start gap-3 rounded-lg border border-gray-100 dark:border-gray-800 px-3 py-3 hover:bg-gray-50 dark:hover:bg-gray-800/50"
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

            <div class="mt-4 flex flex-wrap items-center gap-3">
              <button
                id="plesk-preview-btn"
                type="submit"
                name="import[submit_action]"
                value="preview"
                class="inline-flex items-center gap-2 px-4 py-2 rounded-lg bg-indigo-600 hover:bg-indigo-500 text-white text-sm font-medium transition-colors"
              >
                <.icon name="hero-magnifying-glass" class="w-4 h-4" /> Preview
              </button>

              <button
                id="plesk-apply-btn"
                type="submit"
                name="import[submit_action]"
                value="apply"
                data-confirm="Import now? This will create missing domains for the target user."
                class="inline-flex items-center gap-2 px-4 py-2 rounded-lg bg-emerald-600 hover:bg-emerald-500 text-white text-sm font-medium transition-colors"
              >
                <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> Apply Import
              </button>
            </div>

            <%= if @available_domains != [] do %>
              <div class="mt-6 rounded-xl border border-gray-200 dark:border-gray-700 p-4">
                <div class="flex items-center justify-between gap-3">
                  <div>
                    <h2 class="text-sm font-semibold text-gray-900 dark:text-white">
                      Domain Selection
                    </h2>
                    <p class="text-xs text-gray-500 dark:text-gray-400">
                      Selected {@selected_domains |> length()} of {@available_domains |> length()} discovered domains.
                    </p>
                  </div>
                </div>

                <div class="mt-3 max-h-64 overflow-y-auto rounded-lg border border-gray-100 dark:border-gray-800">
                  <label
                    :for={domain <- @available_domains}
                    class="flex items-center gap-2 px-3 py-2 border-b border-gray-100 dark:border-gray-800 last:border-b-0 hover:bg-gray-50 dark:hover:bg-gray-800/50"
                  >
                    <input
                      type="checkbox"
                      name="import[selected_domains][]"
                      value={domain}
                      checked={domain in @selected_domains}
                      class="checkbox checkbox-sm"
                    />
                    <span class="text-sm text-gray-800 dark:text-gray-200">{domain}</span>
                  </label>
                </div>
              </div>
            <% end %>
          </.form>
        </div>

        <%= if @owner_groups != [] do %>
          <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800 p-6">
            <h2 class="text-base font-semibold text-gray-900 dark:text-white">Ownership Summary</h2>
            <p class="mt-1 text-xs text-gray-500 dark:text-gray-400">
              Parsed from Plesk subscriptions (owner login, owner type, system user).
            </p>

            <div class="mt-4 grid grid-cols-1 md:grid-cols-2 gap-3">
              <div
                :for={group <- Enum.take(@owner_groups, 20)}
                class="rounded-lg border border-gray-200 dark:border-gray-700 px-3 py-2"
              >
                <p class="text-sm text-gray-900 dark:text-gray-100">
                  <span class="font-semibold">Owner:</span> {group.owner_login || "unknown"}
                </p>
                <p class="text-xs text-gray-500 dark:text-gray-400">
                  type={group.owner_type || "unknown"} system_user={group.system_user || "unknown"}
                </p>
                <p class="text-xs font-medium text-indigo-600 dark:text-indigo-400 mt-1">
                  {group.count} domain(s)
                </p>
              </div>
            </div>
          </div>
        <% end %>

        <%= if @ssh_discovery do %>
          <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800 p-6 space-y-4">
            <div>
              <h2 class="text-base font-semibold text-gray-900 dark:text-white">
                SSH Discovery Summary
              </h2>
              <p class="mt-1 text-xs text-gray-500 dark:text-gray-400">
                These categories are preview-only right now. Apply still creates missing Hostctl domains.
              </p>
            </div>

            <%= if @ssh_discovery.warnings != [] do %>
              <div class="rounded-xl border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-900 dark:border-amber-900/40 dark:bg-amber-950/30 dark:text-amber-100">
                <h3 class="font-semibold">Discovery Warnings</h3>
                <ul class="mt-2 space-y-1 text-xs">
                  <li :for={warning <- @ssh_discovery.warnings}>{warning}</li>
                </ul>
              </div>
            <% end %>

            <div class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-3">
              <div
                :for={section <- discovery_sections(@ssh_discovery, @data_type_options)}
                class="rounded-xl border border-gray-200 dark:border-gray-700 p-4"
              >
                <div class="flex items-start justify-between gap-3">
                  <div>
                    <h3 class="text-sm font-semibold text-gray-900 dark:text-white">
                      {section.label}
                    </h3>
                    <p class="text-xs text-gray-500 dark:text-gray-400">{section.key}</p>
                  </div>
                  <span class="inline-flex items-center rounded-full bg-sky-50 px-2 py-1 text-xs font-semibold text-sky-700 dark:bg-sky-900/30 dark:text-sky-300">
                    {section.count}
                  </span>
                </div>

                <div class="mt-3 space-y-1">
                  <p
                    :for={item <- section.samples}
                    class="text-xs text-gray-600 dark:text-gray-300 break-all"
                  >
                    {format_discovery_item(section.key, item)}
                  </p>
                </div>

                <p
                  :if={section.remaining_count > 0}
                  class="mt-3 text-xs font-medium text-indigo-600 dark:text-indigo-400"
                >
                  +{section.remaining_count} more
                </p>
              </div>
            </div>
          </div>
        <% end %>

        <%= if @preview do %>
          <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800 p-6 space-y-3">
            <h2 class="text-base font-semibold text-gray-900 dark:text-white">Preview Result</h2>
            <div class="grid grid-cols-2 md:grid-cols-4 gap-3 text-sm">
              <div class="rounded-lg bg-gray-50 dark:bg-gray-800 px-3 py-2">
                <p class="text-gray-500 dark:text-gray-400">Total input</p>
                <p class="text-lg font-semibold text-gray-900 dark:text-white">
                  {@preview.total_input}
                </p>
              </div>
              <div class="rounded-lg bg-gray-50 dark:bg-gray-800 px-3 py-2">
                <p class="text-gray-500 dark:text-gray-400">Planned</p>
                <p class="text-lg font-semibold text-indigo-600 dark:text-indigo-400">
                  {@preview.planned_count}
                </p>
              </div>
              <div class="rounded-lg bg-gray-50 dark:bg-gray-800 px-3 py-2">
                <p class="text-gray-500 dark:text-gray-400">Skipped existing</p>
                <p class="text-lg font-semibold text-amber-600 dark:text-amber-400">
                  {@preview.skipped_existing_count}
                </p>
              </div>
              <div class="rounded-lg bg-gray-50 dark:bg-gray-800 px-3 py-2">
                <p class="text-gray-500 dark:text-gray-400">Failed</p>
                <p class="text-lg font-semibold text-red-600 dark:text-red-400">
                  {@preview.failed_count}
                </p>
              </div>
            </div>

            <%= if @preview.planned != [] do %>
              <div>
                <h3 class="text-sm font-semibold text-gray-900 dark:text-white">Would be created</h3>
                <div class="mt-2 flex flex-wrap gap-2">
                  <span
                    :for={name <- Enum.take(@preview.planned, 40)}
                    class="inline-flex items-center px-2 py-1 rounded-md bg-indigo-50 dark:bg-indigo-900/30 text-indigo-700 dark:text-indigo-300 text-xs"
                  >
                    {name}
                  </span>
                </div>
              </div>
            <% end %>

            <%= if @preview.created != [] do %>
              <div>
                <h3 class="text-sm font-semibold text-gray-900 dark:text-white">Created</h3>
                <div class="mt-2 flex flex-wrap gap-2">
                  <span
                    :for={name <- Enum.take(@preview.created, 40)}
                    class="inline-flex items-center px-2 py-1 rounded-md bg-emerald-50 dark:bg-emerald-900/30 text-emerald-700 dark:text-emerald-300 text-xs"
                  >
                    {name}
                  </span>
                </div>
              </div>
            <% end %>

            <%= if @preview.failed != [] do %>
              <div>
                <h3 class="text-sm font-semibold text-red-700 dark:text-red-300">Failures</h3>
                <ul class="mt-2 space-y-1 text-xs text-red-600 dark:text-red-300">
                  <li :for={err <- @preview.failed}>{err}</li>
                </ul>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  defp build_preview(params) do
    source = normalize_string(params["source"])

    with {:ok, names, owner_groups, ssh_discovery} <-
           source_domain_names_with_groups(source, params),
         {:ok, target_scope} <- maybe_target_scope(params["target_user_email"]) do
      selected_names = resolve_selected_domains(names, params)
      ssh_discovery = filter_discovery(ssh_discovery, selected_names)

      case target_scope do
        nil ->
          {:ok, dry_preview(selected_names), owner_groups, names, selected_names, ssh_discovery}

        %Scope{} = scope ->
          Importer.import_domains(scope, selected_names, dry_run: true)
          |> case do
            {:ok, preview} -> {:ok, preview, owner_groups, names, selected_names, ssh_discovery}
          end
      end
    end
  end

  defp apply_import(params) do
    source = normalize_string(params["source"])

    with {:ok, names, _owner_groups} <- source_domain_names_with_groups(source, params),
         selected_names <- resolve_selected_domains(names, params),
         :ok <- validate_selected_domains(selected_names),
         {:ok, %Scope{} = target_scope} <- required_target_scope(params["target_user_email"]) do
      case Importer.import_domains(target_scope, selected_names,
             dry_run: false,
             apply_dns_template: normalize_boolean(params["apply_dns_template"])
           ) do
        {:ok, result} -> {:ok, result, selected_names}
      end
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

        {:ok, names, owner_groups, nil}
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
        {:ok, names} -> {:ok, names, [], nil}
        {:error, reason} -> {:error, reason}
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

          {:ok, names, owner_groups, ssh_discovery}
        end
    end
  end

  defp source_domain_names_with_groups(_other, _params),
    do: {:error, "Unsupported source. Choose backup, api, or ssh."}

  defp maybe_target_scope(nil), do: {:ok, nil}

  defp maybe_target_scope(email) when is_binary(email) do
    case normalize_string(email) do
      "" ->
        {:ok, nil}

      normalized_email ->
        case Accounts.get_user_by_email(normalized_email) do
          nil -> {:error, "Target Hostctl user not found: #{normalized_email}"}
          user -> {:ok, Scope.for_user(user)}
        end
    end
  end

  defp required_target_scope(email) do
    case maybe_target_scope(email) do
      {:ok, nil} -> {:error, "Target Hostctl user email is required for apply."}
      {:ok, scope} -> {:ok, scope}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dry_preview(names) do
    %{
      dry_run: true,
      total_input: length(names),
      planned_count: length(names),
      created_count: 0,
      skipped_existing_count: 0,
      failed_count: 0,
      planned: names,
      created: [],
      skipped_existing: [],
      failed: []
    }
  end

  defp normalize_string(value) when is_binary(value), do: String.trim(value)
  defp normalize_string(_), do: ""

  defp normalize_form_params(params) when is_map(params) do
    @default_params
    |> Map.merge(params)
    |> Map.put("selected_domains", selected_domains_from_params(params))
    |> Map.put("selected_data_types", selected_data_types_from_params(params))
  end

  defp selected_domains_from_params(params) do
    case Map.get(params, "selected_domains") do
      list when is_list(list) ->
        list
        |> Enum.map(&normalize_string/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()

      value when is_binary(value) ->
        value
        |> normalize_string()
        |> case do
          "" -> []
          domain -> [domain]
        end

      _ ->
        []
    end
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

  defp resolve_selected_domains(available_domains, params) do
    selected = selected_domains_from_params(params)

    if selected == [] do
      available_domains
    else
      available_set = MapSet.new(available_domains)
      Enum.filter(selected, &MapSet.member?(available_set, &1))
    end
  end

  defp validate_selected_domains([]), do: {:error, "Select at least one domain to import."}
  defp validate_selected_domains(_), do: :ok

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

  defp filter_discovery(nil, _selected_domains), do: nil

  defp filter_discovery(discovery, []) do
    %{
      discovery
      | inventory:
          Map.new(discovery.inventory, fn {key, items} ->
            {key, filter_discovery_items(items, nil)}
          end)
    }
  end

  defp filter_discovery(discovery, selected_domains) do
    selected_domains = MapSet.new(selected_domains)

    %{
      discovery
      | inventory:
          Map.new(discovery.inventory, fn {key, items} ->
            {key, filter_discovery_items(items, selected_domains)}
          end)
    }
  end

  defp filter_discovery_items(items, nil), do: items

  defp filter_discovery_items(items, selected_domains) do
    Enum.filter(items, fn item ->
      case Map.get(item, :domain) do
        nil -> true
        domain -> MapSet.member?(selected_domains, domain)
      end
    end)
  end

  defp discovery_sections(nil, _options), do: []

  defp discovery_sections(discovery, options) do
    options
    |> Enum.map(fn {key, label} ->
      items = Map.get(discovery.inventory, key, [])

      if items == [] do
        nil
      else
        %{
          key: key,
          label: label,
          count: length(items),
          samples: Enum.take(items, 5),
          remaining_count: max(length(items) - 5, 0)
        }
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp format_discovery_item("dns", item) do
    if Map.get(item, :enabled, true) do
      "#{item.domain} (#{item.record_count} records)"
    else
      "#{item.domain} (DNS disabled in Plesk / external DNS)"
    end
  end

  defp format_discovery_item("web_files", item) do
    suffix =
      case item.system_user do
        nil -> ""
        login -> " [#{login}]"
      end

    "#{item.domain} -> #{item.document_root || "unknown"}#{suffix}"
  end

  defp format_discovery_item("mail_accounts", item), do: item.address

  defp format_discovery_item("mail_content", item), do: "#{item.address} -> #{item.path}"

  defp format_discovery_item("databases", item), do: "#{item.name} (#{item.domain})"

  defp format_discovery_item("db_users", item),
    do: "#{item.login} on #{item.database} (#{item.domain})"

  defp format_discovery_item("cron_jobs", item),
    do: "#{item.domain} / #{item.system_user || "unknown"}: #{item.count} jobs"

  defp format_discovery_item("ftp_accounts", item) do
    case item.domain do
      nil -> item.login
      domain -> "#{item.login} (#{domain})"
    end
  end

  defp format_discovery_item("ssl_certificates", item), do: "#{item.domain}: #{item.name}"

  defp format_discovery_item("system_users", item) do
    case item.domain do
      nil -> item.login
      domain -> "#{item.login} (#{domain})"
    end
  end

  defp format_discovery_item(_key, item), do: inspect(item)
end
