defmodule HostctlWeb.DashboardLive do
  use HostctlWeb, :live_view

  alias Hostctl.Hosting

  def mount(_params, _session, socket) do
    stats = Hosting.domain_stats(socket.assigns.current_scope)
    domains = Hosting.list_domains(socket.assigns.current_scope)

    {:ok,
     socket
     |> assign(:page_title, "Dashboard")
     |> assign(:active_tab, :dashboard)
     |> assign(:stats, stats)
     |> stream(:recent_domains, Enum.take(domains, 5))}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_tab={@active_tab}>
      <div class="space-y-6">
        <%!-- Header --%>
        <div>
          <h1 class="text-2xl font-bold text-gray-900 dark:text-white">Dashboard</h1>
          <p class="mt-1 text-sm text-gray-500 dark:text-gray-400">
            Welcome back, {if @current_scope.user.name,
              do: @current_scope.user.name,
              else: @current_scope.user.email}
          </p>
        </div>

        <%!-- Stats cards --%>
        <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
          <.stat_card
            icon="hero-globe-alt"
            label="Total Domains"
            value={@stats.total}
            color="indigo"
          />
          <.stat_card
            icon="hero-check-circle"
            label="Active Domains"
            value={@stats.active}
            color="green"
          />
          <.stat_card
            icon="hero-lock-closed"
            label="SSL Enabled"
            value={@stats.ssl_enabled}
            color="blue"
          />
          <.stat_card
            icon="hero-server"
            label="Server Status"
            value="Online"
            color="emerald"
          />
        </div>

        <%!-- Recent domains --%>
        <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800">
          <div class="flex items-center justify-between px-6 py-4 border-b border-gray-200 dark:border-gray-800">
            <h2 class="text-base font-semibold text-gray-900 dark:text-white">Recent Domains</h2>
            <.link
              navigate={~p"/domains"}
              class="text-sm font-medium text-indigo-600 dark:text-indigo-400 hover:text-indigo-500"
            >
              View all &rarr;
            </.link>
          </div>

          <div
            id="recent-domains"
            phx-update="stream"
            class="divide-y divide-gray-100 dark:divide-gray-800"
          >
            <div class="hidden only:flex items-center justify-center py-12 text-sm text-gray-500 dark:text-gray-400">
              No domains yet.
              <.link
                navigate={~p"/domains/new"}
                class="ml-1 text-indigo-600 dark:text-indigo-400 hover:underline"
              >
                Add your first domain
              </.link>
            </div>
            <div
              :for={{id, domain} <- @streams.recent_domains}
              id={id}
              class="flex items-center justify-between px-6 py-3"
            >
              <div class="flex items-center gap-3">
                <div class="flex items-center justify-center w-8 h-8 rounded-lg bg-gray-100 dark:bg-gray-800">
                  <.icon name="hero-globe-alt" class="w-4 h-4 text-gray-500 dark:text-gray-400" />
                </div>
                <div>
                  <p class="text-sm font-medium text-gray-900 dark:text-white">{domain.name}</p>
                  <p class="text-xs text-gray-500 dark:text-gray-400">PHP {domain.php_version}</p>
                </div>
              </div>
              <div class="flex items-center gap-3">
                <.status_badge status={domain.status} />
                <.link
                  navigate={~p"/domains/#{domain.id}"}
                  class="text-xs text-gray-400 hover:text-gray-600 dark:hover:text-gray-200"
                >
                  Manage &rarr;
                </.link>
              </div>
            </div>
          </div>
        </div>

        <%!-- Quick actions --%>
        <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
          <.quick_action icon="hero-plus-circle" label="Add Domain" href={~p"/domains/new"} />
          <.quick_action icon="hero-envelope" label="Create Email" href={~p"/email"} />
          <.quick_action icon="hero-circle-stack" label="New Database" href={~p"/databases"} />
          <.quick_action icon="hero-lock-closed" label="SSL Certificates" href={~p"/domains"} />
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :color, :string, default: "indigo"

  defp stat_card(assigns) do
    ~H"""
    <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800 p-6">
      <div class="flex items-center gap-4">
        <div class={[
          "flex items-center justify-center w-10 h-10 rounded-lg shrink-0",
          "bg-#{@color}-100 dark:bg-#{@color}-900/30"
        ]}>
          <.icon name={@icon} class={"w-5 h-5 text-#{@color}-600 dark:text-#{@color}-400"} />
        </div>
        <div>
          <p class="text-sm text-gray-500 dark:text-gray-400">{@label}</p>
          <p class="text-2xl font-bold text-gray-900 dark:text-white">{@value}</p>
        </div>
      </div>
    </div>
    """
  end

  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :href, :string, required: true

  defp quick_action(assigns) do
    ~H"""
    <.link
      navigate={@href}
      class="flex items-center gap-3 p-4 bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800 hover:border-indigo-300 dark:hover:border-indigo-700 hover:bg-indigo-50 dark:hover:bg-indigo-950/30 transition-colors group"
    >
      <.icon
        name={@icon}
        class="w-5 h-5 text-gray-400 group-hover:text-indigo-600 dark:group-hover:text-indigo-400 transition-colors"
      />
      <span class="text-sm font-medium text-gray-700 dark:text-gray-300 group-hover:text-indigo-700 dark:group-hover:text-indigo-300">
        {@label}
      </span>
    </.link>
    """
  end

  attr :status, :string, required: true

  defp status_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium",
      cond do
        @status == "active" -> "bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400"
        @status == "suspended" -> "bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-400"
        true -> "bg-yellow-100 text-yellow-700 dark:bg-yellow-900/30 dark:text-yellow-400"
      end
    ]}>
      {@status}
    </span>
    """
  end
end
