defmodule HostctlWeb.PanelLive.Features do
  use HostctlWeb, :live_view

  alias Hostctl.Settings
  alias Hostctl.FeatureSetup

  @impl true
  def mount(_params, _session, socket) do
    features = load_features()

    if connected?(socket) do
      for feature <- FeatureSetup.available_features() do
        Phoenix.PubSub.subscribe(Hostctl.PubSub, "feature_setup:#{feature.key}")
      end
    end

    {:ok,
     socket
     |> assign(:page_title, "Features")
     |> assign(:active_tab, :panel_features)
     |> assign(:features, features)
     |> assign(:active_feature, nil)
     |> stream(:log_lines, [])}
  end

  @impl true
  def handle_info({:log, line}, socket) do
    idx = socket.assigns[:log_counter] || 0
    entry = %{id: idx, text: line}

    {:noreply,
     socket
     |> assign(:log_counter, idx + 1)
     |> stream_insert(:log_lines, entry)}
  end

  @impl true
  def handle_info({:status_changed, _status}, socket) do
    {:noreply, assign(socket, :features, load_features())}
  end

  @impl true
  def handle_event("install", %{"key" => key}, socket) do
    FeatureSetup.install(key)

    {:noreply,
     socket
     |> assign(:active_feature, key)
     |> assign(:log_counter, 0)
     |> stream(:log_lines, [], reset: true)}
  end

  @impl true
  def handle_event("uninstall", %{"key" => key}, socket) do
    FeatureSetup.uninstall(key)

    {:noreply,
     socket
     |> assign(:active_feature, key)
     |> assign(:log_counter, 0)
     |> stream(:log_lines, [], reset: true)}
  end

  @impl true
  def handle_event("show_log", %{"key" => key}, socket) do
    {:noreply,
     socket
     |> assign(:active_feature, key)
     |> assign(:log_counter, 0)
     |> stream(:log_lines, [], reset: true)}
  end

  @impl true
  def handle_event("close_log", _, socket) do
    {:noreply, assign(socket, :active_feature, nil)}
  end

  defp load_features do
    for definition <- FeatureSetup.available_features() do
      setting = Settings.get_feature_setting(definition.key)

      %{
        key: definition.key,
        label: definition.label,
        description: definition.description,
        icon: definition.icon,
        packages: definition.packages,
        enabled: setting.enabled,
        status: setting.status,
        status_message: setting.status_message
      }
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_tab={@active_tab}>
      <div class="max-w-4xl mx-auto space-y-6">
        <%!-- Header --%>
        <div>
          <h1 class="text-2xl font-bold text-gray-900 dark:text-white">Features</h1>
          <p class="mt-1 text-sm text-gray-500 dark:text-gray-400">
            Enable or disable optional server features. Installing a feature will set up the required
            packages and services on this server.
          </p>
        </div>

        <%!-- Feature cards --%>
        <div class="grid gap-4">
          <div
            :for={feature <- @features}
            class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800 p-6 transition-shadow hover:shadow-sm"
          >
            <div class="flex items-start gap-4">
              <%!-- Icon --%>
              <div class={[
                "flex items-center justify-center w-11 h-11 rounded-xl shrink-0",
                if(feature.enabled,
                  do: "bg-indigo-100 dark:bg-indigo-900/30",
                  else: "bg-gray-100 dark:bg-gray-800"
                )
              ]}>
                <.icon
                  name={feature.icon}
                  class={[
                    "w-5 h-5",
                    if(feature.enabled,
                      do: "text-indigo-600 dark:text-indigo-400",
                      else: "text-gray-400 dark:text-gray-500"
                    )
                  ]}
                />
              </div>

              <%!-- Info --%>
              <div class="flex-1 min-w-0">
                <div class="flex items-center gap-2.5">
                  <h3 class="text-base font-semibold text-gray-900 dark:text-white">
                    {feature.label}
                  </h3>
                  <.status_badge status={feature.status} />
                </div>
                <p class="mt-1 text-sm text-gray-500 dark:text-gray-400">
                  {feature.description}
                </p>
                <%= if feature.packages != [] do %>
                  <p class="mt-2 text-xs text-gray-400 dark:text-gray-500">
                    Packages:
                    <span :for={pkg <- feature.packages} class="inline-flex items-center px-1.5 py-0.5 rounded bg-gray-100 dark:bg-gray-800 text-gray-600 dark:text-gray-300 font-mono text-xs mr-1">
                      {pkg}
                    </span>
                  </p>
                <% end %>
                <%= if feature.status_message do %>
                  <p class="mt-2 text-xs text-red-500 dark:text-red-400">
                    {feature.status_message}
                  </p>
                <% end %>
              </div>

              <%!-- Actions --%>
              <div class="flex items-center gap-2 shrink-0">
                <%= cond do %>
                  <% feature.status == "installing" -> %>
                    <button
                      disabled
                      class="inline-flex items-center gap-1.5 px-4 py-2 bg-gray-100 dark:bg-gray-800 text-gray-400 text-sm font-medium rounded-lg cursor-not-allowed"
                    >
                      <.icon
                        name="hero-arrow-path"
                        class="w-4 h-4 animate-spin"
                      /> Working…
                    </button>
                  <% feature.status == "installed" && feature.enabled -> %>
                    <button
                      phx-click="show_log"
                      phx-value-key={feature.key}
                      class="inline-flex items-center gap-1.5 px-3 py-2 text-gray-600 dark:text-gray-300 hover:text-gray-900 dark:hover:text-white text-sm font-medium rounded-lg border border-gray-200 dark:border-gray-700 hover:bg-gray-50 dark:hover:bg-gray-800 transition-colors"
                    >
                      <.icon name="hero-command-line" class="w-4 h-4" /> Log
                    </button>
                    <button
                      phx-click="uninstall"
                      phx-value-key={feature.key}
                      data-confirm={"Disable #{feature.label}? The service will be stopped but packages will remain installed."}
                      class="inline-flex items-center gap-1.5 px-4 py-2 bg-red-50 dark:bg-red-950/30 text-red-600 dark:text-red-400 hover:bg-red-100 dark:hover:bg-red-900/40 text-sm font-medium rounded-lg transition-colors"
                    >
                      <.icon name="hero-x-mark" class="w-4 h-4" /> Disable
                    </button>
                  <% true -> %>
                    <button
                      phx-click="install"
                      phx-value-key={feature.key}
                      data-confirm={"Install #{feature.label}? This will install packages and configure services on this server."}
                      class="inline-flex items-center gap-1.5 px-4 py-2 bg-indigo-600 hover:bg-indigo-700 text-white text-sm font-medium rounded-lg transition-colors"
                    >
                      <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> Install
                    </button>
                <% end %>
              </div>
            </div>
          </div>
        </div>

        <%!-- Log panel --%>
        <%= if @active_feature do %>
          <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800">
            <div class="flex items-center justify-between px-6 py-4 border-b border-gray-200 dark:border-gray-800">
              <h3 class="text-sm font-semibold text-gray-900 dark:text-white">
                Setup log
                <span class="ml-1 text-gray-400 font-normal">({@active_feature})</span>
              </h3>
              <button
                phx-click="close_log"
                class="text-gray-400 hover:text-gray-600 dark:hover:text-gray-200 transition-colors"
              >
                <.icon name="hero-x-mark" class="w-4 h-4" />
              </button>
            </div>
            <div
              id="setup-log"
              phx-update="stream"
              phx-hook=".SetupLogScroll"
              class="bg-gray-950 rounded-b-xl p-4 font-mono text-xs text-green-400 overflow-y-auto max-h-80 space-y-0.5"
            >
              <div class="hidden only:block text-gray-600">Waiting for output…</div>
              <div
                :for={{id, entry} <- @streams.log_lines}
                id={id}
                class="whitespace-pre-wrap break-all leading-5"
              >
                {entry.text}
              </div>
            </div>
          </div>
        <% end %>
        <script :type={Phoenix.LiveView.ColocatedHook} name=".SetupLogScroll">
          export default {
            updated() { this.el.scrollTop = this.el.scrollHeight }
          }
        </script>
      </div>
    </Layouts.app>
    """
  end

  attr :status, :string, required: true

  defp status_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium",
      cond do
        @status == "installed" ->
          "bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400"

        @status == "installing" ->
          "bg-yellow-100 text-yellow-700 dark:bg-yellow-900/30 dark:text-yellow-400"

        @status == "failed" ->
          "bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-400"

        true ->
          "bg-gray-100 text-gray-600 dark:bg-gray-800 dark:text-gray-400"
      end
    ]}>
      {String.replace(@status, "_", " ")}
    </span>
    """
  end
end
