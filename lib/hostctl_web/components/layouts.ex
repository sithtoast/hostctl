defmodule HostctlWeb.Layouts do
  use HostctlWeb, :html
  alias Hostctl.{Settings}
  alias HostctlWeb.Navigation
  embed_templates "layouts/*"

  attr :flash, :map, required: true
  attr :current_scope, :map, default: nil
  attr :active_tab, :atom, default: nil
  attr :update_status, :map, default: nil
  slot :inner_block, required: true

  def app(assigns) do
    assigns =
      assigns
      |> assign(:admin?, assigns.current_scope && assigns.current_scope.user.role == "admin")
      |> assign(:nav_title, Navigation.title(assigns.active_tab))
      |> assign(
        :hosting_links,
        Enum.reject(Navigation.hosting(), fn {key, _, _, _} ->
          key == :ftp and not Settings.feature_enabled?("ftp")
        end)
      )
      |> assign(:groups, Navigation.groups())

    ~H"""
    <div id="hostctl-shell" class={["hostctl-shell", is_nil(@current_scope) && "guest-shell"]}>
      <a
        href="#main-content"
        class="sr-only focus:not-sr-only focus:fixed focus:top-2 focus:left-2 focus:z-50"
      >
        Skip to content
      </a>
      <aside :if={@current_scope} id="app-sidebar" class="app-sidebar" aria-label="Main navigation">
        <.link navigate={~p"/"} class="app-brand">
          <span class="flex size-8 items-center justify-center rounded-lg bg-indigo-600 text-white">
            <.icon name="hero-server-stack" class="size-5" />
          </span>
          hostctl
        </.link>
        <nav class="flex-1 overflow-y-auto px-3 pb-5">
          <p class="nav-section">Hosting</p>
          <.nav_item
            :for={{key, label, path, icon} <- @hosting_links}
            id={"nav-#{key}"}
            label={label}
            href={path}
            icon={icon}
            active={@active_tab == key}
          />
          <%= if @admin? do %>
            <p class="nav-section">Administration</p>
            <.nav_item
              id="nav-admin"
              label="Overview"
              href={~p"/panel"}
              icon="hero-squares-2x2"
              active={@active_tab == :admin_overview}
            />
            <details
              :for={{key, label, path, items} <- @groups}
              id={"nav-group-#{key}"}
              open={Navigation.group_active?(@active_tab, key, items)}
              class="nav-group"
            >
              <summary class="nav-group-heading">
                <span>{label}</span>
                <.update_badge
                  :if={key == :admin_system}
                  status={@update_status}
                  id="system-update-badge"
                />
              </summary>
              <.nav_item
                id={"nav-#{key}"}
                label={"#{label} overview"}
                href={path}
                icon="hero-squares-2x2"
                active={@active_tab == key}
              />
              <.nav_item
                :for={{item, title, href, icon} <- items}
                id={"nav-#{item}"}
                label={title}
                href={href}
                icon={icon}
                active={@active_tab == item}
                update_status={if item == :updates, do: @update_status}
              />
            </details>
          <% else %>
            <p class="nav-section">System</p>
            <.nav_item
              id="nav-updates"
              label="Updates"
              href={~p"/updates"}
              icon="hero-arrow-up-circle"
              active={@active_tab == :updates}
            />
            <.nav_item
              :if={@current_scope.user.role == "reseller"}
              id="nav-panel-users"
              label="Panel users"
              href={~p"/panel/users"}
              icon="hero-users"
              active={@active_tab == :panel_users}
            />
          <% end %>
          <p class="nav-section">Account</p>
          <.nav_item
            id="nav-settings"
            label="Settings"
            href={~p"/users/settings"}
            icon="hero-cog-6-tooth"
            active={@active_tab == :settings}
          />
        </nav>
        <div class="app-user">
          <div class="min-w-0 flex-1">
            <p class="truncate font-medium">
              {@current_scope.user.name || @current_scope.user.email}
            </p>
            <p class="text-xs capitalize text-gray-500 dark:text-gray-400">
              {@current_scope.user.role}
            </p>
          </div>
          <.link href={~p"/users/log-out"} method="delete" aria-label="Sign out">
            <.icon name="hero-arrow-right-on-rectangle" class="size-5" />
          </.link>
        </div>
      </aside>
      <div class="app-workspace">
        <header class="app-topbar">
          <button
            :if={@current_scope}
            id="navigation-toggle"
            type="button"
            class="app-button lg:hidden"
            aria-controls="app-sidebar"
            aria-expanded="false"
            phx-click={
              JS.toggle_class("navigation-open", to: "#hostctl-shell")
              |> JS.toggle_attribute({"aria-expanded", "true", "false"}, to: "#navigation-toggle")
            }
          >
            <.icon name="hero-bars-3" class="size-5" /><span class="sr-only">Toggle navigation</span>
          </button>
          <nav aria-label="Breadcrumb" class="text-sm text-gray-500 dark:text-gray-400">
            <span :if={
              @admin? &&
                @active_tab not in [
                  :admin_overview,
                  :dashboard,
                  :domains,
                  :email,
                  :databases,
                  :ftp,
                  :cron,
                  :settings
                ]
            }>
              Administration <span aria-hidden="true">/</span>
            </span>
            <span aria-current="page">{@nav_title}</span>
          </nav>
          <div class="ml-auto flex items-center gap-3"><.theme_toggle /></div>
        </header>
        <main id="main-content" class="app-content">{render_slot(@inner_block)}</main>
      </div>
    </div>
    <.flash_group flash={@flash} />
    """
  end

  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :href, :string, required: true
  attr :active, :boolean, default: false
  attr :update_status, :map, default: nil

  defp nav_item(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={@href}
      class={["app-nav-link", @active && "is-active"]}
      aria-current={if @active, do: "page"}
    >
      <.icon name={@icon} class="size-4 shrink-0" /><span>{@label}</span>
      <.update_badge status={@update_status} id={"#{@id}-badge"} />
    </.link>
    """
  end

  attr :status, :map, default: nil
  attr :id, :string, required: true

  def update_badge(assigns) do
    ~H"""
    <span
      :if={@status && (@status.available? || @status.status == :error)}
      id={@id}
      class={["update-badge", @status.status == :error && "update-badge-error"]}
      aria-label={if @status.status == :error, do: "Update check failed", else: "Update available"}
      title={
        if @status.status == :error,
          do: "Update check failed; open Updates for details",
          else: "Hostctl update available"
      }
    >
      {if @status.status == :error, do: "!", else: "1"}
    </span>
    """
  end

  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  def theme_toggle(assigns) do
    ~H"""
    <div class="relative flex flex-row items-center border border-gray-200 dark:border-gray-700 bg-gray-100 dark:bg-gray-800 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full bg-white dark:bg-gray-600 shadow-sm left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />
      <button
        class="flex p-1.5 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        aria-label="Use system theme"
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-3.5 opacity-60 hover:opacity-100" />
      </button>
      <button
        class="flex p-1.5 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        aria-label="Use light theme"
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-3.5 opacity-60 hover:opacity-100" />
      </button>
      <button
        class="flex p-1.5 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        aria-label="Use dark theme"
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-3.5 opacity-60 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
