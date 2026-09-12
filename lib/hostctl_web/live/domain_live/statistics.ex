defmodule HostctlWeb.DomainLive.Statistics do
  use HostctlWeb, :live_view
  alias Hostctl.Statistics

  def mount(%{"id" => id}, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Domain statistics")
     |> assign(:active_tab, :domains)
     |> assign(:busy, false)
     |> assign(:kind, "live")
     |> assign(:error, nil)
     |> stream(:history_reports, [])
     |> load_snapshot(id)}
  end

  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:kind, if(params["kind"] == "history", do: "history", else: "live"))
     |> load_snapshot(socket.assigns.snapshot.domain.id)}
  end

  def handle_event("refresh", _, socket) do
    scope = socket.assigns.current_scope
    id = socket.assigns.snapshot.domain.id

    {:noreply,
     socket
     |> assign(busy: true, error: nil)
     |> start_async(:collect, fn -> Statistics.refresh(scope, id) end)}
  end

  def handle_async(:collect, {:ok, {:ok, _}}, socket) do
    {:noreply, socket |> assign(:busy, false) |> load_snapshot(socket.assigns.snapshot.domain.id)}
  end

  def handle_async(:collect, {:ok, {:error, reason}}, socket) do
    {:noreply, assign(socket, busy: false, error: reason)}
  end

  def handle_async(:collect, {:exit, _}, socket) do
    {:noreply,
     assign(socket,
       busy: false,
       error: "Collection was interrupted. The previous report remains available."
     )}
  end

  defp load_snapshot(socket, id) do
    snapshot = Statistics.snapshot(socket.assigns.current_scope, id)
    reports = if snapshot.history, do: snapshot.history["reports"] || [], else: []

    socket
    |> assign(:snapshot, snapshot)
    |> stream(:history_reports, Enum.map(reports, &Map.put(&1, :id, &1["id"])), reset: true)
  end

  defp metric(summary, "bandwidth") do
    case summary["bandwidth"] do
      bytes when is_number(bytes) and bytes >= 0 ->
        {unit, size} =
          Enum.find(
            [
              {"TiB", 1_099_511_627_776},
              {"GiB", 1_073_741_824},
              {"MiB", 1_048_576},
              {"KiB", 1024},
              {"B", 1}
            ],
            fn {_unit, size} -> bytes >= size end
          ) || {"B", 1}

        "#{Float.round(bytes / size, 1)} #{unit}"

      _ ->
        "Unavailable"
    end
  end

  defp metric(summary, key), do: Map.get(summary, key, "Unavailable")

  def render(assigns) do
    data = if assigns.kind == "history", do: assigns.snapshot.history, else: assigns.snapshot.live
    assigns = assign(assigns, :data, data)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_tab={@active_tab}>
      <div id="domain-statistics" class="mx-auto max-w-7xl space-y-6">
        <.link
          navigate={~p"/domains/#{@snapshot.domain.id}"}
          class="text-sm text-indigo-600 hover:underline dark:text-indigo-300"
        >
          ← {@snapshot.domain.name}
        </.link>
        <div class="flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold tracking-tight">Traffic statistics</h1>
            <p class="mt-1 text-sm text-gray-500">
              Explore visits, requested pages, downloads, and referring sites.
            </p>
          </div>
          <button
            id="refresh-statistics"
            phx-click="refresh"
            disabled={@busy or not @snapshot.available?}
            class="rounded-xl bg-indigo-600 px-4 py-2.5 text-sm font-medium text-white transition-colors hover:bg-indigo-500 disabled:opacity-50"
          >
            {cond do
              @busy -> "Collecting…"
              @snapshot.live -> "Refresh traffic"
              true -> "Start collecting"
            end}
          </button>
        </div>
        <div
          :if={not @snapshot.available?}
          id="statistics-install"
          class="rounded-xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-900"
        >
          GoAccess is needed to collect traffic.
          <.link
            :if={@current_scope.user.role == "admin"}
            navigate={~p"/panel/features"}
            class="font-medium underline"
          >
            Install Domain Statistics in Features.
          </.link>
          <span :if={@current_scope.user.role != "admin"}>
            Ask your server administrator to enable Domain Statistics.
          </span>
        </div>
        <p
          :if={@error}
          id="statistics-error"
          role="alert"
          class="rounded-xl bg-red-50 p-4 text-sm text-red-700"
        >
          {@error}
        </p>
        <nav
          class="flex gap-2 border-b border-gray-200 pb-3 dark:border-gray-800"
          aria-label="Statistics source"
        >
          <.link
            id="statistics-live"
            patch={~p"/domains/#{@snapshot.domain.id}/statistics"}
            class={[
              "rounded-lg px-4 py-2 text-sm",
              @kind == "live" &&
                "bg-indigo-50 text-indigo-700 dark:bg-indigo-950 dark:text-indigo-300"
            ]}
          >
            Hostctl traffic
          </.link>
          <.link
            id="statistics-history"
            patch={~p"/domains/#{@snapshot.domain.id}/statistics?kind=history"}
            class={[
              "rounded-lg px-4 py-2 text-sm",
              @kind == "history" &&
                "bg-indigo-50 text-indigo-700 dark:bg-indigo-950 dark:text-indigo-300"
            ]}
          >
            Plesk history
          </.link>
        </nav>
        <%= if @data do %>
          <div class="flex flex-wrap justify-between gap-3 text-xs text-gray-500">
            <span id="statistics-updated">
              Updated {DateTime.from_unix!(@data["updated_at"])
              |> Calendar.strftime("%b %d, %Y at %H:%M UTC")}
            </span>
            <span :if={@kind == "live"}>Refreshes hourly after collection is enabled.</span>
            <span :if={@kind == "history"}>Imported history is kept separate from new traffic.</span>
          </div>
          <p :if={@data["warning"]} class="rounded-lg bg-amber-50 p-3 text-sm text-amber-900">
            {@data["warning"]}
          </p>
          <%= if @data["summary"] do %>
            <div class="grid gap-4 sm:grid-cols-3">
              <div
                :for={
                  {label, key} <- [
                    {"Requests", "valid_requests"},
                    {"Estimated visitors", "unique_visitors"},
                    {"Transferred", "bandwidth"}
                  ]
                }
                class="rounded-xl border border-gray-200 p-5 dark:border-gray-800"
              >
                <p class="text-xs text-gray-500">{label}</p>
                <p class="mt-2 text-2xl font-semibold tabular-nums">
                  {metric(@data["summary"], key)}
                </p>
              </div>
            </div>
            <iframe
              id="statistics-report"
              title="GoAccess traffic report"
              sandbox="allow-scripts"
              referrerpolicy="no-referrer"
              src={
                ~p"/domains/#{@snapshot.domain.id}/statistics/report/#{@kind}?v=#{@data["updated_at"]}"
              }
              class="h-[850px] w-full rounded-xl border border-gray-200 bg-white dark:border-gray-800"
            >
            </iframe>
          <% end %>
        <% else %>
          <div
            id="statistics-empty"
            class="rounded-xl border border-dashed border-gray-300 p-10 text-center dark:border-gray-700"
          >
            <.icon name="hero-chart-bar" class="mx-auto h-10 w-10 text-gray-400" />
            <p class="mt-4 font-medium">
              {if @kind == "history",
                do: "No Plesk history imported yet",
                else: "Start collecting this domain’s traffic"}
            </p>
            <p class="mt-2 text-sm text-gray-500">
              {if @kind == "history",
                do:
                  "Select Statistics history in a Plesk SSH import, or import an extracted history directory with the shell command.",
                else: "The first report reads the current and most recently rotated access logs."}
            </p>
          </div>
        <% end %>
        <section :if={@kind == "history"} class="space-y-3">
          <h2 class="text-lg font-semibold">Archived Plesk reports</h2>
          <div id="statistics-history-reports" phx-update="stream" class="grid gap-3 sm:grid-cols-2">
            <.link
              :for={{id, report} <- @streams.history_reports}
              id={id}
              href={
                ~p"/domains/#{@snapshot.domain.id}/statistics/report/history?archive=#{report["id"]}"
              }
              target="_blank"
              rel="noopener noreferrer"
              class="rounded-xl border border-gray-200 p-4 text-sm text-indigo-600 transition-colors hover:bg-indigo-50 dark:border-gray-800 dark:hover:bg-gray-900"
            >
              <.icon name="hero-document-chart-bar" class="mr-2 inline h-5 w-5" />{report["name"]}
            </.link>
          </div>
        </section>
        <p class="text-xs leading-relaxed text-gray-500">
          Log-based visitors are estimates and include bots. Referrers may be missing. Countries require a configured GeoIP database and accurate client IP logs.
          CDN cache hits never reaching this server are absent. Collection gaps can occur if access logs rotate away while collection is stopped.
        </p>
      </div>
    </Layouts.app>
    """
  end
end
