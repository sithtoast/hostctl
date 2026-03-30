defmodule HostctlWeb.PanelLive.Backup do
  use HostctlWeb, :live_view

  alias Hostctl.Backup
  alias Hostctl.Backup.Runner

  @pubsub_topic "backup:events"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Hostctl.PubSub, @pubsub_topic)
    end

    setting = Backup.get_or_create_settings()
    form = to_form(Backup.change_settings(setting), as: :backup_setting)
    logs = Backup.list_logs()
    running = Backup.backup_running?()
    domain_groups = Backup.list_domain_groups()

    {:ok,
     socket
     |> assign(:page_title, "Backup")
     |> assign(:active_tab, :panel_backup)
     |> assign(:setting, setting)
     |> assign(:form, form)
     |> assign(:settings_tab, :local)
     |> assign(:running, running)
     |> assign(:progress_messages, [])
     |> assign(:exclude_picker, nil)
     |> assign(:domain_groups, domain_groups)
     |> stream(:logs, logs)}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => "domains"}, socket) do
    {:noreply,
     socket
     |> assign(:settings_tab, :domains)
     |> assign(:domain_groups, Backup.list_domain_groups())}
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :settings_tab, String.to_existing_atom(tab))}
  end

  @impl true
  def handle_event("validate", %{"backup_setting" => params}, socket) do
    form =
      socket.assigns.setting
      |> Backup.change_settings(params)
      |> to_form(action: :validate, as: :backup_setting)

    {:noreply, assign(socket, :form, form)}
  end

  @impl true
  def handle_event("save", %{"backup_setting" => params}, socket) do
    case Backup.update_settings(socket.assigns.setting, params) do
      {:ok, updated} ->
        form = to_form(Backup.change_settings(updated), as: :backup_setting)

        socket =
          socket
          |> assign(:setting, updated)
          |> assign(:form, form)
          |> put_flash(:info, "Backup settings saved.")

        socket =
          if updated.local_enabled do
            local_path = updated.local_path || "/var/backups/hostctl"

            case File.mkdir_p(local_path) do
              :ok ->
                put_flash(socket, :info, "Backup settings saved. Local directory #{local_path} is ready.")

              {:error, reason} ->
                put_flash(
                  socket,
                  :warning,
                  "Settings saved, but could not create local backup directory #{local_path}: #{:file.format_error(reason)}. " <>
                    "Fix by running: sudo /opt/hostctl/bin/repair"
                )
            end
          else
            socket
          end

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :backup_setting))}
    end
  end

  @impl true
  def handle_event(
        "toggle_domain_files",
        %{"domain-id" => id_str, "current" => current_str},
        socket
      ) do
    domain_id = String.to_integer(id_str)

    case Backup.set_domain_include_files(domain_id, current_str != "true") do
      {:ok, _} ->
        {:noreply, assign(socket, :domain_groups, Backup.list_domain_groups())}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update domain backup setting.")}
    end
  end

  @impl true
  def handle_event(
        "toggle_subdomain_files",
        %{"subdomain-id" => id_str, "current" => current_str},
        socket
      ) do
    subdomain_id = String.to_integer(id_str)

    case Backup.set_subdomain_include_files(subdomain_id, current_str != "true") do
      {:ok, _} ->
        {:noreply, assign(socket, :domain_groups, Backup.list_domain_groups())}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update subdomain backup setting.")}
    end
  end

  @impl true
  def handle_event(
        "toggle_domain_mail",
        %{"domain-id" => id_str, "current" => current_str},
        socket
      ) do
    domain_id = String.to_integer(id_str)

    case Backup.set_domain_include_mail(domain_id, current_str != "true") do
      {:ok, _} ->
        {:noreply, assign(socket, :domain_groups, Backup.list_domain_groups())}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update domain mail setting.")}
    end
  end

  @impl true
  def handle_event(
        "set_domain_s3_mode",
        %{"domain-id" => id_str, "mode" => mode},
        socket
      ) do
    domain_id = String.to_integer(id_str)
    effective_mode = if mode == "global", do: nil, else: mode

    case Backup.set_domain_s3_mode(domain_id, effective_mode) do
      {:ok, _} ->
        {:noreply, assign(socket, :domain_groups, Backup.list_domain_groups())}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update domain S3 mode.")}
    end
  end

  @impl true
  def handle_event(
        "set_subdomain_s3_mode",
        %{"subdomain-id" => id_str, "mode" => mode},
        socket
      ) do
    subdomain_id = String.to_integer(id_str)
    effective_mode = if mode == "global", do: nil, else: mode

    case Backup.set_subdomain_s3_mode(subdomain_id, effective_mode) do
      {:ok, _} ->
        {:noreply, assign(socket, :domain_groups, Backup.list_domain_groups())}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update subdomain S3 mode.")}
    end
  end

  @impl true
  def handle_event("run_domain_now", _, %{assigns: %{running: true}} = socket) do
    {:noreply, put_flash(socket, :error, "A backup is already running.")}
  end

  @impl true
  def handle_event("open_domain_excludes", %{"domain-id" => id_str}, socket) do
    domain_id = String.to_integer(id_str)

    case Enum.find(socket.assigns.domain_groups, &(&1.id == domain_id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Domain not found.")}

      group ->
        case build_exclude_picker(
               :domain,
               group.id,
               group.name,
               group.document_root,
               group.excluded_dirs || []
             ) do
          {:ok, picker} ->
            {:noreply, assign(socket, :exclude_picker, picker)}

          {:error, :not_dir} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Cannot browse excludes: document root is missing or not a directory."
             )}
        end
    end
  end

  @impl true
  def handle_event("open_subdomain_excludes", %{"subdomain-id" => id_str}, socket) do
    subdomain_id = String.to_integer(id_str)

    subdomain =
      socket.assigns.domain_groups
      |> Enum.flat_map(& &1.subdomains)
      |> Enum.find(&(&1.id == subdomain_id))

    case subdomain do
      nil ->
        {:noreply, put_flash(socket, :error, "Subdomain not found.")}

      sub ->
        case build_exclude_picker(
               :subdomain,
               sub.id,
               sub.full_name,
               sub.document_root,
               sub.excluded_dirs || []
             ) do
          {:ok, picker} ->
            {:noreply, assign(socket, :exclude_picker, picker)}

          {:error, :not_dir} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Cannot browse excludes: document root is missing or not a directory."
             )}
        end
    end
  end

  @impl true
  def handle_event("close_excludes", _, socket) do
    {:noreply, assign(socket, :exclude_picker, nil)}
  end

  @impl true
  def handle_event("exclude_open_path", %{"path" => rel_path}, socket) do
    picker = socket.assigns.exclude_picker

    if is_nil(picker) do
      {:noreply, socket}
    else
      rel_path = normalize_rel_path(rel_path)

      case list_directories(picker.root, rel_path) do
        {:ok, entries} ->
          {:noreply,
           assign(socket, :exclude_picker, %{picker | current_path: rel_path, entries: entries})}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Unable to read directory.")}
      end
    end
  end

  @impl true
  def handle_event("exclude_up", _, socket) do
    picker = socket.assigns.exclude_picker

    if is_nil(picker) do
      {:noreply, socket}
    else
      next_path =
        case picker.current_path do
          "" -> ""
          path -> path |> String.split("/", trim: true) |> Enum.drop(-1) |> Enum.join("/")
        end

      case list_directories(picker.root, next_path) do
        {:ok, entries} ->
          {:noreply,
           assign(socket, :exclude_picker, %{picker | current_path: next_path, entries: entries})}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Unable to read directory.")}
      end
    end
  end

  @impl true
  def handle_event("toggle_excluded_dir", %{"path" => rel_path, "current" => current_str}, socket) do
    picker = socket.assigns.exclude_picker
    rel_path = normalize_rel_path(rel_path)

    selected =
      if current_str == "true" do
        MapSet.delete(picker.selected, rel_path)
      else
        MapSet.put(picker.selected, rel_path)
      end

    {:noreply, assign(socket, :exclude_picker, %{picker | selected: selected})}
  end

  @impl true
  def handle_event("save_excludes", _, socket) do
    picker = socket.assigns.exclude_picker
    excluded_dirs = picker.selected |> MapSet.to_list() |> Enum.sort()

    result =
      case picker.scope do
        :domain -> Backup.set_domain_excluded_dirs(picker.id, excluded_dirs)
        :subdomain -> Backup.set_subdomain_excluded_dirs(picker.id, excluded_dirs)
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:exclude_picker, nil)
         |> assign(:domain_groups, Backup.list_domain_groups())
         |> put_flash(:info, "Excluded directories updated.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update excluded directories.")}
    end
  end

  def handle_event("run_domain_now", %{"domain-id" => id_str}, socket) do
    domain_id = String.to_integer(id_str)

    case Runner.run_domain_now(domain_id) do
      :ok ->
        {:noreply,
         socket
         |> assign(:running, true)
         |> assign(:progress_messages, [])
         |> put_flash(:info, "Domain backup started.")}

      {:error, :already_running} ->
        {:noreply, put_flash(socket, :error, "A backup is already running.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Domain not found.")}
    end
  end

  @impl true
  def handle_event("run_now", _, %{assigns: %{running: true}} = socket) do
    {:noreply, put_flash(socket, :error, "A backup is already running.")}
  end

  def handle_event("run_now", _, socket) do
    case Runner.run_now() do
      :ok ->
        {:noreply,
         socket
         |> assign(:running, true)
         |> assign(:progress_messages, [])
         |> put_flash(:info, "Backup started.")}

      {:error, :already_running} ->
        {:noreply, put_flash(socket, :error, "A backup is already running.")}
    end
  end

  @impl true
  def handle_info({:backup_started, _log_id}, socket) do
    {:noreply, socket |> assign(:running, true) |> assign(:progress_messages, [])}
  end

  def handle_info({:backup_progress, message}, socket) do
    messages = [message | socket.assigns.progress_messages] |> Enum.take(50)
    {:noreply, assign(socket, :progress_messages, messages)}
  end

  def handle_info({:backup_completed, log}, socket) do
    logs = Backup.list_logs()

    {:noreply,
     socket
     |> assign(:running, false)
     |> assign(:progress_messages, [])
     |> stream(:logs, logs, reset: true)
     |> put_flash(
       :info,
       "Backup completed successfully (#{format_bytes(log.file_size_bytes || 0)})."
     )}
  end

  def handle_info({:backup_failed, log}, socket) do
    logs = Backup.list_logs()
    error = (log && log.error_message) || "Backup failed with an unexpected error."

    {:noreply,
     socket
     |> assign(:running, false)
     |> assign(:progress_messages, [])
     |> stream(:logs, logs, reset: true)
     |> put_flash(:error, "Backup failed: #{error}")}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp format_bytes(nil), do: "—"

  defp format_bytes(bytes) when bytes >= 1_073_741_824,
    do: "#{Float.round(bytes / 1_073_741_824, 1)} GB"

  defp format_bytes(bytes) when bytes >= 1_048_576, do: "#{Float.round(bytes / 1_048_576, 1)} MB"
  defp format_bytes(bytes) when bytes >= 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes), do: "#{bytes} B"

  defp day_name(1), do: "Monday"
  defp day_name(2), do: "Tuesday"
  defp day_name(3), do: "Wednesday"
  defp day_name(4), do: "Thursday"
  defp day_name(5), do: "Friday"
  defp day_name(6), do: "Saturday"
  defp day_name(7), do: "Sunday"
  defp day_name(_), do: "Monday"

  defp build_exclude_picker(scope, id, name, root, excluded_dirs) do
    case list_directories(root, "") do
      {:ok, entries} ->
        {:ok,
         %{
           scope: scope,
           id: id,
           name: name,
           root: root,
           current_path: "",
           entries: entries,
           selected: MapSet.new(excluded_dirs || [])
         }}

      {:error, _} = error ->
        error
    end
  end

  defp list_directories(root, rel_path) when is_binary(root) and root != "" do
    path = if rel_path == "", do: root, else: Path.join(root, rel_path)

    if File.dir?(path) do
      entries =
        case File.ls(path) do
          {:ok, names} ->
            names
            |> Enum.filter(fn name -> File.dir?(Path.join(path, name)) end)
            |> Enum.sort()
            |> Enum.map(fn name ->
              %{name: name, path: join_rel(rel_path, name)}
            end)

          _ ->
            []
        end

      {:ok, entries}
    else
      {:error, :not_dir}
    end
  end

  defp list_directories(_, _), do: {:ok, []}

  defp normalize_rel_path(path) do
    path
    |> String.trim()
    |> String.trim_leading("/")
    |> String.split("/", trim: true)
    |> Enum.reject(&(&1 in ["", ".", ".."] or String.contains?(&1, "..")))
    |> Enum.join("/")
  end

  defp join_rel("", name), do: name
  defp join_rel(rel, name), do: Path.join(rel, name)

  defp trigger_label("manual_domain"), do: "Manual Domain"
  defp trigger_label(nil), do: "Manual"
  defp trigger_label(other), do: String.capitalize(other)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_tab={@active_tab}>
      <div class="max-w-4xl mx-auto px-4 py-8 space-y-8">
        <%!-- Page header --%>
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-bold text-gray-900 dark:text-white">Backup</h1>
            <p class="mt-1 text-sm text-gray-500 dark:text-gray-400">
              Back up your database and site files locally and to S3-compatible storage.
            </p>
          </div>
          <button
            id="run-backup-btn"
            phx-click="run_now"
            disabled={@running}
            class={[
              "inline-flex items-center gap-2 px-4 py-2 rounded-lg text-sm font-medium transition-all",
              if(@running,
                do:
                  "bg-gray-200 text-gray-400 cursor-not-allowed dark:bg-gray-700 dark:text-gray-500",
                else: "bg-indigo-600 text-white hover:bg-indigo-700 active:scale-95 shadow-sm"
              )
            ]}
          >
            <%= if @running do %>
              <svg class="w-4 h-4 animate-spin" fill="none" viewBox="0 0 24 24">
                <circle
                  class="opacity-25"
                  cx="12"
                  cy="12"
                  r="10"
                  stroke="currentColor"
                  stroke-width="4"
                />
                <path
                  class="opacity-75"
                  fill="currentColor"
                  d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"
                />
              </svg>
              Running…
            <% else %>
              <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> Run Backup Now
            <% end %>
          </button>
        </div>

        <%!-- Progress log (visible while running) --%>
        <%= if @running and @progress_messages != [] do %>
          <div class="rounded-xl border border-indigo-200 bg-indigo-50 dark:border-indigo-900 dark:bg-indigo-950/40 p-4">
            <p class="text-xs font-semibold uppercase tracking-wider text-indigo-600 dark:text-indigo-400 mb-2">
              Backup in progress
            </p>
            <div
              id="progress-log"
              class="space-y-0.5 font-mono text-xs text-indigo-800 dark:text-indigo-300"
            >
              <%= for msg <- Enum.reverse(@progress_messages) do %>
                <div>{msg}</div>
              <% end %>
            </div>
          </div>
        <% end %>

        <%!-- Settings card --%>
        <div class="bg-white dark:bg-gray-900 rounded-2xl shadow-sm border border-gray-200 dark:border-gray-800 overflow-hidden">
          <div class="border-b border-gray-200 dark:border-gray-800 px-6 pt-5 pb-0">
            <h2 class="text-base font-semibold text-gray-900 dark:text-white mb-4">Settings</h2>
            <%!-- Internal tabs --%>
            <div class="flex gap-6">
              <button
                id="tab-local"
                phx-click="switch_tab"
                phx-value-tab="local"
                class={[
                  "pb-3 text-sm font-medium border-b-2 transition-colors",
                  if(@settings_tab == :local,
                    do: "border-indigo-600 text-indigo-600",
                    else:
                      "border-transparent text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200"
                  )
                ]}
              >
                Local
              </button>
              <button
                id="tab-s3"
                phx-click="switch_tab"
                phx-value-tab="s3"
                class={[
                  "pb-3 text-sm font-medium border-b-2 transition-colors",
                  if(@settings_tab == :s3,
                    do: "border-indigo-600 text-indigo-600",
                    else:
                      "border-transparent text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200"
                  )
                ]}
              >
                Remote (S3)
              </button>
              <button
                id="tab-schedule"
                phx-click="switch_tab"
                phx-value-tab="schedule"
                class={[
                  "pb-3 text-sm font-medium border-b-2 transition-colors",
                  if(@settings_tab == :schedule,
                    do: "border-indigo-600 text-indigo-600",
                    else:
                      "border-transparent text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200"
                  )
                ]}
              >
                Schedule
              </button>
              <button
                id="tab-domains"
                phx-click="switch_tab"
                phx-value-tab="domains"
                class={[
                  "pb-3 text-sm font-medium border-b-2 transition-colors",
                  if(@settings_tab == :domains,
                    do: "border-indigo-600 text-indigo-600",
                    else:
                      "border-transparent text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200"
                  )
                ]}
              >
                Domains
              </button>
            </div>
          </div>

          <.form
            for={@form}
            id="backup-settings-form"
            phx-change="validate"
            phx-submit="save"
            class={["p-6 space-y-6", @settings_tab == :domains && "hidden"]}
          >
            <%!-- What to back up (always visible on non-domains tabs) --%>
            <fieldset>
              <legend class="text-sm font-medium text-gray-700 dark:text-gray-300 mb-3">
                What to include
              </legend>
              <div class="flex flex-col gap-3">
                <label class="flex items-center gap-3 cursor-pointer">
                  <.input
                    field={@form[:backup_database]}
                    type="checkbox"
                    class="w-4 h-4 rounded border-gray-300 text-indigo-600 focus:ring-indigo-500"
                  />
                  <span class="text-sm text-gray-700 dark:text-gray-300">
                    Panel database (Hostctl PostgreSQL)
                  </span>
                </label>
                <label class="flex items-center gap-3 cursor-pointer">
                  <.input
                    field={@form[:backup_mysql]}
                    type="checkbox"
                    class="w-4 h-4 rounded border-gray-300 text-indigo-600 focus:ring-indigo-500"
                  />
                  <span class="text-sm text-gray-700 dark:text-gray-300">
                    User databases (MySQL / MariaDB / PostgreSQL)
                    <span class="text-gray-400 dark:text-gray-500 text-xs">
                      (all hosted databases)
                    </span>
                  </span>
                </label>
                <label class="flex items-center gap-3 cursor-pointer">
                  <.input
                    field={@form[:backup_files]}
                    type="checkbox"
                    class="w-4 h-4 rounded border-gray-300 text-indigo-600 focus:ring-indigo-500"
                  />
                  <span class="text-sm text-gray-700 dark:text-gray-300">
                    Domain document roots
                    <span class="text-gray-400 dark:text-gray-500 text-xs">(may be large)</span>
                  </span>
                </label>
                <label class="flex items-center gap-3 cursor-pointer">
                  <.input
                    field={@form[:backup_mail]}
                    type="checkbox"
                    class="w-4 h-4 rounded border-gray-300 text-indigo-600 focus:ring-indigo-500"
                  />
                  <span class="text-sm text-gray-700 dark:text-gray-300">
                    Mailboxes
                    <span class="text-gray-400 dark:text-gray-500 text-xs">
                      (per-domain, configurable on Domains tab)
                    </span>
                  </span>
                </label>
              </div>
            </fieldset>

            <%!-- Local tab --%>
            <%= if @settings_tab == :local do %>
              <div id="local-settings" class="space-y-5">
                <label class="flex items-center gap-3 cursor-pointer">
                  <.input
                    field={@form[:local_enabled]}
                    type="checkbox"
                    class="w-4 h-4 rounded border-gray-300 text-indigo-600 focus:ring-indigo-500"
                  />
                  <span class="text-sm font-medium text-gray-700 dark:text-gray-300">
                    Enable local backup
                  </span>
                </label>

                <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
                  <div>
                    <.input
                      field={@form[:local_path]}
                      type="text"
                      label="Backup directory"
                      placeholder="/var/backups/hostctl"
                    />
                  </div>
                  <div>
                    <.input
                      field={@form[:local_retention_days]}
                      type="number"
                      label="Retention (days)"
                      min="1"
                    />
                  </div>
                </div>
              </div>
            <% end %>

            <%!-- S3 tab --%>
            <%= if @settings_tab == :s3 do %>
              <div id="s3-settings" class="space-y-5">
                <label class="flex items-center gap-3 cursor-pointer">
                  <.input
                    field={@form[:s3_enabled]}
                    type="checkbox"
                    class="w-4 h-4 rounded border-gray-300 text-indigo-600 focus:ring-indigo-500"
                  />
                  <span class="text-sm font-medium text-gray-700 dark:text-gray-300">
                    Enable S3-compatible remote backup
                  </span>
                </label>

                <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
                  <div class="sm:col-span-2">
                    <.input
                      field={@form[:s3_endpoint]}
                      type="text"
                      label="Endpoint URL"
                      placeholder="https://s3.amazonaws.com  (AWS) or your MinIO/B2 endpoint"
                    />
                    <p class="mt-1 text-xs text-gray-400">
                      Leave blank to use AWS S3. For S3-compatible services (MinIO, Backblaze B2,
                      Wasabi) enter the full endpoint URL.
                    </p>
                  </div>
                  <div>
                    <.input
                      field={@form[:s3_region]}
                      type="text"
                      label="Region"
                      placeholder="us-east-1"
                    />
                  </div>
                  <div>
                    <.input
                      field={@form[:s3_bucket]}
                      type="text"
                      label="Bucket"
                      placeholder="my-backups"
                    />
                  </div>
                  <div>
                    <.input
                      field={@form[:s3_access_key_id]}
                      type="text"
                      label="Access Key ID"
                      placeholder="AKIAIOSFODNN7EXAMPLE"
                      autocomplete="off"
                    />
                  </div>
                  <div>
                    <.input
                      field={@form[:s3_secret_access_key]}
                      type="password"
                      label="Secret Access Key"
                      placeholder="••••••••••••••••••••••••••••••••"
                      autocomplete="new-password"
                    />
                  </div>
                  <div>
                    <.input
                      field={@form[:s3_path_prefix]}
                      type="text"
                      label="Path prefix"
                      placeholder="hostctl-backups"
                    />
                    <p class="mt-1 text-xs text-gray-400">
                      Folder/prefix inside the bucket where backups are stored.
                    </p>
                  </div>
                  <div>
                    <.input
                      field={@form[:s3_retention_days]}
                      type="number"
                      label="Retention (days)"
                      min="1"
                    />
                  </div>
                </div>

                <%!-- Upload mode --%>
                <div class="border border-gray-200 dark:border-gray-700 rounded-xl p-4 space-y-3">
                  <p class="text-sm font-medium text-gray-700 dark:text-gray-300">Upload mode</p>
                  <label class="flex items-start gap-3 cursor-pointer group">
                    <input
                      type="radio"
                      name={@form[:s3_mode].name}
                      id="s3_mode_archive"
                      value="archive"
                      checked={
                        Phoenix.HTML.Form.normalize_value(
                          "checkbox",
                          @form[:s3_mode].value == "archive"
                        )
                      }
                      class="mt-0.5 w-4 h-4 border-gray-300 text-indigo-600 focus:ring-indigo-500"
                    />
                    <div>
                      <span class="text-sm font-medium text-gray-700 dark:text-gray-300">
                        Single archive <span class="text-xs font-normal text-gray-400">.tar.gz</span>
                      </span>
                      <p class="text-xs text-gray-400 dark:text-gray-500 mt-0.5">
                        Combines everything into one compressed archive before uploading.
                        Requires temporary free disk space equal to the compressed archive size.
                      </p>
                    </div>
                  </label>
                  <label class="flex items-start gap-3 cursor-pointer group">
                    <input
                      type="radio"
                      name={@form[:s3_mode].name}
                      id="s3_mode_stream"
                      value="stream"
                      checked={
                        Phoenix.HTML.Form.normalize_value(
                          "checkbox",
                          @form[:s3_mode].value == "stream"
                        )
                      }
                      class="mt-0.5 w-4 h-4 border-gray-300 text-indigo-600 focus:ring-indigo-500"
                    />
                    <div>
                      <span class="text-sm font-medium text-gray-700 dark:text-gray-300">
                        Stream directly to S3
                        <span class="text-xs font-normal text-gray-400">
                          recommended for large sites / limited disk
                        </span>
                      </span>
                      <p class="text-xs text-gray-400 dark:text-gray-500 mt-0.5">
                        Pipes each domain's files directly to S3 via multipart upload—no temp files
                        written to disk. Produces one <code>.tar.gz</code>
                        per domain under the prefix folder.
                      </p>
                    </div>
                  </label>
                </div>
              </div>
            <% end %>

            <%!-- Schedule tab --%>
            <%= if @settings_tab == :schedule do %>
              <div id="schedule-settings" class="space-y-5">
                <label class="flex items-center gap-3 cursor-pointer">
                  <.input
                    field={@form[:schedule_enabled]}
                    type="checkbox"
                    class="w-4 h-4 rounded border-gray-300 text-indigo-600 focus:ring-indigo-500"
                  />
                  <span class="text-sm font-medium text-gray-700 dark:text-gray-300">
                    Enable automatic scheduled backups
                  </span>
                </label>

                <div class="grid grid-cols-1 gap-4 sm:grid-cols-3">
                  <div>
                    <.input
                      field={@form[:schedule_frequency]}
                      type="select"
                      label="Frequency"
                      options={[{"Daily", "daily"}, {"Weekly", "weekly"}]}
                    />
                  </div>
                  <div>
                    <.input
                      field={@form[:schedule_hour]}
                      type="select"
                      label="Hour (UTC)"
                      options={
                        Enum.map(0..23, fn h ->
                          {String.pad_leading(to_string(h), 2, "0") <> ":00", h}
                        end)
                      }
                    />
                  </div>
                  <div>
                    <.input
                      field={@form[:schedule_minute]}
                      type="select"
                      label="Minute"
                      options={
                        Enum.map([0, 15, 30, 45], fn m ->
                          {String.pad_leading(to_string(m), 2, "0"), m}
                        end)
                      }
                    />
                  </div>
                  <div>
                    <.input
                      field={@form[:schedule_day_of_week]}
                      type="select"
                      label="Day of week (weekly only)"
                      options={Enum.map(1..7, fn d -> {day_name(d), d} end)}
                    />
                  </div>
                </div>

                <p class="text-xs text-gray-400 dark:text-gray-500">
                  All times are UTC. For weekly backups, the day-of-week setting only applies
                  when "Weekly" frequency is selected. At least one destination (local or S3)
                  must be enabled for scheduled backups to store anything.
                </p>
              </div>
            <% end %>

            <%!-- Save row --%>
            <div class="flex justify-end pt-2 border-t border-gray-100 dark:border-gray-800">
              <button
                id="save-backup-settings-btn"
                type="submit"
                class="px-5 py-2 rounded-lg bg-indigo-600 text-white text-sm font-medium hover:bg-indigo-700 active:scale-95 transition-all shadow-sm"
              >
                Save settings
              </button>
            </div>
          </.form>

          <%!-- Domains tab (outside the form, manages its own events) --%>
          <%= if @settings_tab == :domains do %>
            <div id="domains-settings" class="divide-y divide-gray-100 dark:divide-gray-800">
              <%!-- Header row --%>
              <div class="flex items-center gap-4 px-6 py-3 bg-gray-50 dark:bg-gray-800/50">
                <span class="flex-1 text-xs font-semibold uppercase tracking-wider text-gray-500 dark:text-gray-400">
                  Domain / Subdomain
                </span>
                <span class="text-xs font-semibold uppercase tracking-wider text-gray-500 dark:text-gray-400 w-20 text-center">
                  Include files
                </span>
                <span class="text-xs font-semibold uppercase tracking-wider text-gray-500 dark:text-gray-400 w-20 text-center">
                  Include mail
                </span>
                <span
                  class="text-xs font-semibold uppercase tracking-wider text-gray-500 dark:text-gray-400 w-52 text-center"
                  title={"Global default: #{@setting.s3_mode || "archive"}"}
                >
                  S3 mode
                  <span class="normal-case font-normal text-gray-400 dark:text-gray-500">
                    (global: {@setting.s3_mode || "archive"})
                  </span>
                </span>
              </div>

              <%!-- Empty state --%>
              <%= if @domain_groups == [] do %>
                <div class="flex flex-col items-center justify-center py-12 gap-2 text-center">
                  <.icon name="hero-globe-alt" class="w-8 h-8 text-gray-300 dark:text-gray-600" />
                  <p class="text-sm text-gray-400 dark:text-gray-500">No domains found.</p>
                  <p class="text-xs text-gray-400 dark:text-gray-500">
                    Add domains to configure per-domain backup settings.
                  </p>
                </div>
              <% end %>

              <%!-- Domain + subdomain rows --%>
              <%= for group <- @domain_groups do %>
                <%!-- Domain row --%>
                <div
                  id={"backup-domain-#{group.id}"}
                  class="flex items-center gap-4 px-6 py-4 hover:bg-gray-50 dark:hover:bg-gray-800/40 transition-colors"
                >
                  <div class="flex-1 min-w-0">
                    <div class="flex items-center gap-2">
                      <p class="text-sm font-medium text-gray-900 dark:text-white truncate">
                        {group.name}
                      </p>
                      <button
                        id={"domain-excludes-#{group.id}"}
                        phx-click="open_domain_excludes"
                        phx-value-domain-id={group.id}
                        class="inline-flex items-center gap-1 rounded-md px-2 py-0.5 text-xs font-medium transition-colors bg-gray-100 text-gray-600 hover:bg-gray-200 dark:bg-gray-800 dark:text-gray-300 dark:hover:bg-gray-700"
                        title="Choose directories to exclude"
                      >
                        <.icon name="hero-folder-minus" class="w-3 h-3" /> Exclude dirs
                      </button>
                      <button
                        id={"run-domain-backup-#{group.id}"}
                        phx-click="run_domain_now"
                        phx-value-domain-id={group.id}
                        disabled={@running}
                        class={[
                          "inline-flex items-center gap-1 rounded-md px-2 py-0.5 text-xs font-medium transition-colors",
                          if(@running,
                            do:
                              "bg-gray-100 text-gray-400 cursor-not-allowed dark:bg-gray-800 dark:text-gray-600",
                            else:
                              "bg-indigo-50 text-indigo-700 hover:bg-indigo-100 dark:bg-indigo-900/30 dark:text-indigo-300 dark:hover:bg-indigo-900/50"
                          )
                        ]}
                      >
                        <.icon name="hero-play" class="w-3 h-3" /> One-off
                      </button>
                    </div>
                    <p class="text-xs text-gray-400 dark:text-gray-500 truncate mt-0.5">
                      {group.document_root}
                    </p>
                  </div>
                  <div class="w-20 flex justify-center">
                    <button
                      id={"toggle-domain-#{group.id}"}
                      phx-click="toggle_domain_files"
                      phx-value-domain-id={group.id}
                      phx-value-current={to_string(group.include_files)}
                      title={
                        if(group.include_files,
                          do: "Included – click to exclude",
                          else: "Excluded – click to include"
                        )
                      }
                      class={[
                        "relative inline-flex h-6 w-11 shrink-0 cursor-pointer rounded-full border-2 border-transparent",
                        "transition-colors duration-200 ease-in-out focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-offset-2",
                        if(group.include_files,
                          do: "bg-indigo-600",
                          else: "bg-gray-200 dark:bg-gray-700"
                        )
                      ]}
                      role="switch"
                      aria-checked={to_string(group.include_files)}
                    >
                      <span
                        aria-hidden="true"
                        class={[
                          "pointer-events-none inline-block h-5 w-5 rounded-full bg-white shadow ring-0",
                          "transition duration-200 ease-in-out",
                          if(group.include_files, do: "translate-x-5", else: "translate-x-0")
                        ]}
                      />
                    </button>
                  </div>
                  <%!-- Include mail toggle for domain --%>
                  <div class="w-20 flex justify-center">
                    <button
                      id={"toggle-domain-mail-#{group.id}"}
                      phx-click="toggle_domain_mail"
                      phx-value-domain-id={group.id}
                      phx-value-current={to_string(group.include_mail)}
                      title={
                        if(group.include_mail,
                          do: "Mail included – click to exclude",
                          else: "Mail excluded – click to include"
                        )
                      }
                      class={[
                        "relative inline-flex h-6 w-11 shrink-0 cursor-pointer rounded-full border-2 border-transparent",
                        "transition-colors duration-200 ease-in-out focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-offset-2",
                        if(group.include_mail,
                          do: "bg-indigo-600",
                          else: "bg-gray-200 dark:bg-gray-700"
                        )
                      ]}
                      role="switch"
                      aria-checked={to_string(group.include_mail)}
                    >
                      <span
                        aria-hidden="true"
                        class={[
                          "pointer-events-none inline-block h-5 w-5 rounded-full bg-white shadow ring-0",
                          "transition duration-200 ease-in-out",
                          if(group.include_mail, do: "translate-x-5", else: "translate-x-0")
                        ]}
                      />
                    </button>
                  </div>
                  <%!-- S3 mode selector for domain --%>
                  <div class="w-52 flex justify-center">
                    <div class="inline-flex rounded-lg border border-gray-200 dark:border-gray-700 overflow-hidden text-xs">
                      <%= for {label, val} <- [{"Global", "global"}, {"Archive", "archive"}, {"Stream", "stream"}, {"Raw", "raw"}] do %>
                        <button
                          id={"domain-s3mode-#{group.id}-#{val}"}
                          phx-click="set_domain_s3_mode"
                          phx-value-domain-id={group.id}
                          phx-value-mode={val}
                          class={[
                            "px-3 py-1.5 font-medium transition-colors",
                            if(
                              (val == "global" and is_nil(group.s3_mode)) or
                                group.s3_mode == val,
                              do: "bg-indigo-600 text-white",
                              else:
                                "bg-white dark:bg-gray-900 text-gray-600 dark:text-gray-400 hover:bg-gray-50 dark:hover:bg-gray-800"
                            )
                          ]}
                        >
                          {label}
                        </button>
                      <% end %>
                    </div>
                  </div>
                </div>

                <%!-- Subdomain rows (indented) --%>
                <%= for sub <- group.subdomains do %>
                  <div
                    id={"backup-subdomain-#{sub.id}"}
                    class="flex items-center gap-4 pl-10 pr-6 py-3 bg-gray-50/50 dark:bg-gray-800/20 hover:bg-gray-50 dark:hover:bg-gray-800/40 transition-colors"
                  >
                    <div class="flex items-center gap-2 flex-1 min-w-0">
                      <.icon
                        name="hero-arrow-turn-down-right"
                        class="w-3 h-3 text-gray-300 dark:text-gray-600 shrink-0"
                      />
                      <div class="min-w-0">
                        <div class="flex items-center gap-2">
                          <p class="text-sm text-gray-700 dark:text-gray-300 truncate">
                            {sub.full_name}
                          </p>
                          <button
                            id={"subdomain-excludes-#{sub.id}"}
                            phx-click="open_subdomain_excludes"
                            phx-value-subdomain-id={sub.id}
                            class="inline-flex items-center gap-1 rounded-md px-2 py-0.5 text-xs font-medium transition-colors bg-gray-100 text-gray-600 hover:bg-gray-200 dark:bg-gray-800 dark:text-gray-300 dark:hover:bg-gray-700"
                            title="Choose directories to exclude"
                          >
                            <.icon name="hero-folder-minus" class="w-3 h-3" /> Exclude dirs
                          </button>
                        </div>
                        <p class="text-xs text-gray-400 dark:text-gray-500 truncate mt-0.5">
                          {sub.document_root}
                        </p>
                      </div>
                    </div>
                    <div class="w-20 flex justify-center">
                      <button
                        id={"toggle-subdomain-#{sub.id}"}
                        phx-click="toggle_subdomain_files"
                        phx-value-subdomain-id={sub.id}
                        phx-value-current={to_string(sub.include_files)}
                        title={
                          if(sub.include_files,
                            do: "Included – click to exclude",
                            else: "Excluded – click to include"
                          )
                        }
                        class={[
                          "relative inline-flex h-6 w-11 shrink-0 cursor-pointer rounded-full border-2 border-transparent",
                          "transition-colors duration-200 ease-in-out focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-offset-2",
                          if(sub.include_files,
                            do: "bg-indigo-600",
                            else: "bg-gray-200 dark:bg-gray-700"
                          )
                        ]}
                        role="switch"
                        aria-checked={to_string(sub.include_files)}
                      >
                        <span
                          aria-hidden="true"
                          class={[
                            "pointer-events-none inline-block h-5 w-5 rounded-full bg-white shadow ring-0",
                            "transition duration-200 ease-in-out",
                            if(sub.include_files, do: "translate-x-5", else: "translate-x-0")
                          ]}
                        />
                      </button>
                    </div>
                    <%!-- Empty mail column for subdomains (mail is per-domain only) --%>
                    <div class="w-20"></div>
                    <%!-- S3 mode selector for subdomain --%>
                    <div class="w-52 flex justify-center">
                      <div class="inline-flex rounded-lg border border-gray-200 dark:border-gray-700 overflow-hidden text-xs">
                        <%= for {label, val} <- [{"Global", "global"}, {"Archive", "archive"}, {"Stream", "stream"}, {"Raw", "raw"}] do %>
                          <button
                            id={"subdomain-s3mode-#{sub.id}-#{val}"}
                            phx-click="set_subdomain_s3_mode"
                            phx-value-subdomain-id={sub.id}
                            phx-value-mode={val}
                            class={[
                              "px-3 py-1.5 font-medium transition-colors",
                              if(
                                (val == "global" and is_nil(sub.s3_mode)) or
                                  sub.s3_mode == val,
                                do: "bg-indigo-600 text-white",
                                else:
                                  "bg-white dark:bg-gray-900 text-gray-600 dark:text-gray-400 hover:bg-gray-50 dark:hover:bg-gray-800"
                              )
                            ]}
                          >
                            {label}
                          </button>
                        <% end %>
                      </div>
                    </div>
                  </div>
                <% end %>
              <% end %>

              <%!-- Footer note --%>
              <div class="px-6 py-3 bg-gray-50 dark:bg-gray-800/30">
                <p class="text-xs text-gray-400 dark:text-gray-500">
                  Controls which domain document roots and mailboxes are included in backups.
                  Mail is per-domain (covers all accounts under that domain). Changes take effect on the next backup run.
                </p>
              </div>
            </div>
          <% end %>
        </div>

        <%= if @exclude_picker do %>
          <div class="fixed inset-0 z-50 flex items-center justify-center p-4">
            <div class="absolute inset-0 bg-black/50" phx-click="close_excludes"></div>
            <div class="relative w-full max-w-2xl bg-white dark:bg-gray-900 rounded-2xl shadow-xl border border-gray-200 dark:border-gray-800 overflow-hidden">
              <div class="px-5 py-4 border-b border-gray-200 dark:border-gray-800">
                <div class="flex items-center justify-between gap-3">
                  <div>
                    <h3 class="text-sm font-semibold text-gray-900 dark:text-white">
                      Exclude Directories
                    </h3>
                    <p class="text-xs text-gray-500 dark:text-gray-400 mt-0.5">
                      {@exclude_picker.name}
                    </p>
                  </div>
                  <button
                    id="close-excludes"
                    phx-click="close_excludes"
                    class="inline-flex items-center justify-center rounded-md p-1.5 text-gray-400 hover:text-gray-600 hover:bg-gray-100 dark:hover:bg-gray-800 dark:hover:text-gray-200"
                  >
                    <.icon name="hero-x-mark" class="w-4 h-4" />
                  </button>
                </div>
              </div>

              <div class="px-5 py-4 space-y-3">
                <div class="flex items-center gap-2">
                  <button
                    id="exclude-root"
                    phx-click="exclude_open_path"
                    phx-value-path=""
                    class="text-xs px-2 py-1 rounded-md bg-gray-100 text-gray-600 hover:bg-gray-200 dark:bg-gray-800 dark:text-gray-300"
                  >
                    Root
                  </button>
                  <button
                    id="exclude-up"
                    phx-click="exclude_up"
                    class="text-xs px-2 py-1 rounded-md bg-gray-100 text-gray-600 hover:bg-gray-200 dark:bg-gray-800 dark:text-gray-300"
                  >
                    Up
                  </button>
                  <span class="text-xs text-gray-500 dark:text-gray-400 font-mono truncate">
                    {if @exclude_picker.current_path == "",
                      do: "/",
                      else: "/#{@exclude_picker.current_path}"}
                  </span>
                </div>

                <div class="max-h-80 overflow-auto rounded-lg border border-gray-200 dark:border-gray-800 divide-y divide-gray-100 dark:divide-gray-800">
                  <%= if @exclude_picker.entries == [] do %>
                    <div class="px-4 py-6 text-center text-xs text-gray-400 dark:text-gray-500">
                      No subdirectories here.
                    </div>
                  <% end %>

                  <%= for entry <- @exclude_picker.entries do %>
                    <div class="px-4 py-2.5 flex items-center gap-3">
                      <div class="flex-1 min-w-0">
                        <p class="text-sm text-gray-800 dark:text-gray-200 truncate">{entry.name}</p>
                        <p class="text-xs text-gray-400 dark:text-gray-500 font-mono truncate">
                          /{entry.path}
                        </p>
                      </div>
                      <button
                        id={"open-exclude-path-#{entry.path}"}
                        phx-click="exclude_open_path"
                        phx-value-path={entry.path}
                        class="text-xs px-2 py-1 rounded-md bg-gray-100 text-gray-600 hover:bg-gray-200 dark:bg-gray-800 dark:text-gray-300"
                      >
                        Open
                      </button>
                      <button
                        id={"toggle-exclude-path-#{entry.path}"}
                        phx-click="toggle_excluded_dir"
                        phx-value-path={entry.path}
                        phx-value-current={
                          to_string(MapSet.member?(@exclude_picker.selected, entry.path))
                        }
                        class={[
                          "text-xs px-2.5 py-1 rounded-md font-medium",
                          if(MapSet.member?(@exclude_picker.selected, entry.path),
                            do: "bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-300",
                            else:
                              "bg-emerald-100 text-emerald-700 dark:bg-emerald-900/30 dark:text-emerald-300"
                          )
                        ]}
                      >
                        <%= if MapSet.member?(@exclude_picker.selected, entry.path) do %>
                          Excluded
                        <% else %>
                          Include
                        <% end %>
                      </button>
                    </div>
                  <% end %>
                </div>

                <div class="text-xs text-gray-500 dark:text-gray-400">
                  Selected exclusions: {MapSet.size(@exclude_picker.selected)}
                </div>
              </div>

              <div class="px-5 py-3 border-t border-gray-200 dark:border-gray-800 flex items-center justify-end gap-2">
                <button
                  id="cancel-excludes"
                  phx-click="close_excludes"
                  class="px-3 py-1.5 rounded-md text-sm bg-gray-100 text-gray-600 hover:bg-gray-200 dark:bg-gray-800 dark:text-gray-300"
                >
                  Cancel
                </button>
                <button
                  id="save-excludes"
                  phx-click="save_excludes"
                  class="px-3 py-1.5 rounded-md text-sm bg-indigo-600 text-white hover:bg-indigo-700"
                >
                  Save exclusions
                </button>
              </div>
            </div>
          </div>
        <% end %>

        <%!-- History card --%>
        <div class="bg-white dark:bg-gray-900 rounded-2xl shadow-sm border border-gray-200 dark:border-gray-800 overflow-hidden">
          <div class="px-6 py-5 border-b border-gray-200 dark:border-gray-800">
            <h2 class="text-base font-semibold text-gray-900 dark:text-white">History</h2>
          </div>

          <div
            id="backup-logs"
            phx-update="stream"
            class="divide-y divide-gray-100 dark:divide-gray-800"
          >
            <div class="hidden only:flex items-center justify-center py-12 text-sm text-gray-400 dark:text-gray-500">
              No backups have been run yet.
            </div>
            <%= for {id, log} <- @streams.logs do %>
              <div
                id={id}
                class="flex items-center gap-4 px-6 py-4 hover:bg-gray-50 dark:hover:bg-gray-800/50 transition-colors"
              >
                <%!-- Status badge --%>
                <div class={[
                  "shrink-0 inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full text-xs font-semibold",
                  log.status == "success" &&
                    "bg-emerald-100 text-emerald-700 dark:bg-emerald-900/40 dark:text-emerald-400",
                  log.status == "failed" &&
                    "bg-red-100 text-red-700 dark:bg-red-900/40 dark:text-red-400",
                  log.status == "running" &&
                    "bg-indigo-100 text-indigo-700 dark:bg-indigo-900/40 dark:text-indigo-400",
                  log.status == "pending" &&
                    "bg-gray-100 text-gray-600 dark:bg-gray-800 dark:text-gray-400"
                ]}>
                  <%= cond do %>
                    <% log.status == "success" -> %>
                      <.icon name="hero-check-circle" class="w-3.5 h-3.5" /> Success
                    <% log.status == "failed" -> %>
                      <.icon name="hero-x-circle" class="w-3.5 h-3.5" /> Failed
                    <% log.status == "running" -> %>
                      <.icon name="hero-arrow-path" class="w-3.5 h-3.5" /> Running
                    <% true -> %>
                      <.icon name="hero-clock" class="w-3.5 h-3.5" /> Pending
                  <% end %>
                </div>

                <%!-- Details --%>
                <div class="flex-1 min-w-0">
                  <div class="flex items-center gap-3 flex-wrap">
                    <span class="text-sm font-medium text-gray-900 dark:text-white">
                      {if log.started_at,
                        do: Calendar.strftime(log.started_at, "%Y-%m-%d %H:%M UTC"),
                        else: "—"}
                    </span>
                    <span class={[
                      "text-xs px-2 py-0.5 rounded-full font-medium",
                      log.trigger == "scheduled" &&
                        "bg-blue-50 text-blue-600 dark:bg-blue-900/30 dark:text-blue-400",
                      log.trigger == "manual_domain" &&
                        "bg-indigo-50 text-indigo-600 dark:bg-indigo-900/30 dark:text-indigo-400",
                      log.trigger == "manual" &&
                        "bg-gray-100 text-gray-500 dark:bg-gray-800 dark:text-gray-400"
                    ]}>
                      {trigger_label(log.trigger)}
                    </span>
                    <%= if log.destination do %>
                      <span class="text-xs text-gray-400 dark:text-gray-500">
                        → {log.destination}
                      </span>
                    <% end %>
                  </div>
                  <%= if log.error_message do %>
                    <p class="mt-0.5 text-xs text-red-500 dark:text-red-400 truncate">
                      {log.error_message}
                    </p>
                  <% end %>
                </div>

                <%!-- Size --%>
                <div class="shrink-0 text-sm text-gray-500 dark:text-gray-400">
                  {format_bytes(log.file_size_bytes)}
                </div>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
