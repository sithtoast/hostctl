defmodule HostctlWeb.PanelLive.Domains do
  use HostctlWeb, :live_view

  alias Hostctl.Hosting

  @impl true
  def mount(_params, _session, socket) do
    domains = Hosting.list_all_domains_with_users()

    {:ok,
     socket
     |> assign(:page_title, "All Domains")
     |> assign(:domains_empty?, domains == [])
     |> stream(:domains, domains)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_tab={:panel_domains}>
      <div class="max-w-5xl mx-auto space-y-6">
        <%!-- Header --%>
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-bold text-gray-900 dark:text-white">All Domains</h1>
            <p class="mt-1 text-sm text-gray-500 dark:text-gray-400">
              All domains currently hosted on this server.
            </p>
          </div>
        </div>

        <%!-- Domains table --%>
        <div class="rounded-xl border border-gray-200 dark:border-gray-800 bg-white dark:bg-gray-900 overflow-hidden shadow-sm">
          <%= if @domains_empty? do %>
            <div class="flex flex-col items-center justify-center py-16 text-center">
              <div class="flex items-center justify-center w-12 h-12 rounded-full bg-gray-100 dark:bg-gray-800 mb-4">
                <.icon name="hero-globe-alt" class="w-6 h-6 text-gray-400" />
              </div>
              <p class="text-sm font-medium text-gray-900 dark:text-white">No domains yet</p>
              <p class="text-xs text-gray-500 dark:text-gray-400 mt-1">
                No users have added any domains to this server.
              </p>
            </div>
          <% else %>
            <table class="min-w-full divide-y divide-gray-200 dark:divide-gray-800">
              <thead class="bg-gray-50 dark:bg-gray-800/50">
                <tr>
                  <th class="px-6 py-3 text-left text-xs font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-400">
                    Domain
                  </th>
                  <th class="px-6 py-3 text-left text-xs font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-400">
                    Owner
                  </th>
                  <th class="px-6 py-3 text-left text-xs font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-400">
                    PHP
                  </th>
                  <th class="px-6 py-3 text-left text-xs font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-400">
                    Status
                  </th>
                  <th class="px-6 py-3 text-left text-xs font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-400">
                    SSL
                  </th>
                  <th class="relative px-6 py-3">
                    <span class="sr-only">Actions</span>
                  </th>
                </tr>
              </thead>
              <tbody id="all-domains" phx-update="stream" class="divide-y divide-gray-100 dark:divide-gray-800">
                <tr
                  :for={{id, domain} <- @streams.domains}
                  id={id}
                  class="hover:bg-gray-50 dark:hover:bg-gray-800/40 transition-colors"
                >
                  <td class="px-6 py-4">
                    <div class="flex items-center gap-2">
                      <.icon name="hero-globe-alt" class="w-4 h-4 text-gray-400 shrink-0" />
                      <span class="text-sm font-medium text-gray-900 dark:text-white">
                        {domain.name}
                      </span>
                    </div>
                  </td>
                  <td class="px-6 py-4">
                    <div class="flex items-center gap-2">
                      <div class="flex items-center justify-center w-6 h-6 rounded-full bg-indigo-100 dark:bg-indigo-900/50 text-indigo-700 dark:text-indigo-300 text-xs font-semibold shrink-0">
                        {String.upcase(String.slice(domain.user.email, 0, 1))}
                      </div>
                      <div class="min-w-0">
                        <%= if domain.user.name do %>
                          <p class="text-sm font-medium text-gray-900 dark:text-white truncate">
                            {domain.user.name}
                          </p>
                          <p class="text-xs text-gray-500 dark:text-gray-400 truncate">
                            {domain.user.email}
                          </p>
                        <% else %>
                          <p class="text-sm text-gray-900 dark:text-white truncate">
                            {domain.user.email}
                          </p>
                        <% end %>
                      </div>
                    </div>
                  </td>
                  <td class="px-6 py-4">
                    <span class="text-sm text-gray-600 dark:text-gray-300">
                      PHP {domain.php_version}
                    </span>
                  </td>
                  <td class="px-6 py-4">
                    <span class={[
                      "inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium",
                      domain.status == "active" &&
                        "bg-green-100 text-green-700 dark:bg-green-900/40 dark:text-green-400",
                      domain.status == "suspended" &&
                        "bg-red-100 text-red-700 dark:bg-red-900/40 dark:text-red-400",
                      domain.status == "pending" &&
                        "bg-yellow-100 text-yellow-700 dark:bg-yellow-900/40 dark:text-yellow-400"
                    ]}>
                      {String.capitalize(domain.status)}
                    </span>
                  </td>
                  <td class="px-6 py-4">
                    <%= if domain.ssl_enabled do %>
                      <span class="inline-flex items-center gap-1 text-xs font-medium text-green-600 dark:text-green-400">
                        <.icon name="hero-lock-closed" class="w-3.5 h-3.5" /> SSL
                      </span>
                    <% else %>
                      <span class="text-xs text-gray-400">—</span>
                    <% end %>
                  </td>
                  <td class="px-6 py-4 text-right">
                    <.link
                      navigate={~p"/domains/#{domain.id}"}
                      class="text-xs font-medium text-indigo-600 hover:text-indigo-800 dark:text-indigo-400 dark:hover:text-indigo-300 transition-colors"
                    >
                      View
                    </.link>
                  </td>
                </tr>
              </tbody>
            </table>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
