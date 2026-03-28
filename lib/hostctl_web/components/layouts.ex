defmodule HostctlWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use HostctlWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :active_tab, :atom, default: nil, doc: "the currently active navigation tab"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="flex h-screen overflow-hidden bg-gray-50 dark:bg-gray-950">
      <%!-- Sidebar --%>
      <aside class="flex flex-col w-64 shrink-0 bg-gray-900 text-gray-100">
        <%!-- Logo --%>
        <div class="flex items-center gap-3 px-6 py-5 border-b border-gray-800">
          <div class="flex items-center justify-center w-8 h-8 rounded-lg bg-indigo-600">
            <.icon name="hero-server-stack" class="w-5 h-5 text-white" />
          </div>
          <span class="text-lg font-bold tracking-tight text-white">hostctl</span>
        </div>

        <%!-- Nav --%>
        <nav class="flex-1 px-3 py-4 space-y-0.5 overflow-y-auto">
          <.nav_item
            icon="hero-squares-2x2"
            label="Dashboard"
            href={~p"/"}
            active={@active_tab == :dashboard}
          />
          <.nav_item
            icon="hero-globe-alt"
            label="Domains"
            href={~p"/domains"}
            active={@active_tab == :domains}
          />
          <div class="pt-4 pb-1 px-3">
            <p class="text-xs font-semibold uppercase tracking-wider text-gray-500">Services</p>
          </div>
          <.nav_item
            icon="hero-envelope"
            label="Email"
            href={~p"/email"}
            active={@active_tab == :email}
          />
          <.nav_item
            icon="hero-circle-stack"
            label="Databases"
            href={~p"/databases"}
            active={@active_tab == :databases}
          />
          <.nav_item
            icon="hero-folder"
            label="FTP Accounts"
            href={~p"/ftp"}
            active={@active_tab == :ftp}
          />
          <.nav_item
            icon="hero-clock"
            label="Cron Jobs"
            href={~p"/cron"}
            active={@active_tab == :cron}
          />
          <div class="pt-4 pb-1 px-3">
            <p class="text-xs font-semibold uppercase tracking-wider text-gray-500">System</p>
          </div>
          <.nav_item
            icon="hero-arrow-up-circle"
            label="Updates"
            href={~p"/updates"}
            active={@active_tab == :updates}
          />
          <div class="pt-4 pb-1 px-3">
            <p class="text-xs font-semibold uppercase tracking-wider text-gray-500">Account</p>
          </div>
          <.nav_item
            icon="hero-cog-6-tooth"
            label="Settings"
            href={~p"/users/settings"}
            active={@active_tab == :settings}
          />
        </nav>

        <%!-- User --%>
        <%= if @current_scope do %>
          <div class="px-4 py-4 border-t border-gray-800">
            <div class="flex items-center gap-3">
              <div class="flex items-center justify-center w-8 h-8 rounded-full bg-indigo-700 text-white text-sm font-semibold shrink-0">
                {String.upcase(String.slice(@current_scope.user.email, 0, 1))}
              </div>
              <div class="flex-1 min-w-0">
                <p class="text-sm font-medium text-white truncate">
                  {if @current_scope.user.name,
                    do: @current_scope.user.name,
                    else: @current_scope.user.email}
                </p>
                <p class="text-xs text-gray-400 truncate capitalize">{@current_scope.user.role}</p>
              </div>
              <.link
                href={~p"/users/log-out"}
                method="delete"
                class="text-gray-400 hover:text-white transition-colors"
                title="Sign out"
              >
                <.icon name="hero-arrow-right-on-rectangle" class="w-4 h-4" />
              </.link>
            </div>
          </div>
        <% end %>
      </aside>

      <%!-- Main content --%>
      <div class="flex flex-col flex-1 min-w-0 overflow-hidden">
        <%!-- Top bar --%>
        <header class="flex items-center justify-between px-6 py-3 bg-white dark:bg-gray-900 border-b border-gray-200 dark:border-gray-800 shrink-0">
          <div class="flex items-center gap-2 text-sm text-gray-500 dark:text-gray-400">
            <%!-- Breadcrumb slot could go here --%>
          </div>
          <div class="flex items-center gap-3">
            <.theme_toggle />
          </div>
        </header>

        <%!-- Page content --%>
        <main class="flex-1 overflow-y-auto px-6 py-6">
          {render_slot(@inner_block)}
        </main>
      </div>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :href, :string, required: true
  attr :active, :boolean, default: false

  defp nav_item(assigns) do
    ~H"""
    <.link
      navigate={@href}
      class={[
        "flex items-center gap-3 px-3 py-2 rounded-lg text-sm font-medium transition-colors",
        if(@active,
          do: "bg-indigo-600 text-white",
          else: "text-gray-400 hover:bg-gray-800 hover:text-white"
        )
      ]}
    >
      <.icon name={@icon} class="w-4 h-4 shrink-0" />
      {@label}
    </.link>
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
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-3.5 opacity-60 hover:opacity-100" />
      </button>
      <button
        class="flex p-1.5 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-3.5 opacity-60 hover:opacity-100" />
      </button>
      <button
        class="flex p-1.5 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-3.5 opacity-60 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
