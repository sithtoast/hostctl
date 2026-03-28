defmodule HostctlWeb.PanelLive.Settings do
  use HostctlWeb, :live_view

  alias Hostctl.Settings
  alias Hostctl.DNS.Cloudflare

  @impl true
  def mount(_params, _session, socket) do
    ip_settings = Settings.sync_and_list_ip_settings()
    dns_setting = Settings.get_dns_provider_setting()
    dns_form = to_form(Settings.change_dns_provider_setting(dns_setting), as: :dns_provider)

    {:ok,
     socket
     |> assign(:page_title, "Panel Settings")
     |> assign(:active_tab, :panel_settings)
     |> assign(:editing_id, nil)
     |> assign(:edit_form, nil)
     |> assign(:dns_setting, dns_setting)
     |> assign(:dns_form, dns_form)
     |> assign(:dns_test_status, nil)
     |> stream(:ip_settings, ip_settings)}
  end

  @impl true
  def handle_event("edit", %{"id" => id}, socket) do
    setting = Settings.get_ip_setting!(id)
    form = to_form(Settings.change_ip_setting(setting), as: :ip_setting)

    {:noreply,
     socket
     |> assign(:editing_id, String.to_integer(id))
     |> assign(:edit_form, form)
     |> stream_insert(:ip_settings, setting)}
  end

  @impl true
  def handle_event("cancel_edit", _, socket) do
    {:noreply, socket |> assign(:editing_id, nil) |> assign(:edit_form, nil)}
  end

  @impl true
  def handle_event("save", %{"ip_setting" => params}, socket) do
    setting = Settings.get_ip_setting!(socket.assigns.editing_id)

    case Settings.update_ip_setting(setting, params) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> put_flash(:info, "IP setting updated.")
         |> assign(:editing_id, nil)
         |> assign(:edit_form, nil)
         |> stream_insert(:ip_settings, updated)}

      {:error, changeset} ->
        {:noreply, assign(socket, :edit_form, to_form(changeset, as: :ip_setting))}
    end
  end

  @impl true
  def handle_event("validate", %{"ip_setting" => params}, socket) do
    setting = Settings.get_ip_setting!(socket.assigns.editing_id)
    form = to_form(Settings.change_ip_setting(setting, params), as: :ip_setting)
    {:noreply, assign(socket, :edit_form, form)}
  end

  @impl true
  def handle_event("refresh_ips", _, socket) do
    ip_settings = Settings.sync_and_list_ip_settings()

    {:noreply,
     socket
     |> put_flash(:info, "IP list refreshed.")
     |> stream(:ip_settings, ip_settings, reset: true)}
  end

  @impl true
  def handle_event("validate_dns", %{"dns_provider" => params}, socket) do
    dns_setting = socket.assigns.dns_setting
    form = to_form(Settings.change_dns_provider_setting(dns_setting, params), as: :dns_provider)
    {:noreply, assign(socket, :dns_form, form)}
  end

  @impl true
  def handle_event("save_dns", %{"dns_provider" => params}, socket) do
    case Settings.save_dns_provider_setting(params) do
      {:ok, updated} ->
        dns_form = to_form(Settings.change_dns_provider_setting(updated), as: :dns_provider)

        {:noreply,
         socket
         |> assign(:dns_setting, updated)
         |> assign(:dns_form, dns_form)
         |> assign(:dns_test_status, nil)
         |> put_flash(:info, "DNS provider settings saved.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :dns_form, to_form(changeset, as: :dns_provider))}
    end
  end

  @impl true
  def handle_event("test_cloudflare", _, socket) do
    dns_setting = socket.assigns.dns_setting

    status =
      case dns_setting do
        %{provider: "cloudflare", cloudflare_api_token: token}
        when is_binary(token) and token != "" ->
          case Cloudflare.verify_token(token) do
            {:ok, :valid} -> :ok
            {:error, reason} -> {:error, reason}
          end

        _ ->
          {:error, "No API token configured"}
      end

    {:noreply, assign(socket, :dns_test_status, status)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_tab={@active_tab}>
      <div class="space-y-6">
        <%!-- Header --%>
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-bold text-gray-900 dark:text-white">Panel Settings</h1>
            <p class="mt-1 text-sm text-gray-500 dark:text-gray-400">
              Manage server network interfaces and external IP mappings for DNS.
            </p>
          </div>
          <button
            id="refresh-ips-btn"
            phx-click="refresh_ips"
            class="inline-flex items-center gap-2 px-4 py-2 rounded-lg bg-indigo-600 hover:bg-indigo-500 text-white text-sm font-medium transition-colors"
          >
            <.icon name="hero-arrow-path" class="w-4 h-4" /> Refresh IPs
          </button>
        </div>

        <%!-- IP Settings table --%>
        <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800 overflow-hidden">
          <div class="px-6 py-4 border-b border-gray-200 dark:border-gray-800">
            <div class="flex items-center gap-3">
              <div class="flex items-center justify-center w-8 h-8 rounded-lg bg-indigo-100 dark:bg-indigo-900/30">
                <.icon name="hero-server" class="w-4 h-4 text-indigo-600 dark:text-indigo-400" />
              </div>
              <div>
                <h2 class="text-base font-semibold text-gray-900 dark:text-white">
                  Server IP Addresses
                </h2>
                <p class="text-xs text-gray-500 dark:text-gray-400">
                  Detected network interfaces. Set an external IP for each to use in DNS records.
                </p>
              </div>
            </div>
          </div>

          <div id="ip-settings" phx-update="stream">
            <div class="hidden only:flex items-center justify-center py-12 text-sm text-gray-500 dark:text-gray-400">
              No network interfaces detected.
            </div>
            <div
              :for={{dom_id, setting} <- @streams.ip_settings}
              id={dom_id}
              class="border-b border-gray-100 dark:border-gray-800 last:border-0"
            >
              <%!-- View row --%>
              <%= if @editing_id != setting.id do %>
                <div class="flex items-center gap-4 px-6 py-4">
                  <div class="flex items-center justify-center w-9 h-9 rounded-lg bg-gray-100 dark:bg-gray-800 shrink-0">
                    <.icon
                      name="hero-cpu-chip"
                      class="w-4 h-4 text-gray-500 dark:text-gray-400"
                    />
                  </div>

                  <div class="flex-1 grid grid-cols-1 sm:grid-cols-4 gap-x-6 gap-y-1 min-w-0">
                    <div>
                      <p class="text-xs font-medium text-gray-400 dark:text-gray-500 uppercase tracking-wide">
                        Interface
                      </p>
                      <p class="text-sm font-mono text-gray-900 dark:text-white truncate">
                        {setting.interface || "—"}
                      </p>
                    </div>
                    <div>
                      <p class="text-xs font-medium text-gray-400 dark:text-gray-500 uppercase tracking-wide">
                        Detected IP
                      </p>
                      <p class="text-sm font-mono text-gray-900 dark:text-white truncate">
                        {setting.ip_address}
                      </p>
                    </div>
                    <div>
                      <p class="text-xs font-medium text-gray-400 dark:text-gray-500 uppercase tracking-wide">
                        External IP (DNS)
                      </p>
                      <%= if setting.external_ip && setting.external_ip != "" do %>
                        <p class="text-sm font-mono text-emerald-600 dark:text-emerald-400 truncate">
                          {setting.external_ip}
                        </p>
                      <% else %>
                        <p class="text-sm text-gray-400 dark:text-gray-600 italic">Not set</p>
                      <% end %>
                    </div>
                    <div>
                      <p class="text-xs font-medium text-gray-400 dark:text-gray-500 uppercase tracking-wide">
                        Label
                      </p>
                      <p class="text-sm text-gray-900 dark:text-white truncate">
                        {setting.label || "—"}
                      </p>
                    </div>
                  </div>

                  <button
                    id={"edit-btn-#{setting.id}"}
                    phx-click="edit"
                    phx-value-id={setting.id}
                    class="shrink-0 inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-medium text-gray-600 dark:text-gray-400 bg-gray-100 dark:bg-gray-800 hover:bg-gray-200 dark:hover:bg-gray-700 transition-colors"
                  >
                    <.icon name="hero-pencil-square" class="w-3.5 h-3.5" /> Edit
                  </button>
                </div>
              <% else %>
                <%!-- Edit row --%>
                <div class="px-6 py-4 bg-indigo-50/50 dark:bg-indigo-950/20">
                  <.form
                    for={@edit_form}
                    id={"edit-form-#{setting.id}"}
                    phx-submit="save"
                    phx-change="validate"
                    class="space-y-4"
                  >
                    <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
                      <div>
                        <p class="text-xs font-medium text-gray-400 dark:text-gray-500 uppercase tracking-wide mb-1">
                          Interface
                        </p>
                        <p class="text-sm font-mono text-gray-900 dark:text-white py-2">
                          {setting.interface || "—"}
                        </p>
                      </div>
                      <div>
                        <p class="text-xs font-medium text-gray-400 dark:text-gray-500 uppercase tracking-wide mb-1">
                          Detected IP
                        </p>
                        <p class="text-sm font-mono text-gray-900 dark:text-white py-2">
                          {setting.ip_address}
                        </p>
                      </div>
                      <.input
                        field={@edit_form[:external_ip]}
                        type="text"
                        label="External IP (DNS)"
                        placeholder="e.g. 203.0.113.10"
                      />
                      <.input
                        field={@edit_form[:label]}
                        type="text"
                        label="Label"
                        placeholder="e.g. Primary, Backup…"
                      />
                    </div>

                    <div class="flex items-center gap-3 pt-1">
                      <button
                        type="submit"
                        id={"save-btn-#{setting.id}"}
                        class="inline-flex items-center gap-1.5 px-4 py-2 rounded-lg bg-indigo-600 hover:bg-indigo-500 text-white text-sm font-medium transition-colors"
                      >
                        <.icon name="hero-check" class="w-4 h-4" /> Save
                      </button>
                      <button
                        type="button"
                        id={"cancel-btn-#{setting.id}"}
                        phx-click="cancel_edit"
                        class="inline-flex items-center gap-1.5 px-4 py-2 rounded-lg bg-gray-100 dark:bg-gray-800 hover:bg-gray-200 dark:hover:bg-gray-700 text-gray-700 dark:text-gray-300 text-sm font-medium transition-colors"
                      >
                        Cancel
                      </button>
                    </div>
                  </.form>
                </div>
              <% end %>
            </div>
          </div>
        </div>

        <%!-- Info box --%>
        <div class="flex items-start gap-3 p-4 rounded-xl bg-blue-50 dark:bg-blue-950/30 border border-blue-200 dark:border-blue-900">
          <.icon
            name="hero-information-circle"
            class="w-5 h-5 text-blue-500 dark:text-blue-400 shrink-0 mt-0.5"
          />
          <div class="text-sm text-blue-700 dark:text-blue-300">
            <p class="font-medium mb-0.5">How external IPs are used</p>
            <p class="text-blue-600 dark:text-blue-400">
              When creating DNS A records, the external IP for the matching server interface will be
              used as the default value. This is useful when the server sits behind NAT and has a
              different public IP than the detected interface address.
            </p>
          </div>
        </div>

        <%!-- DNS Provider Settings --%>
        <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800 overflow-hidden">
          <div class="px-6 py-4 border-b border-gray-200 dark:border-gray-800">
            <div class="flex items-center gap-3">
              <div class="flex items-center justify-center w-8 h-8 rounded-lg bg-orange-100 dark:bg-orange-900/30">
                <.icon name="hero-globe-alt" class="w-4 h-4 text-orange-600 dark:text-orange-400" />
              </div>
              <div>
                <h2 class="text-base font-semibold text-gray-900 dark:text-white">DNS Provider</h2>
                <p class="text-xs text-gray-500 dark:text-gray-400">
                  Choose how DNS records are managed — locally or via Cloudflare.
                </p>
              </div>
            </div>
          </div>

          <div class="p-6">
            <.form
              for={@dns_form}
              id="dns-provider-form"
              phx-change="validate_dns"
              phx-submit="save_dns"
              class="space-y-6"
            >
              <%!-- Provider selection cards --%>
              <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
                <label class={[
                  "relative flex items-start gap-3 p-4 rounded-xl border-2 cursor-pointer transition-all",
                  if(@dns_form[:provider].value == "local" || is_nil(@dns_form[:provider].value),
                    do:
                      "border-indigo-500 bg-indigo-50/50 dark:bg-indigo-950/20 dark:border-indigo-500",
                    else:
                      "border-gray-200 dark:border-gray-700 hover:border-gray-300 dark:hover:border-gray-600"
                  )
                ]}>
                  <input
                    type="radio"
                    name="dns_provider[provider]"
                    value="local"
                    checked={
                      @dns_form[:provider].value == "local" ||
                        is_nil(@dns_form[:provider].value)
                    }
                    class="mt-0.5 text-indigo-600"
                  />
                  <div>
                    <div class="flex items-center gap-2">
                      <.icon name="hero-server" class="w-4 h-4 text-gray-600 dark:text-gray-400" />
                      <span class="text-sm font-semibold text-gray-900 dark:text-white">
                        Local DNS
                      </span>
                    </div>
                    <p class="text-xs text-gray-500 dark:text-gray-400 mt-0.5">
                      Records are stored in the database only. Use this for manual zone file exports or bind integration.
                    </p>
                  </div>
                </label>

                <label class={[
                  "relative flex items-start gap-3 p-4 rounded-xl border-2 cursor-pointer transition-all",
                  if(@dns_form[:provider].value == "cloudflare",
                    do:
                      "border-orange-500 bg-orange-50/50 dark:bg-orange-950/20 dark:border-orange-500",
                    else:
                      "border-gray-200 dark:border-gray-700 hover:border-gray-300 dark:hover:border-gray-600"
                  )
                ]}>
                  <input
                    type="radio"
                    name="dns_provider[provider]"
                    value="cloudflare"
                    checked={@dns_form[:provider].value == "cloudflare"}
                    class="mt-0.5 text-orange-500"
                  />
                  <div>
                    <div class="flex items-center gap-2">
                      <.icon
                        name="hero-cloud"
                        class="w-4 h-4 text-orange-500 dark:text-orange-400"
                      />
                      <span class="text-sm font-semibold text-gray-900 dark:text-white">
                        Cloudflare
                      </span>
                    </div>
                    <p class="text-xs text-gray-500 dark:text-gray-400 mt-0.5">
                      Automatically sync DNS records to Cloudflare when records are created, updated, or deleted.
                    </p>
                  </div>
                </label>
              </div>

              <%!-- Cloudflare config (shown when cloudflare selected) --%>
              <%= if @dns_form[:provider].value == "cloudflare" do %>
                <div class="space-y-4 p-4 rounded-xl bg-orange-50/50 dark:bg-orange-950/20 border border-orange-200 dark:border-orange-800">
                  <div>
                    <.input
                      field={@dns_form[:cloudflare_api_token]}
                      type="password"
                      label="Cloudflare API Token"
                      placeholder="Paste your API token here"
                    />
                    <p class="mt-1.5 text-xs text-gray-500 dark:text-gray-400">
                      Create a token at
                      <span class="font-mono">dash.cloudflare.com → My Profile → API Tokens</span>
                      with <span class="font-semibold">Zone → DNS → Edit</span>
                      permission.
                    </p>
                  </div>

                  <%!-- Test connection result --%>
                  <%= if @dns_test_status != nil do %>
                    <%= if @dns_test_status == :ok do %>
                      <div class="flex items-center gap-2 text-sm text-emerald-600 dark:text-emerald-400 font-medium">
                        <.icon name="hero-check-circle" class="w-4 h-4" /> Token is valid and active.
                      </div>
                    <% else %>
                      <div class="flex items-center gap-2 text-sm text-red-600 dark:text-red-400">
                        <.icon name="hero-x-circle" class="w-4 h-4" />
                        {elem(@dns_test_status, 1)}
                      </div>
                    <% end %>
                  <% end %>
                </div>
              <% end %>

              <div class="flex items-center gap-3">
                <button
                  type="submit"
                  id="save-dns-btn"
                  class="inline-flex items-center gap-1.5 px-4 py-2 rounded-lg bg-indigo-600 hover:bg-indigo-500 text-white text-sm font-medium transition-colors"
                >
                  <.icon name="hero-check" class="w-4 h-4" /> Save DNS Settings
                </button>
                <%= if @dns_form[:provider].value == "cloudflare" do %>
                  <button
                    type="button"
                    id="test-cloudflare-btn"
                    phx-click="test_cloudflare"
                    class="inline-flex items-center gap-1.5 px-4 py-2 rounded-lg bg-orange-100 dark:bg-orange-900/30 hover:bg-orange-200 dark:hover:bg-orange-900/50 text-orange-700 dark:text-orange-400 text-sm font-medium transition-colors"
                  >
                    <.icon name="hero-beaker" class="w-4 h-4" /> Test Connection
                  </button>
                <% end %>
              </div>
            </.form>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
