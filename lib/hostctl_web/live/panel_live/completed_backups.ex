defmodule HostctlWeb.PanelLive.CompletedBackups do
  use HostctlWeb, :live_view

  alias Hostctl.Backup
  alias Hostctl.Backup.{Archive, Restore, S3}

  @default_filters %{
    "query" => "",
    "trigger" => "all",
    "destination" => "all",
    "from_date" => "",
    "to_date" => ""
  }

  @impl true
  def mount(_params, _session, socket) do
    filters = @default_filters
    logs = Backup.list_completed_logs(filters)
    settings = Backup.get_or_create_settings()

    {:ok,
     socket
     |> assign(:page_title, "Completed Backups")
     |> assign(:active_tab, :panel_completed_backups)
     |> assign(:filters, filters)
     |> assign(:filter_form, to_form(filters, as: :filters))
     |> assign(:logs, logs)
     |> assign(:s3_enabled, settings.s3_enabled)
     |> assign(:s3_archives, nil)
     |> assign(:s3_loading, false)
     |> assign(:s3_error, nil)
     |> assign(:restore, nil)
     |> assign(:raw_restore, nil)}
  end

  @impl true
  def handle_event("filter", %{"filters" => params}, socket) do
    filters = normalize_filters(params)

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:filter_form, to_form(filters, as: :filters))
     |> assign(:logs, Backup.list_completed_logs(filters))}
  end

  def handle_event("reset_filters", _, socket) do
    filters = @default_filters

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:filter_form, to_form(filters, as: :filters))
     |> assign(:logs, Backup.list_completed_logs(filters))}
  end

  def handle_event("close_s3", _, socket) do
    {:noreply, socket |> assign(:s3_archives, nil) |> assign(:s3_error, nil)}
  end

  def handle_event("load_s3", _, socket) do
    send(self(), :load_s3_archives)
    {:noreply, socket |> assign(:s3_loading, true) |> assign(:s3_error, nil)}
  end

  def handle_event("restore_s3", %{"key" => s3_key}, socket) do
    settings = Backup.get_or_create_settings()
    temp_path = restore_temp_path(s3_key)

    restore_state = %{
      step: :downloading,
      s3_key: s3_key,
      local_path: nil,
      items: [],
      selected_items: MapSet.new(),
      extracted_dir: nil,
      sql_dumps: [],
      db_targets: nil,
      import_results: [],
      error: nil
    }

    socket = assign(socket, :restore, restore_state)

    lv = self()

    Task.start(fn ->
      result = S3.download(settings, s3_key, temp_path)
      send(lv, {:s3_download_complete, result, temp_path})
    end)

    {:noreply, socket}
  end

  def handle_event("toggle_restore_item", %{"item-id" => item_id}, socket) do
    restore = socket.assigns.restore
    selected = restore.selected_items

    selected =
      if MapSet.member?(selected, item_id),
        do: MapSet.delete(selected, item_id),
        else: MapSet.put(selected, item_id)

    {:noreply, assign(socket, :restore, %{restore | selected_items: selected})}
  end

  def handle_event("extract_selected", _, socket) do
    restore = socket.assigns.restore

    tar_members =
      restore.items
      |> Enum.filter(&MapSet.member?(restore.selected_items, &1.id))
      |> Enum.map(& &1.tar_member)

    if tar_members == [] do
      {:noreply, put_flash(socket, :error, "Select at least one item to restore.")}
    else
      staging_root = Path.join(System.tmp_dir!(), "hostctl-restore")

      case Archive.extract_selected(restore.local_path, tar_members, staging_root) do
        {:ok, extracted_dir} ->
          sql_dumps = Archive.list_sql_dumps(extracted_dir)
          db_targets = Backup.restore_database_targets()

          {:noreply,
           assign(socket, :restore, %{
             restore
             | step: :review_dumps,
               extracted_dir: extracted_dir,
               sql_dumps: sql_dumps,
               db_targets: db_targets,
               import_results: []
           })}

        {:error, :nothing_selected} ->
          {:noreply, put_flash(socket, :error, "No items selected.")}

        {:error, reason} ->
          {:noreply,
           assign(socket, :restore, %{
             restore
             | step: :error,
               error: "Extraction failed: #{reason}"
           })}
      end
    end
  end

  def handle_event(
        "import_sql",
        %{"dump_path" => dump_path, "kind" => kind, "target_db" => target_db},
        socket
      ) do
    restore = socket.assigns.restore

    result =
      case Restore.import_sql(kind, dump_path, target_db) do
        :ok -> %{dump: dump_path, status: :ok, message: "Imported successfully."}
        {:ok, _} -> %{dump: dump_path, status: :ok, message: "Imported successfully."}
        {:error, reason} -> %{dump: dump_path, status: :error, message: reason}
      end

    import_results = [result | restore.import_results]

    {:noreply, assign(socket, :restore, %{restore | import_results: import_results})}
  end

  def handle_event("close_restore", _, socket) do
    cleanup_restore(socket.assigns.restore)
    {:noreply, assign(socket, :restore, nil)}
  end

  def handle_event("restore_back_to_items", _, socket) do
    restore = socket.assigns.restore

    {:noreply,
     assign(socket, :restore, %{
       restore
       | step: :select_items,
         extracted_dir: nil,
         sql_dumps: [],
         import_results: []
     })}
  end

  # Raw restore events

  def handle_event("browse_raw", _, socket) do
    send(self(), :load_raw_domains)

    {:noreply,
     assign(socket, :raw_restore, %{
       step: :loading_domains,
       domains: [],
       selected_domain: nil,
       files: [],
       file_count: 0,
       total_size: 0,
       target_dir: nil,
       s3_prefix: nil,
       progress: nil,
       error: nil
     })}
  end

  def handle_event("close_raw_restore", _, socket) do
    {:noreply, assign(socket, :raw_restore, nil)}
  end

  def handle_event("raw_select_domain", %{"domain" => domain_name}, socket) do
    send(self(), {:load_raw_domain_files, domain_name})

    raw = socket.assigns.raw_restore

    {:noreply,
     assign(socket, :raw_restore, %{
       raw
       | step: :loading_files,
         selected_domain: domain_name,
         files: [],
         error: nil
     })}
  end

  def handle_event("raw_back_to_domains", _, socket) do
    raw = socket.assigns.raw_restore

    {:noreply,
     assign(socket, :raw_restore, %{
       raw
       | step: :select_domain,
         selected_domain: nil,
         files: [],
         error: nil
     })}
  end

  def handle_event("raw_start_restore", %{"target_dir" => target_dir}, socket) do
    raw = socket.assigns.raw_restore
    target_dir = String.trim(target_dir)

    if target_dir == "" do
      {:noreply, put_flash(socket, :error, "Target directory is required.")}
    else
      if raw[:s3_prefix] do
        send(self(), {:do_prefix_restore, raw.s3_prefix, target_dir})
      else
        send(self(), {:do_raw_restore, raw.selected_domain, target_dir})
      end

      {:noreply,
       assign(socket, :raw_restore, %{
         raw
         | step: :restoring,
           target_dir: target_dir,
           progress: "Downloading files from S3…"
       })}
    end
  end

  def handle_event("restore_raw_log", %{"id" => log_id}, socket) do
    log = Backup.get_log(String.to_integer(log_id))
    domain = log_first_domain(log)
    prefix = "#{log.s3_key}/domains/#{domain}"

    send(self(), {:load_prefix_files, prefix, domain})

    {:noreply,
     assign(socket, :raw_restore, %{
       step: :loading_files,
       domains: [],
       selected_domain: domain,
       files: [],
       file_count: 0,
       total_size: 0,
       target_dir: nil,
       s3_prefix: prefix,
       progress: nil,
       error: nil
     })}
  end

  def handle_event("restore_stream_log", %{"id" => log_id}, socket) do
    log = Backup.get_log(String.to_integer(log_id))
    domain = log_first_domain(log)
    s3_key = "#{log.s3_key}/domains/#{domain}.tar.gz"

    settings = Backup.get_or_create_settings()
    temp_path = restore_temp_path(s3_key)

    restore_state = %{
      step: :downloading,
      s3_key: s3_key,
      local_path: nil,
      items: [],
      selected_items: MapSet.new(),
      extracted_dir: nil,
      sql_dumps: [],
      db_targets: nil,
      import_results: [],
      error: nil
    }

    socket = assign(socket, :restore, restore_state)

    lv = self()

    Task.start(fn ->
      result = S3.download(settings, s3_key, temp_path)
      send(lv, {:s3_download_complete, result, temp_path})
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_info(:load_s3_archives, socket) do
    case Backup.list_restore_s3_archives(100) do
      {:ok, archives} ->
        {:noreply,
         socket
         |> assign(:s3_loading, false)
         |> assign(:s3_archives, archives)
         |> assign(:s3_error, nil)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:s3_loading, false)
         |> assign(:s3_archives, [])
         |> assign(:s3_error, reason)}
    end
  end

  def handle_info({:s3_download_complete, {:ok, local_path}, _temp_path}, socket) do
    case Archive.inspect_archive(local_path) do
      {:ok, %{items: items}} ->
        {:noreply,
         assign(socket, :restore, %{
           socket.assigns.restore
           | step: :select_items,
             local_path: local_path,
             items: items,
             selected_items: MapSet.new(Enum.map(items, & &1.id))
         })}

      {:error, reason} ->
        {:noreply,
         assign(socket, :restore, %{
           socket.assigns.restore
           | step: :error,
             local_path: local_path,
             error: "Failed to inspect archive: #{reason}"
         })}
    end
  end

  def handle_info({:s3_download_complete, {:error, reason}, _temp_path}, socket) do
    {:noreply,
     assign(socket, :restore, %{
       socket.assigns.restore
       | step: :error,
         error: "Download failed: #{reason}"
     })}
  end

  # Raw restore info handlers

  def handle_info(:load_raw_domains, socket) do
    case Backup.list_raw_s3_domains() do
      {:ok, domains} ->
        {:noreply,
         assign(socket, :raw_restore, %{
           socket.assigns.raw_restore
           | step: :select_domain,
             domains: domains
         })}

      {:error, reason} ->
        {:noreply,
         assign(socket, :raw_restore, %{
           socket.assigns.raw_restore
           | step: :error,
             error: "Failed to list raw domains: #{reason}"
         })}
    end
  end

  def handle_info({:load_raw_domain_files, domain_name}, socket) do
    case Backup.list_raw_s3_domain_files(domain_name) do
      {:ok, files} ->
        total_size = files |> Enum.map(& &1[:size]) |> Enum.filter(&is_integer/1) |> Enum.sum()
        doc_root = Backup.domain_document_root(domain_name)

        {:noreply,
         assign(socket, :raw_restore, %{
           socket.assigns.raw_restore
           | step: :preview_files,
             files: Enum.take(files, 100),
             file_count: length(files),
             total_size: total_size,
             target_dir: doc_root
         })}

      {:error, reason} ->
        {:noreply,
         assign(socket, :raw_restore, %{
           socket.assigns.raw_restore
           | step: :error,
             error: "Failed to list files: #{reason}"
         })}
    end
  end

  def handle_info({:do_raw_restore, domain_name, target_dir}, socket) do
    case Backup.restore_raw_s3_domain(domain_name, target_dir) do
      {:ok, count} ->
        {:noreply,
         socket
         |> assign(:raw_restore, %{
           socket.assigns.raw_restore
           | step: :done,
             progress: "Restored #{count} files to #{target_dir}"
         })
         |> put_flash(:info, "Raw restore complete: #{count} files restored to #{target_dir}")}

      {:error, reason} ->
        {:noreply,
         assign(socket, :raw_restore, %{
           socket.assigns.raw_restore
           | step: :error,
             error: reason
         })}
    end
  end

  def handle_info({:load_prefix_files, prefix, domain_name}, socket) do
    case Backup.list_s3_prefix_files(prefix) do
      {:ok, files} ->
        total_size = files |> Enum.map(& &1[:size]) |> Enum.filter(&is_integer/1) |> Enum.sum()
        doc_root = Backup.domain_document_root(domain_name)

        {:noreply,
         assign(socket, :raw_restore, %{
           socket.assigns.raw_restore
           | step: :preview_files,
             files: Enum.take(files, 100),
             file_count: length(files),
             total_size: total_size,
             target_dir: doc_root
         })}

      {:error, reason} ->
        {:noreply,
         assign(socket, :raw_restore, %{
           socket.assigns.raw_restore
           | step: :error,
             error: "Failed to list files: #{reason}"
         })}
    end
  end

  def handle_info({:do_prefix_restore, prefix, target_dir}, socket) do
    case Backup.restore_s3_prefix_to_dir(prefix, target_dir) do
      {:ok, count} ->
        {:noreply,
         socket
         |> assign(:raw_restore, %{
           socket.assigns.raw_restore
           | step: :done,
             progress: "Restored #{count} files to #{target_dir}"
         })
         |> put_flash(:info, "Raw restore complete: #{count} files restored to #{target_dir}")}

      {:error, reason} ->
        {:noreply,
         assign(socket, :raw_restore, %{
           socket.assigns.raw_restore
           | step: :error,
             error: reason
         })}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp normalize_filters(params) do
    %{
      "query" => String.trim(params["query"] || ""),
      "trigger" => normalize_select(params["trigger"]),
      "destination" => normalize_select(params["destination"]),
      "from_date" => String.trim(params["from_date"] || ""),
      "to_date" => String.trim(params["to_date"] || "")
    }
  end

  defp normalize_select(nil), do: "all"
  defp normalize_select(""), do: "all"
  defp normalize_select(value), do: value

  defp restorable_log?(log) do
    local_archive? = is_binary(log.local_path) and log.local_path != ""
    s3_archive? = is_binary(log.s3_key) and archive_key?(log.s3_key)
    local_archive? or s3_archive?
  end

  defp archive_key?(value) when is_binary(value) do
    String.ends_with?(value, ".tar.gz") or String.ends_with?(value, ".tgz")
  end

  defp archive_key?(_), do: false

  defp log_s3_mode(log) do
    details = log.details || %{}

    cond do
      # Explicit s3_mode recorded by runner
      (mode = Map.get(details, :s3_mode) || Map.get(details, "s3_mode")) != nil ->
        mode

      # mode == "archive" means traditional single-file archive
      (Map.get(details, :mode) || Map.get(details, "mode")) == "archive" ->
        "archive"

      # s3_key ending in .tar.gz is an archive
      is_binary(log.s3_key) and archive_key?(log.s3_key) ->
        "archive"

      # s3_key without .tar.gz suffix is a stream/raw prefix
      is_binary(log.s3_key) and log.s3_key != "" ->
        "stream"

      true ->
        nil
    end
  end

  defp log_first_domain(log) do
    log |> domain_names_from_log() |> List.first()
  end

  defp display_domain_count(log) do
    log
    |> domain_names_from_log()
    |> length()
  end

  defp display_domain_preview(log) do
    log
    |> domain_names_from_log()
    |> Enum.take(4)
    |> Enum.join(", ")
  end

  defp domain_names_from_log(log) do
    details = log.details || %{}
    names = Map.get(details, :domain_names) || Map.get(details, "domain_names") || []

    names
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp database_count(log) do
    details = log.details || %{}
    mysql = Map.get(details, :mysql_databases) || Map.get(details, "mysql_databases") || []

    postgresql =
      Map.get(details, :postgresql_databases) || Map.get(details, "postgresql_databases") || []

    length(mysql) + length(postgresql)
  end

  defp format_bytes(nil), do: "—"

  defp format_bytes(bytes) when bytes >= 1_073_741_824,
    do: "#{Float.round(bytes / 1_073_741_824, 1)} GB"

  defp format_bytes(bytes) when bytes >= 1_048_576,
    do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp format_bytes(bytes) when bytes >= 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes), do: "#{bytes} B"

  defp trigger_label("manual_domain"), do: "Manual Domain"
  defp trigger_label(nil), do: "Manual"
  defp trigger_label(other), do: String.capitalize(other)

  defp s3_mode_label("archive"), do: "S3 Archive"
  defp s3_mode_label("stream"), do: "S3 Stream"
  defp s3_mode_label("raw"), do: "S3 Raw"
  defp s3_mode_label(_), do: "S3"

  defp restore_temp_path(s3_key) do
    basename = s3_key |> Path.basename() |> String.replace(~r/[^a-zA-Z0-9._-]/, "_")
    ts = System.system_time(:millisecond)

    Path.join(
      System.tmp_dir!(),
      "hostctl-s3-restore-#{ts}-#{basename}"
    )
  end

  defp cleanup_restore(nil), do: :ok

  defp cleanup_restore(%{local_path: path}) when is_binary(path) do
    File.rm(path)
    :ok
  end

  defp cleanup_restore(_), do: :ok

  defp s3_archive_basename(key) when is_binary(key), do: Path.basename(key)
  defp s3_archive_basename(_), do: "unknown"

  defp kind_label("panel_postgresql"), do: "Panel DB"
  defp kind_label("mysql"), do: "MySQL"
  defp kind_label("postgresql"), do: "PostgreSQL"
  defp kind_label("domain_files"), do: "Domain files"
  defp kind_label("mail"), do: "Mail"
  defp kind_label(_), do: "Other"

  defp sql_kind?(kind), do: kind in ["panel_postgresql", "mysql", "postgresql"]

  defp import_result_for(import_results, dump_path) do
    Enum.find(import_results, fn r -> r.dump == dump_path end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_tab={@active_tab}>
      <div class="max-w-6xl mx-auto px-4 py-8 space-y-8">
        <div class="flex items-center justify-between gap-4">
          <div>
            <h1 class="text-2xl font-bold text-gray-900 dark:text-white">Completed Backups</h1>
            <p class="mt-1 text-sm text-gray-500 dark:text-gray-400">
              Filter successful backups and jump directly into the restore flow.
            </p>
          </div>
          <div class="flex items-center gap-2">
            <button
              :if={@s3_enabled}
              id="browse-raw-btn"
              phx-click="browse_raw"
              class="inline-flex items-center gap-2 rounded-lg border border-gray-300 bg-white px-4 py-2 text-sm font-medium text-gray-700 hover:bg-gray-50 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-200 dark:hover:bg-gray-700"
            >
              <.icon name="hero-folder-open" class="w-4 h-4" /> Restore Raw
            </button>
            <button
              :if={@s3_enabled}
              id="browse-s3-btn"
              phx-click="load_s3"
              class="inline-flex items-center gap-2 rounded-lg border border-gray-300 bg-white px-4 py-2 text-sm font-medium text-gray-700 hover:bg-gray-50 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-200 dark:hover:bg-gray-700"
            >
              <.icon name="hero-cloud-arrow-down" class="w-4 h-4" /> Browse S3
            </button>
            <.link
              navigate={~p"/panel/backup"}
              class="inline-flex items-center gap-2 rounded-lg bg-indigo-600 px-4 py-2 text-sm font-medium text-white hover:bg-indigo-700"
            >
              <.icon name="hero-arrow-left" class="w-4 h-4" /> Back to Backup
            </.link>
          </div>
        </div>

        <%!-- S3 archives panel --%>
        <%= if @s3_archives != nil or @s3_loading do %>
          <div class="rounded-2xl border border-gray-200 bg-white shadow-sm dark:border-gray-800 dark:bg-gray-900 overflow-hidden">
            <div class="px-6 py-4 border-b border-gray-200 dark:border-gray-800 flex items-center justify-between">
              <div class="flex items-center gap-3">
                <.icon name="hero-cloud" class="w-5 h-5 text-indigo-500" />
                <h2 class="text-base font-semibold text-gray-900 dark:text-white">
                  S3 Archives
                </h2>
              </div>
              <button
                id="close-s3-panel"
                phx-click="close_s3"
                class="inline-flex items-center justify-center rounded-md p-1.5 text-gray-400 hover:text-gray-600 hover:bg-gray-100 dark:hover:bg-gray-800 dark:hover:text-gray-200"
              >
                <.icon name="hero-x-mark" class="w-4 h-4" />
              </button>
            </div>

            <%= if @s3_loading do %>
              <div class="px-6 py-12 text-center">
                <svg
                  class="mx-auto mb-3 w-6 h-6 animate-spin text-indigo-500"
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
                  />
                  <path
                    class="opacity-75"
                    fill="currentColor"
                    d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"
                  />
                </svg>
                <p class="text-sm text-gray-500 dark:text-gray-400">Loading S3 archives…</p>
              </div>
            <% end %>

            <%= if @s3_error do %>
              <div class="px-6 py-6 text-center">
                <p class="text-sm text-red-600 dark:text-red-400">
                  <.icon name="hero-exclamation-triangle" class="w-4 h-4 inline -mt-0.5" />
                  {@s3_error}
                </p>
                <button
                  id="retry-s3-btn"
                  phx-click="load_s3"
                  class="mt-3 text-sm text-indigo-600 hover:text-indigo-700 dark:text-indigo-400 font-medium"
                >
                  Retry
                </button>
              </div>
            <% end %>

            <%= if not @s3_loading and is_list(@s3_archives) do %>
              <div
                :if={@s3_archives == []}
                class="px-6 py-12 text-center text-sm text-gray-400 dark:text-gray-500"
              >
                No archives found in S3 bucket.
              </div>

              <div :if={@s3_archives != []} class="divide-y divide-gray-100 dark:divide-gray-800">
                <%= for archive <- @s3_archives do %>
                  <div
                    id={"s3-archive-#{Base.encode16(:crypto.hash(:md5, archive.key), case: :lower) |> binary_part(0, 8)}"}
                    class="px-6 py-4 flex items-center gap-4 hover:bg-gray-50 dark:hover:bg-gray-800/40 transition-colors"
                  >
                    <div class="flex-1 min-w-0">
                      <p class="text-sm font-medium text-gray-900 dark:text-white truncate">
                        {s3_archive_basename(archive.key)}
                      </p>
                      <p class="text-xs text-gray-400 dark:text-gray-500 truncate mt-0.5">
                        {archive.key}
                      </p>
                      <p
                        :if={archive[:last_modified]}
                        class="text-xs text-gray-400 dark:text-gray-500 mt-0.5"
                      >
                        Modified: {archive.last_modified}
                      </p>
                    </div>
                    <button
                      id={"restore-s3-#{Base.encode16(:crypto.hash(:md5, archive.key), case: :lower) |> binary_part(0, 8)}"}
                      phx-click="restore_s3"
                      phx-value-key={archive.key}
                      class="inline-flex items-center gap-2 rounded-lg bg-emerald-600 px-3 py-2 text-xs font-medium text-white hover:bg-emerald-700 transition-colors"
                    >
                      <.icon name="hero-arrow-path-rounded-square" class="w-4 h-4" /> Restore
                    </button>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        <% end %>

        <div class="rounded-2xl border border-gray-200 bg-white p-6 shadow-sm dark:border-gray-800 dark:bg-gray-900">
          <.form
            for={@filter_form}
            id="completed-backups-filters"
            phx-change="filter"
            class="grid grid-cols-1 gap-4 md:grid-cols-6"
          >
            <.input
              field={@filter_form[:query]}
              type="text"
              label="Search"
              placeholder="domain, archive path, or S3 key"
            />
            <.input
              field={@filter_form[:trigger]}
              type="select"
              label="Trigger"
              options={[
                {"All", "all"},
                {"Manual", "manual"},
                {"Manual Domain", "manual_domain"},
                {"Scheduled", "scheduled"}
              ]}
            />
            <.input
              field={@filter_form[:destination]}
              type="select"
              label="Destination"
              options={[
                {"All", "all"},
                {"Local", "local"},
                {"S3", "s3"},
                {"Both", "both"}
              ]}
            />
            <.input field={@filter_form[:from_date]} type="date" label="From" />
            <.input field={@filter_form[:to_date]} type="date" label="To" />
            <div class="flex items-end">
              <button
                id="reset-completed-backup-filters"
                type="button"
                phx-click="reset_filters"
                class="w-full rounded-lg bg-gray-100 px-4 py-2 text-sm font-medium text-gray-700 hover:bg-gray-200 dark:bg-gray-800 dark:text-gray-300 dark:hover:bg-gray-700"
              >
                Reset Filters
              </button>
            </div>
          </.form>
        </div>

        <div class="rounded-2xl border border-gray-200 bg-white shadow-sm dark:border-gray-800 dark:bg-gray-900 overflow-hidden">
          <div
            :if={@logs == []}
            class="px-6 py-12 text-center text-sm text-gray-400 dark:text-gray-500"
          >
            No completed backups match the current filters.
          </div>

          <div :if={@logs != []} class="divide-y divide-gray-100 dark:divide-gray-800">
            <%= for log <- @logs do %>
              <div id={"completed-log-#{log.id}"} class="px-6 py-5 flex items-start gap-4">
                <div class="flex-1 min-w-0 space-y-2">
                  <div class="flex items-center gap-2 flex-wrap">
                    <span class="text-sm font-semibold text-gray-900 dark:text-white">
                      {if log.completed_at,
                        do: Calendar.strftime(log.completed_at, "%Y-%m-%d %H:%M UTC"),
                        else: "Completed"}
                    </span>
                    <span class="rounded-full bg-emerald-100 px-2 py-0.5 text-xs font-medium text-emerald-700 dark:bg-emerald-900/40 dark:text-emerald-400">
                      {trigger_label(log.trigger)}
                    </span>
                    <span :if={log.destination} class="text-xs text-gray-500 dark:text-gray-400">
                      {log.destination}
                    </span>
                    <%= if log_s3_mode(log) do %>
                      <span class={[
                        "rounded-full px-2 py-0.5 text-xs font-medium",
                        if(log_s3_mode(log) == "raw",
                          do: "bg-amber-100 text-amber-700 dark:bg-amber-900/40 dark:text-amber-400",
                          else: "bg-blue-100 text-blue-700 dark:bg-blue-900/40 dark:text-blue-400"
                        )
                      ]}>
                        {s3_mode_label(log_s3_mode(log))}
                      </span>
                    <% end %>
                  </div>

                  <div class="grid grid-cols-1 gap-2 text-xs text-gray-500 dark:text-gray-400 md:grid-cols-3">
                    <div>Domains: {display_domain_count(log)}</div>
                    <div>Databases: {database_count(log)}</div>
                    <div>Archive Size: {format_bytes(log.file_size_bytes)}</div>
                  </div>

                  <p
                    :if={display_domain_preview(log) != ""}
                    class="text-sm text-gray-700 dark:text-gray-300 truncate"
                  >
                    {display_domain_preview(log)}
                  </p>

                  <p :if={log.local_path} class="text-xs text-gray-400 dark:text-gray-500 truncate">
                    Local: {log.local_path}
                  </p>
                  <p :if={log.s3_key} class="text-xs text-gray-400 dark:text-gray-500 truncate">
                    S3: {log.s3_key}
                  </p>
                </div>

                <div class="shrink-0 flex items-center gap-2">
                  <.link
                    href={~p"/panel/backups/#{log.id}/download"}
                    class="inline-flex items-center gap-2 rounded-lg border border-gray-300 px-3 py-2 text-xs font-medium text-gray-700 hover:bg-gray-50 dark:border-gray-700 dark:text-gray-200 dark:hover:bg-gray-800"
                  >
                    <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> Download
                  </.link>
                  <button
                    :if={restorable_log?(log) and is_binary(log.s3_key) and log.s3_key != ""}
                    id={"restore-log-s3-#{log.id}"}
                    phx-click="restore_s3"
                    phx-value-key={log.s3_key}
                    class="inline-flex items-center gap-2 rounded-lg bg-emerald-600 px-3 py-2 text-xs font-medium text-white hover:bg-emerald-700"
                  >
                    <.icon name="hero-arrow-path-rounded-square" class="w-4 h-4" /> Restore
                  </button>
                  <button
                    :if={log_s3_mode(log) == "raw" and log_first_domain(log)}
                    id={"restore-raw-log-#{log.id}"}
                    phx-click="restore_raw_log"
                    phx-value-id={log.id}
                    class="inline-flex items-center gap-2 rounded-lg bg-amber-600 px-3 py-2 text-xs font-medium text-white hover:bg-amber-700"
                  >
                    <.icon name="hero-folder-open" class="w-4 h-4" /> Restore Raw
                  </button>
                  <button
                    :if={log_s3_mode(log) == "stream" and log_first_domain(log)}
                    id={"restore-stream-log-#{log.id}"}
                    phx-click="restore_stream_log"
                    phx-value-id={log.id}
                    class="inline-flex items-center gap-2 rounded-lg bg-emerald-600 px-3 py-2 text-xs font-medium text-white hover:bg-emerald-700"
                  >
                    <.icon name="hero-arrow-path-rounded-square" class="w-4 h-4" /> Restore
                  </button>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      </div>

      <%!-- Restore modal --%>
      <%= if @restore do %>
        <div class="fixed inset-0 z-50 flex items-center justify-center p-4">
          <div class="absolute inset-0 bg-black/50" phx-click="close_restore"></div>
          <div class="relative w-full max-w-3xl max-h-[85vh] flex flex-col bg-white dark:bg-gray-900 rounded-2xl shadow-xl border border-gray-200 dark:border-gray-800 overflow-hidden">
            <%!-- Modal header --%>
            <div class="px-6 py-4 border-b border-gray-200 dark:border-gray-800 flex items-center justify-between shrink-0">
              <div>
                <h3 class="text-sm font-semibold text-gray-900 dark:text-white">
                  Restore from S3
                </h3>
                <p class="text-xs text-gray-500 dark:text-gray-400 mt-0.5 truncate max-w-lg">
                  {s3_archive_basename(@restore.s3_key)}
                </p>
              </div>
              <button
                id="close-restore-modal"
                phx-click="close_restore"
                class="inline-flex items-center justify-center rounded-md p-1.5 text-gray-400 hover:text-gray-600 hover:bg-gray-100 dark:hover:bg-gray-800 dark:hover:text-gray-200"
              >
                <.icon name="hero-x-mark" class="w-4 h-4" />
              </button>
            </div>

            <%!-- Modal body --%>
            <div class="flex-1 overflow-y-auto px-6 py-5 space-y-5">
              <%!-- Step: downloading --%>
              <%= if @restore.step == :downloading do %>
                <div class="text-center py-12">
                  <svg
                    class="mx-auto mb-3 w-8 h-8 animate-spin text-indigo-500"
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
                    />
                    <path
                      class="opacity-75"
                      fill="currentColor"
                      d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"
                    />
                  </svg>
                  <p class="text-sm font-medium text-gray-700 dark:text-gray-300">
                    Downloading archive from S3…
                  </p>
                  <p class="text-xs text-gray-400 dark:text-gray-500 mt-1">
                    This may take a while for large backups.
                  </p>
                </div>
              <% end %>

              <%!-- Step: error --%>
              <%= if @restore.step == :error do %>
                <div class="text-center py-8">
                  <div class="inline-flex items-center justify-center w-12 h-12 rounded-full bg-red-100 dark:bg-red-900/30 mb-3">
                    <.icon
                      name="hero-exclamation-triangle"
                      class="w-6 h-6 text-red-600 dark:text-red-400"
                    />
                  </div>
                  <p class="text-sm font-medium text-red-700 dark:text-red-400">
                    {@restore.error}
                  </p>
                </div>
              <% end %>

              <%!-- Step: select items from archive --%>
              <%= if @restore.step == :select_items do %>
                <div>
                  <p class="text-sm text-gray-600 dark:text-gray-400 mb-4">
                    Select which items to extract and restore:
                  </p>
                  <div class="rounded-xl border border-gray-200 dark:border-gray-800 divide-y divide-gray-100 dark:divide-gray-800 overflow-hidden">
                    <%= if @restore.items == [] do %>
                      <div class="px-4 py-8 text-center text-sm text-gray-400 dark:text-gray-500">
                        No restorable items found in this archive.
                      </div>
                    <% end %>
                    <%= for item <- @restore.items do %>
                      <label class="flex items-center gap-3 px-4 py-3 cursor-pointer hover:bg-gray-50 dark:hover:bg-gray-800/40 transition-colors">
                        <input
                          type="checkbox"
                          checked={MapSet.member?(@restore.selected_items, item.id)}
                          phx-click="toggle_restore_item"
                          phx-value-item-id={item.id}
                          class="w-4 h-4 rounded border-gray-300 text-indigo-600 focus:ring-indigo-500"
                        />
                        <div class="flex-1 min-w-0">
                          <p class="text-sm font-medium text-gray-800 dark:text-gray-200 truncate">
                            {item.label}
                          </p>
                          <p class="text-xs text-gray-400 dark:text-gray-500 font-mono truncate">
                            {item.path}
                          </p>
                        </div>
                        <span class="shrink-0 rounded-full px-2 py-0.5 text-xs font-medium bg-gray-100 text-gray-600 dark:bg-gray-800 dark:text-gray-400">
                          {kind_label(item.kind)}
                        </span>
                        <span
                          :if={item.bytes}
                          class="shrink-0 text-xs text-gray-400 dark:text-gray-500"
                        >
                          {format_bytes(item.bytes)}
                        </span>
                      </label>
                    <% end %>
                  </div>
                </div>
              <% end %>

              <%!-- Step: review & import SQL dumps --%>
              <%= if @restore.step == :review_dumps do %>
                <div>
                  <%= if @restore.sql_dumps == [] do %>
                    <div class="text-center py-8">
                      <p class="text-sm text-gray-500 dark:text-gray-400">
                        No SQL dumps found in the extracted archive. File-based items have been
                        extracted to:
                      </p>
                      <p class="mt-2 text-xs text-gray-400 dark:text-gray-500 font-mono">
                        {@restore.extracted_dir}
                      </p>
                    </div>
                  <% else %>
                    <p class="text-sm text-gray-600 dark:text-gray-400 mb-4">
                      Select a target database and import each SQL dump:
                    </p>
                    <div class="space-y-3">
                      <%= for dump <- @restore.sql_dumps do %>
                        <div
                          id={"sql-dump-#{Base.encode16(:crypto.hash(:md5, dump.full_path), case: :lower) |> binary_part(0, 8)}"}
                          class="rounded-xl border border-gray-200 dark:border-gray-800 p-4 space-y-3"
                        >
                          <div class="flex items-center gap-3">
                            <div class="flex-1 min-w-0">
                              <p class="text-sm font-medium text-gray-800 dark:text-gray-200 truncate">
                                {dump.label}
                              </p>
                              <p class="text-xs text-gray-400 dark:text-gray-500 font-mono truncate">
                                {dump.rel_path}
                              </p>
                            </div>
                            <span class="rounded-full px-2 py-0.5 text-xs font-medium bg-gray-100 text-gray-600 dark:bg-gray-800 dark:text-gray-400">
                              {kind_label(dump.kind)}
                            </span>
                          </div>

                          <%= if sql_kind?(dump.kind) do %>
                            <% result = import_result_for(@restore.import_results, dump.full_path) %>
                            <%= if result do %>
                              <div class={[
                                "rounded-lg px-3 py-2 text-xs font-medium",
                                if(result.status == :ok,
                                  do:
                                    "bg-emerald-50 text-emerald-700 dark:bg-emerald-900/30 dark:text-emerald-400",
                                  else: "bg-red-50 text-red-700 dark:bg-red-900/30 dark:text-red-400"
                                )
                              ]}>
                                <%= if result.status == :ok do %>
                                  <.icon name="hero-check-circle" class="w-3.5 h-3.5 inline -mt-0.5" />
                                <% else %>
                                  <.icon name="hero-x-circle" class="w-3.5 h-3.5 inline -mt-0.5" />
                                <% end %>
                                {result.message}
                              </div>
                            <% else %>
                              <form
                                id={"import-form-#{Base.encode16(:crypto.hash(:md5, dump.full_path), case: :lower) |> binary_part(0, 8)}"}
                                phx-submit="import_sql"
                                class="flex items-end gap-3"
                              >
                                <input type="hidden" name="dump_path" value={dump.full_path} />
                                <input type="hidden" name="kind" value={dump.kind} />
                                <%= if dump.kind == "panel_postgresql" do %>
                                  <input type="hidden" name="target_db" value="" />
                                  <p class="text-xs text-gray-500 dark:text-gray-400 flex-1">
                                    Imports into the panel PostgreSQL database.
                                  </p>
                                <% else %>
                                  <div class="flex-1">
                                    <label class="block text-xs font-medium text-gray-600 dark:text-gray-400 mb-1">
                                      Target database
                                    </label>
                                    <select
                                      name="target_db"
                                      class="w-full rounded-lg border border-gray-300 bg-white px-3 py-1.5 text-sm text-gray-800 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-200 focus:border-indigo-500 focus:ring-1 focus:ring-indigo-500"
                                    >
                                      <option value="">Select…</option>
                                      <%= if dump.kind == "mysql" do %>
                                        <%= for db <- @restore.db_targets.mysql do %>
                                          <option value={db}>{db}</option>
                                        <% end %>
                                      <% else %>
                                        <%= for db <- @restore.db_targets.postgresql do %>
                                          <option value={db}>{db}</option>
                                        <% end %>
                                      <% end %>
                                    </select>
                                  </div>
                                <% end %>
                                <button
                                  type="submit"
                                  data-confirm="This will import the SQL dump into the selected database. Are you sure?"
                                  class="shrink-0 inline-flex items-center gap-1.5 rounded-lg bg-indigo-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-indigo-700"
                                >
                                  <.icon name="hero-arrow-down-on-square" class="w-3.5 h-3.5" />
                                  Import
                                </button>
                              </form>
                            <% end %>
                          <% else %>
                            <p class="text-xs text-gray-400 dark:text-gray-500">
                              Non-SQL item extracted to: {dump.full_path}
                            </p>
                          <% end %>
                        </div>
                      <% end %>
                    </div>

                    <div
                      :if={@restore.extracted_dir}
                      class="mt-4 rounded-lg bg-gray-50 dark:bg-gray-800/50 px-4 py-3"
                    >
                      <p class="text-xs text-gray-500 dark:text-gray-400">
                        Extracted files staged at:
                        <code class="font-mono">{@restore.extracted_dir}</code>
                      </p>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>

            <%!-- Modal footer --%>
            <div class="px-6 py-3 border-t border-gray-200 dark:border-gray-800 flex items-center justify-between shrink-0">
              <div>
                <button
                  :if={@restore.step == :review_dumps}
                  id="restore-back-btn"
                  phx-click="restore_back_to_items"
                  class="inline-flex items-center gap-1.5 rounded-lg px-3 py-1.5 text-sm font-medium text-gray-600 hover:text-gray-800 hover:bg-gray-100 dark:text-gray-400 dark:hover:text-gray-200 dark:hover:bg-gray-800"
                >
                  <.icon name="hero-arrow-left" class="w-3.5 h-3.5" /> Back
                </button>
              </div>
              <div class="flex items-center gap-2">
                <button
                  id="close-restore-btn"
                  phx-click="close_restore"
                  class="px-3 py-1.5 rounded-lg text-sm bg-gray-100 text-gray-600 hover:bg-gray-200 dark:bg-gray-800 dark:text-gray-300"
                >
                  Close
                </button>
                <button
                  :if={@restore.step == :select_items and @restore.items != []}
                  id="extract-selected-btn"
                  phx-click="extract_selected"
                  disabled={MapSet.size(@restore.selected_items) == 0}
                  class={[
                    "px-4 py-1.5 rounded-lg text-sm font-medium transition-colors",
                    if(MapSet.size(@restore.selected_items) == 0,
                      do:
                        "bg-gray-200 text-gray-400 cursor-not-allowed dark:bg-gray-700 dark:text-gray-500",
                      else: "bg-emerald-600 text-white hover:bg-emerald-700"
                    )
                  ]}
                >
                  Extract Selected
                </button>
              </div>
            </div>
          </div>
        </div>
      <% end %>
      <%!-- Raw restore modal --%>
      <%= if @raw_restore do %>
        <div class="fixed inset-0 z-50 flex items-center justify-center p-4">
          <div class="absolute inset-0 bg-black/50" phx-click="close_raw_restore"></div>
          <div class="relative w-full max-w-2xl max-h-[85vh] flex flex-col bg-white dark:bg-gray-900 rounded-2xl shadow-xl border border-gray-200 dark:border-gray-800 overflow-hidden">
            <%!-- Modal header --%>
            <div class="px-6 py-4 border-b border-gray-200 dark:border-gray-800 flex items-center justify-between shrink-0">
              <div>
                <h3 class="text-sm font-semibold text-gray-900 dark:text-white">
                  Restore Raw Backup
                </h3>
                <p class="text-xs text-gray-500 dark:text-gray-400 mt-0.5">
                  <%= cond do %>
                    <% @raw_restore.step in [:loading_domains, :select_domain] -> %>
                      Select a domain to restore
                    <% @raw_restore.step in [:loading_files, :preview_files] -> %>
                      {@raw_restore.selected_domain}
                    <% @raw_restore.step == :restoring -> %>
                      Restoring {@raw_restore.selected_domain}…
                    <% @raw_restore.step == :done -> %>
                      Restore complete
                    <% @raw_restore.step == :error -> %>
                      Restore error
                    <% true -> %>
                      Raw file restore
                  <% end %>
                </p>
              </div>
              <button
                id="close-raw-restore-modal"
                phx-click="close_raw_restore"
                class="inline-flex items-center justify-center rounded-md p-1.5 text-gray-400 hover:text-gray-600 hover:bg-gray-100 dark:hover:bg-gray-800 dark:hover:text-gray-200"
              >
                <.icon name="hero-x-mark" class="w-4 h-4" />
              </button>
            </div>

            <%!-- Modal body --%>
            <div class="flex-1 overflow-y-auto px-6 py-5 space-y-5">
              <%!-- Loading spinner --%>
              <%= if @raw_restore.step in [:loading_domains, :loading_files, :restoring] do %>
                <div class="text-center py-12">
                  <svg
                    class="mx-auto mb-3 w-8 h-8 animate-spin text-indigo-500"
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
                    />
                    <path
                      class="opacity-75"
                      fill="currentColor"
                      d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"
                    />
                  </svg>
                  <p class="text-sm font-medium text-gray-700 dark:text-gray-300">
                    <%= cond do %>
                      <% @raw_restore.step == :loading_domains -> %>
                        Loading domains from S3…
                      <% @raw_restore.step == :loading_files -> %>
                        Loading files for {@raw_restore.selected_domain}…
                      <% @raw_restore.step == :restoring -> %>
                        Restoring files to {@raw_restore.target_dir}…
                      <% true -> %>
                        Loading…
                    <% end %>
                  </p>
                </div>
              <% end %>

              <%!-- Error state --%>
              <%= if @raw_restore.step == :error do %>
                <div class="text-center py-8">
                  <div class="inline-flex items-center justify-center w-12 h-12 rounded-full bg-red-100 dark:bg-red-900/30 mb-3">
                    <.icon
                      name="hero-exclamation-triangle"
                      class="w-6 h-6 text-red-600 dark:text-red-400"
                    />
                  </div>
                  <p class="text-sm font-medium text-red-700 dark:text-red-400">
                    {@raw_restore.error}
                  </p>
                </div>
              <% end %>

              <%!-- Domain selection --%>
              <%= if @raw_restore.step == :select_domain do %>
                <%= if @raw_restore.domains == [] do %>
                  <div class="text-center py-8 text-sm text-gray-400 dark:text-gray-500">
                    No raw domain backups found in S3.
                  </div>
                <% else %>
                  <div class="rounded-xl border border-gray-200 dark:border-gray-800 divide-y divide-gray-100 dark:divide-gray-800 overflow-hidden">
                    <%= for domain <- @raw_restore.domains do %>
                      <button
                        id={"raw-domain-#{domain}"}
                        phx-click="raw_select_domain"
                        phx-value-domain={domain}
                        class="w-full px-4 py-3 flex items-center gap-3 text-left hover:bg-gray-50 dark:hover:bg-gray-800/40 transition-colors"
                      >
                        <.icon
                          name="hero-globe-alt"
                          class="w-5 h-5 text-indigo-500 shrink-0"
                        />
                        <span class="text-sm font-medium text-gray-800 dark:text-gray-200 truncate">
                          {domain}
                        </span>
                        <.icon
                          name="hero-chevron-right"
                          class="w-4 h-4 text-gray-400 ml-auto shrink-0"
                        />
                      </button>
                    <% end %>
                  </div>
                <% end %>
              <% end %>

              <%!-- File preview & target dir --%>
              <%= if @raw_restore.step == :preview_files do %>
                <div class="space-y-4">
                  <div class="flex items-center gap-4 text-sm text-gray-600 dark:text-gray-400">
                    <div class="flex items-center gap-1.5">
                      <.icon name="hero-document" class="w-4 h-4" />
                      <span>{@raw_restore.file_count} files</span>
                    </div>
                    <div class="flex items-center gap-1.5">
                      <.icon name="hero-circle-stack" class="w-4 h-4" />
                      <span>{format_bytes(@raw_restore.total_size)}</span>
                    </div>
                  </div>

                  <div class="rounded-xl border border-gray-200 dark:border-gray-800 overflow-hidden">
                    <div class="max-h-48 overflow-y-auto divide-y divide-gray-100 dark:divide-gray-800">
                      <%= for file <- @raw_restore.files do %>
                        <div class="px-4 py-2 flex items-center gap-3 text-xs">
                          <.icon
                            name="hero-document-text"
                            class="w-3.5 h-3.5 text-gray-400 shrink-0"
                          />
                          <span class="text-gray-700 dark:text-gray-300 truncate flex-1 font-mono">
                            {file.rel_path}
                          </span>
                          <span
                            :if={file[:size]}
                            class="text-gray-400 dark:text-gray-500 shrink-0"
                          >
                            {format_bytes(file[:size])}
                          </span>
                        </div>
                      <% end %>
                    </div>
                    <div
                      :if={@raw_restore.file_count > 100}
                      class="px-4 py-2 text-xs text-gray-400 dark:text-gray-500 bg-gray-50 dark:bg-gray-800/50 border-t border-gray-100 dark:border-gray-800"
                    >
                      Showing 100 of {@raw_restore.file_count} files
                    </div>
                  </div>

                  <div>
                    <label class="block text-xs font-medium text-gray-600 dark:text-gray-400 mb-1.5">
                      Restore destination
                    </label>
                    <form id="raw-restore-form" phx-submit="raw_start_restore" class="flex gap-2">
                      <input type="hidden" name="domain" value={@raw_restore.selected_domain} />
                      <input
                        type="text"
                        name="target_dir"
                        value={@raw_restore.target_dir || ""}
                        placeholder="/home/user/domains/example.com/public_html"
                        class="flex-1 rounded-lg border border-gray-300 bg-white px-3 py-2 text-sm text-gray-800 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-200 focus:border-indigo-500 focus:ring-1 focus:ring-indigo-500 font-mono"
                      />
                      <button
                        type="submit"
                        data-confirm="This will download and write all files to the specified directory. Existing files will be overwritten. Continue?"
                        class="shrink-0 inline-flex items-center gap-2 rounded-lg bg-emerald-600 px-4 py-2 text-sm font-medium text-white hover:bg-emerald-700 transition-colors"
                      >
                        <.icon name="hero-arrow-down-on-square" class="w-4 h-4" /> Restore
                      </button>
                    </form>
                    <p class="mt-1.5 text-xs text-gray-400 dark:text-gray-500">
                      Files will be restored preserving their original directory structure.
                    </p>
                  </div>
                </div>
              <% end %>

              <%!-- Done state --%>
              <%= if @raw_restore.step == :done do %>
                <div class="text-center py-8">
                  <div class="inline-flex items-center justify-center w-12 h-12 rounded-full bg-emerald-100 dark:bg-emerald-900/30 mb-3">
                    <.icon
                      name="hero-check-circle"
                      class="w-6 h-6 text-emerald-600 dark:text-emerald-400"
                    />
                  </div>
                  <p class="text-sm font-medium text-emerald-700 dark:text-emerald-400">
                    {@raw_restore.progress}
                  </p>
                </div>
              <% end %>
            </div>

            <%!-- Modal footer --%>
            <div class="px-6 py-3 border-t border-gray-200 dark:border-gray-800 flex items-center justify-between shrink-0">
              <div>
                <button
                  :if={@raw_restore.step == :preview_files}
                  id="raw-back-btn"
                  phx-click="raw_back_to_domains"
                  class="inline-flex items-center gap-1.5 rounded-lg px-3 py-1.5 text-sm font-medium text-gray-600 hover:text-gray-800 hover:bg-gray-100 dark:text-gray-400 dark:hover:text-gray-200 dark:hover:bg-gray-800"
                >
                  <.icon name="hero-arrow-left" class="w-3.5 h-3.5" /> Back
                </button>
              </div>
              <button
                id="close-raw-restore-btn"
                phx-click="close_raw_restore"
                class="px-3 py-1.5 rounded-lg text-sm bg-gray-100 text-gray-600 hover:bg-gray-200 dark:bg-gray-800 dark:text-gray-300"
              >
                Close
              </button>
            </div>
          </div>
        </div>
      <% end %>
    </Layouts.app>
    """
  end
end
