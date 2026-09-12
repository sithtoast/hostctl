defmodule HostctlWeb.PanelLive.Resources do
  use HostctlWeb, :live_view
  alias Hostctl.Resources

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        page_title: "Account resources",
        active_tab: :panel_resources,
        form: to_form(%{"query" => ""}, as: :search),
        query: "",
        loading: false,
        error: nil,
        sampled_at: nil,
        total: 0,
        attributed: 0,
        matching: 0,
        limit: 500
      )
      |> stream(:processes, [])

    {:ok, if(connected?(socket), do: load(socket), else: socket)}
  end

  def handle_event("refresh", _, socket), do: {:noreply, load(socket)}

  def handle_event("search", %{"search" => %{"query" => query}}, socket) do
    query = String.slice(query, 0, 120)

    {:noreply,
     socket
     |> assign(query: query, form: to_form(%{"query" => query}, as: :search))
     |> load()}
  end

  def handle_async(:processes, {:ok, {:ok, result}}, socket) do
    {:noreply,
     socket
     |> assign(Map.drop(result, [:processes]))
     |> assign(loading: false, error: nil)
     |> stream(:processes, result.processes, reset: true)}
  end

  def handle_async(:processes, {:ok, {:error, reason}}, socket), do: failed(socket, reason)
  def handle_async(:processes, {:exit, _}, socket), do: failed(socket, :process_access_failed)

  defp load(socket) do
    scope = socket.assigns.current_scope
    query = socket.assigns.query

    socket
    |> assign(loading: true, error: nil)
    |> start_async(:processes, fn -> Resources.snapshot(scope, query) end)
  end

  defp failed(socket, reason) do
    message =
      case reason do
        :linux_required -> "Live process metrics are available on the Linux server."
        :forbidden -> "Administrator access is required."
        _ -> "Process metrics could not be read. Check server process visibility and try again."
      end

    {:noreply,
     socket
     |> assign(
       loading: false,
       error: message,
       sampled_at: nil,
       total: 0,
       attributed: 0,
       matching: 0
     )
     |> stream(:processes, [], reset: true)}
  end

  defp owner_label(%{user_id: nil} = owner), do: "Retained account ##{owner.original_user_id}"
  defp owner_label(owner), do: owner.name || owner.email || "Account ##{owner.original_user_id}"
  defp memory(kb), do: :erlang.float_to_binary(kb / 1024, decimals: 1) <> " MiB"
  defp cpu(value), do: :erlang.float_to_binary(value / 1, decimals: 1) <> "%"

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_tab={@active_tab}
      update_status={assigns[:update_status]}
    >
      <div id="account-resources" class="space-y-6">
        <div class="flex flex-wrap items-start justify-between gap-4">
          <div>
            <div class="mb-2 flex items-center gap-2 text-xs font-medium uppercase tracking-wider text-indigo-600 dark:text-indigo-400">
              <.icon name="hero-cpu-chip" class="size-4" /> System & access
            </div>
            <h1 class="text-2xl font-semibold text-gray-900 dark:text-white">Account resources</h1>
            <p class="mt-2 max-w-2xl text-sm text-gray-500 dark:text-gray-400">
              Trace a busy process to the account and websites it belongs to.
            </p>
          </div>
          <button
            id="resources-refresh"
            phx-click="refresh"
            disabled={@loading}
            class="inline-flex items-center gap-2 rounded-lg border border-gray-200 bg-white px-4 py-2.5 text-sm font-medium text-gray-700 shadow-sm transition hover:bg-gray-50 disabled:opacity-50 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-200 dark:hover:bg-gray-700"
          >
            <.icon name="hero-arrow-path" class={["size-4", @loading && "animate-spin"]} />
            {if @loading, do: "Reading processes…", else: "Refresh snapshot"}
          </button>
        </div>

        <div class="grid gap-4 sm:grid-cols-3">
          <div class="rounded-xl border border-gray-200 bg-white p-5 dark:border-gray-800 dark:bg-gray-900">
            <p class="text-xs font-medium uppercase tracking-wide text-gray-500">Visible processes</p>
            <p id="resources-total" class="mt-2 text-3xl font-semibold tabular-nums">
              {if @sampled_at, do: @total, else: "—"}
            </p>
          </div>
          <div class="rounded-xl border border-indigo-200 bg-indigo-50/60 p-5 dark:border-indigo-900 dark:bg-indigo-950/20">
            <p class="text-xs font-medium uppercase tracking-wide text-indigo-600 dark:text-indigo-400">
              Attributed to accounts
            </p>
            <p id="resources-attributed" class="mt-2 text-3xl font-semibold tabular-nums">
              {if @sampled_at, do: @attributed, else: "—"}
            </p>
          </div>
          <div class="rounded-xl border border-gray-200 bg-white p-5 dark:border-gray-800 dark:bg-gray-900">
            <p class="text-xs font-medium uppercase tracking-wide text-gray-500">Snapshot time</p>
            <p id="resources-timestamp" class="mt-3 text-lg font-medium tabular-nums">
              {if @sampled_at, do: Calendar.strftime(@sampled_at, "%H:%M:%S UTC"), else: "Not sampled"}
            </p>
          </div>
        </div>

        <div
          :if={@error}
          id="resources-error"
          role="alert"
          class="rounded-xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-900 dark:border-amber-900 dark:bg-amber-950/30 dark:text-amber-200"
        >
          {@error}
        </div>

        <section
          class="overflow-hidden rounded-xl border border-gray-200 bg-white dark:border-gray-800 dark:bg-gray-900"
          aria-label="Process ownership"
        >
          <div class="flex flex-wrap items-center justify-between gap-3 border-b border-gray-100 p-4 dark:border-gray-800">
            <.form
              for={@form}
              id="resources-search"
              phx-change="search"
              phx-submit="search"
              class="w-full sm:max-w-md"
            >
              <.input
                field={@form[:query]}
                type="search"
                label="Find an account or process"
                placeholder="Name, email, domain, Linux user, UID or PID"
                phx-debounce="400"
                maxlength="120"
              />
            </.form>
            <p id="resources-matching" class="text-xs text-gray-500">
              {min(@matching, @limit)} of {@matching} matches · highest CPU first
            </p>
          </div>
          <div class="overflow-x-auto">
            <table class="w-full min-w-[850px] text-left text-sm">
              <thead class="bg-gray-50 text-xs text-gray-500 dark:bg-gray-800/50 dark:text-gray-400">
                <tr>
                  <th class="px-5 py-3 font-medium">Process / PID</th>
                  <th class="px-5 py-3 font-medium">Linux identity</th>
                  <th class="px-5 py-3 font-medium">Account / domains</th>
                  <th class="px-5 py-3 text-right font-medium">CPU avg.</th>
                  <th class="px-5 py-3 text-right font-medium">Resident memory</th>
                </tr>
              </thead>
              <tbody
                id="resource-processes"
                phx-update="stream"
                class="divide-y divide-gray-100 dark:divide-gray-800"
              >
                <tr id="resources-empty" class="hidden only:table-row">
                  <td colspan="5" class="px-5 py-12 text-center text-sm text-gray-500">
                    {if @loading, do: "Reading server processes…", else: "No processes to display."}
                  </td>
                </tr>
                <tr
                  :for={{id, process} <- @streams.processes}
                  id={id}
                  class="transition hover:bg-gray-50/80 dark:hover:bg-gray-800/40"
                >
                  <td class="px-5 py-4">
                    <p class="max-w-48 truncate font-medium" title={process.command}>
                      {process.command}
                    </p>
                    <p class="mt-1 font-mono text-xs text-gray-500">PID {process.pid}</p>
                  </td>
                  <td class="px-5 py-4">
                    <p class="font-mono text-xs">{process.linux_user}</p>
                    <p class="mt-1 text-xs text-gray-500">UID {process.uid}</p>
                  </td>
                  <td class="px-5 py-4">
                    <%= if process.owner do %>
                      <p class="font-medium">{owner_label(process.owner)}</p>
                      <p class="mt-1 text-xs text-gray-500">{process.owner.email}</p>
                      <p
                        class="mt-1 max-w-sm truncate text-xs text-gray-500"
                        title={Enum.join(process.owner.domains, ", ")}
                      >
                        {Enum.join(process.owner.domains, ", ")}
                      </p>
                    <% else %>
                      <p class={[
                        "text-xs",
                        if(process.attribution == :identity_mismatch,
                          do: "text-amber-700 dark:text-amber-400",
                          else: "text-gray-500"
                        )
                      ]}>
                        {if process.attribution == :identity_mismatch,
                          do: "Identity mismatch — review mapping",
                          else: "System / shared service"}
                      </p>
                    <% end %>
                  </td>
                  <td class="px-5 py-4 text-right font-mono text-xs tabular-nums">
                    <span class={[
                      "rounded-md px-2 py-1",
                      process.cpu >= 80 &&
                        "bg-amber-100 text-amber-800 dark:bg-amber-900/40 dark:text-amber-200"
                    ]}>
                      {cpu(process.cpu)}
                    </span>
                  </td>
                  <td class="px-5 py-4 text-right font-mono text-xs tabular-nums">
                    {memory(process.rss_kb)}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <div class="border-t border-gray-100 px-5 py-4 text-xs leading-relaxed text-gray-500 dark:border-gray-800">
            CPU is the process lifetime average; 100% represents one core. Resident memory includes shared pages. Domains identify the owning account, not the exact website being served. Process visibility follows the server's permissions.
          </div>
        </section>

        <section
          class="flex flex-wrap items-start justify-between gap-4 rounded-xl bg-gray-100/70 p-5 dark:bg-gray-800/50"
          aria-label="Shell lookup"
        >
          <div>
            <h2 class="text-sm font-semibold">Investigating over SSH?</h2>
            <p class="mt-1 text-xs text-gray-500">
              Find the same account from a Linux username, UID or PID.
            </p>
          </div>
          <div class="space-y-2 overflow-x-auto text-xs">
            <code class="block font-mono">sudo /opt/hostctl/bin/account-owner --user hc_5</code><code class="block font-mono">sudo /opt/hostctl/bin/account-owner --pid 1234</code><code class="block font-mono">sudo /opt/hostctl/bin/account-owner --uid 1005</code>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
