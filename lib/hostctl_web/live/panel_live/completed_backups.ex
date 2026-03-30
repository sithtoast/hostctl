defmodule HostctlWeb.PanelLive.CompletedBackups do
  use HostctlWeb, :live_view

  alias Hostctl.Backup

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

    {:ok,
     socket
     |> assign(:page_title, "Completed Backups")
     |> assign(:active_tab, :panel_completed_backups)
     |> assign(:filters, filters)
     |> assign(:filter_form, to_form(filters, as: :filters))
     |> assign(:logs, logs)}
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

  @impl true
  def handle_event("reset_filters", _, socket) do
    filters = @default_filters

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:filter_form, to_form(filters, as: :filters))
     |> assign(:logs, Backup.list_completed_logs(filters))}
  end

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
          <.link
            navigate={~p"/panel/backup"}
            class="inline-flex items-center gap-2 rounded-lg bg-indigo-600 px-4 py-2 text-sm font-medium text-white hover:bg-indigo-700"
          >
            <.icon name="hero-arrow-left" class="w-4 h-4" /> Back to Backup
          </.link>
        </div>

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
                    :if={restorable_log?(log)}
                    navigate={~p"/panel/backup?restore_log_id=#{log.id}"}
                    class="inline-flex items-center gap-2 rounded-lg bg-emerald-600 px-3 py-2 text-xs font-medium text-white hover:bg-emerald-700"
                  >
                    <.icon name="hero-arrow-path-rounded-square" class="w-4 h-4" /> Restore
                  </.link>
                  <span
                    :if={not restorable_log?(log)}
                    class="text-xs text-gray-400 dark:text-gray-500"
                  >
                    Restore unavailable
                  </span>
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
