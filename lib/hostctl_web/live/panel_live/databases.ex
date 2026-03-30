defmodule HostctlWeb.PanelLive.Databases do
  use HostctlWeb, :live_view

  alias Hostctl.Hosting

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_tab={:panel_databases}>
      <div class="max-w-5xl mx-auto space-y-6">
        <%!-- Header --%>
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-bold text-gray-900 dark:text-white">All Databases</h1>
            <p class="mt-1 text-sm text-gray-500 dark:text-gray-400">
              All databases across every user and domain.
            </p>
          </div>
          <span class="inline-flex items-center gap-1.5 px-3 py-1 rounded-full bg-gray-100 dark:bg-gray-800 text-xs font-medium text-gray-600 dark:text-gray-300">
            {@total} total
          </span>
        </div>

        <%!-- Table --%>
        <div class="rounded-xl border border-gray-200 dark:border-gray-800 bg-white dark:bg-gray-900 shadow-sm overflow-hidden">
          <%= if @dbs_empty? do %>
            <div
              id="panel-dbs-empty"
              class="flex items-center justify-center py-16 text-gray-400 dark:text-gray-600"
            >
              <div class="text-center space-y-2">
                <.icon name="hero-circle-stack" class="w-10 h-10 mx-auto" />
                <p class="text-sm">No databases found.</p>
              </div>
            </div>
          <% end %>
          <div id="panel-databases-list" phx-update="stream">
            <div
              :for={{id, db} <- @streams.databases}
              id={id}
              class="flex items-center gap-4 px-6 py-4 border-b border-gray-100 dark:border-gray-800 last:border-b-0 hover:bg-gray-50 dark:hover:bg-gray-800/50 transition-colors"
            >
              <div class="flex items-center justify-center w-9 h-9 rounded-lg bg-indigo-100 dark:bg-indigo-900/40 text-indigo-600 dark:text-indigo-400 shrink-0">
                <.icon name="hero-circle-stack" class="w-5 h-5" />
              </div>
              <div class="flex-1 min-w-0">
                <p class="text-sm font-medium text-gray-900 dark:text-white truncate">{db.name}</p>
                <p class="text-xs text-gray-500 dark:text-gray-400 truncate">
                  {db.domain.name}
                  <span class="text-gray-400 dark:text-gray-600">&nbsp;&bull;&nbsp;</span>
                  {db.domain.user.email}
                </p>
              </div>
              <div class="flex items-center gap-3 shrink-0">
                <span class="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-gray-100 dark:bg-gray-800 text-gray-600 dark:text-gray-300 capitalize">
                  {db.db_type}
                </span>
                <%= if db.status == "active" do %>
                  <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium bg-green-100 dark:bg-green-900/40 text-green-700 dark:text-green-400">
                    <span class="w-1.5 h-1.5 rounded-full bg-green-500 inline-block"></span> Active
                  </span>
                <% else %>
                  <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium bg-amber-100 dark:bg-amber-900/40 text-amber-700 dark:text-amber-400">
                    <span class="w-1.5 h-1.5 rounded-full bg-amber-400 inline-block"></span>
                    {String.capitalize(db.status)}
                  </span>
                <% end %>
                <p class="text-xs text-gray-400 dark:text-gray-500 hidden sm:block">
                  {Calendar.strftime(db.inserted_at, "%b %-d, %Y")}
                </p>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    databases = Hosting.list_all_databases_with_domains()

    {:ok,
     socket
     |> assign(:page_title, "All Databases")
     |> assign(:total, length(databases))
     |> assign(:dbs_empty?, databases == [])
     |> stream(:databases, databases)}
  end
end
