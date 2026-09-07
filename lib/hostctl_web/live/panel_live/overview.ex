defmodule HostctlWeb.PanelLive.Overview do
  use HostctlWeb, :live_view
  alias HostctlWeb.Navigation

  def mount(_params, _session, socket), do: {:ok, socket}

  def handle_params(_params, _uri, socket) do
    tab =
      %{
        overview: :admin_overview,
        mail: :admin_mail,
        backup: :admin_backup,
        system: :admin_system
      }[socket.assigns.live_action]

    groups =
      if tab == :admin_overview,
        do: Navigation.groups(),
        else: Enum.filter(Navigation.groups(), &(elem(&1, 0) == tab))

    {:noreply, assign(socket, active_tab: tab, page_title: Navigation.title(tab), groups: groups)}
  end

  defp area_description(:admin_mail),
    do: "Protect mail, configure delivery, and manage mailboxes."

  defp area_description(:admin_backup),
    do: "Plan backups, review completed runs, and migrate websites."

  defp area_description(:admin_system),
    do: "Manage the server runtime, installed features, and access."

  defp destination_description(item) do
    %{
      panel_spam_protection: "Review spam filtering, learning, and protection settings.",
      panel_email_delivery: "Check mail authentication and review DNS changes.",
      panel_smarthost: "Configure outbound mail routing and relay credentials.",
      panel_emails: "Find and manage mailboxes across all panel users.",
      panel_backup: "Set backup schedules and local or S3 destinations.",
      panel_completed_backups: "Review backup results and available archives.",
      panel_plesk_import: "Discover, map, review, and track a Plesk migration.",
      updates: "Review available versions and install updates when ready.",
      panel_docker: "Manage containers, proxy mappings, images, and Compose stacks.",
      panel_features: "Install and configure optional server capabilities.",
      panel_settings: "Manage server addresses and shared panel configuration.",
      panel_users: "Manage panel accounts, roles, and ownership.",
      panel_databases: "Inspect databases and users across hosted domains.",
      panel_ftp: "Review server-wide FTP access and directory assignments."
    }[item]
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_tab={@active_tab}
      update_status={assigns[:update_status]}
    >
      <div id="administration" class="space-y-6">
        <div>
          <h1 class="text-2xl font-semibold text-gray-900 dark:text-white">{@page_title}</h1>
          <p class="mt-1 text-sm text-gray-500 dark:text-gray-400">
            Server-wide services and resources across all panel users.
          </p>
        </div>
        <div
          :if={@update_status && (@update_status.available? || @update_status.status == :error)}
          id="admin-update-notice"
          class="flex flex-wrap items-center justify-between gap-4 rounded-xl border border-indigo-200 bg-indigo-50 p-5 dark:border-indigo-900 dark:bg-indigo-950/30"
        >
          <p class="text-sm text-indigo-800 dark:text-indigo-200">
            {if @update_status.status == :error,
              do: "The latest update check failed. Review the last known result.",
              else: "A Hostctl update is available."}
          </p>
          <.link
            navigate={~p"/updates"}
            class="text-sm font-medium text-indigo-600 dark:text-indigo-400"
          >
            Review updates →
          </.link>
        </div>
        <section
          :for={{key, title, path, items} <- @groups}
          id={"admin-area-#{key}"}
          class="space-y-4"
        >
          <div class="flex flex-wrap items-center justify-between gap-3 pt-3">
            <div>
              <h2 class="text-base font-semibold">{title}</h2>
              <p class="mt-1 text-xs text-gray-500">{area_description(key)}</p>
            </div>
            <.link :if={@active_tab == :admin_overview} navigate={path} class="ui-text-link">
              Open overview →
            </.link>
          </div>
          <div class="admin-card-grid">
            <.link
              :for={{item, label, href, icon} <- items}
              id={"admin-link-#{item}"}
              navigate={href}
              class="ui-panel admin-destination"
            >
              <div class="admin-destination-icon">
                <.icon name={icon} class="size-6" /><Layouts.update_badge
                  :if={item == :updates}
                  id="admin-updates-badge"
                  status={@update_status}
                /><span aria-hidden="true">↗</span>
              </div>
              <div>
                <h3>{label}</h3>
                <p>{destination_description(item)}</p>
              </div>
            </.link>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
