defmodule HostctlWeb.PanelLive.Smarthost do
  use HostctlWeb, :live_view

  alias Hostctl.Settings
  alias Hostctl.Settings.SmarthostSetting
  alias Hostctl.MailServer
  alias Hostctl.MailgunClient

  @impl true
  def mount(_params, _session, socket) do
    setting = Settings.get_smarthost_setting()
    form = to_form(Settings.change_smarthost_setting(setting), as: :smarthost)
    email_installed? = Settings.feature_enabled?("email")

    {:ok,
     socket
     |> assign(:page_title, "Smarthost")
     |> assign(:active_tab, :panel_smarthost)
     |> assign(:setting, setting)
     |> assign(:form, form)
     |> assign(:email_installed?, email_installed?)
     |> assign(:apply_status, nil)
     |> assign(:show_password, false)
     |> assign(:mg_key, "")
     |> assign(:mg_region, "us")
     |> assign(:mg_domains, nil)
     |> assign(:mg_domain, nil)
     |> assign(:mg_status, nil)}
  end

  @impl true
  def handle_event("validate", %{"smarthost" => params}, socket) do
    form =
      %SmarthostSetting{}
      |> Settings.change_smarthost_setting(params)
      |> to_form(action: :validate, as: :smarthost)

    {:noreply, assign(socket, :form, form)}
  end

  @impl true
  def handle_event("submit", %{"action" => "apply", "smarthost" => params}, socket) do
    case Settings.save_smarthost_setting(params) do
      {:ok, updated} ->
        form = to_form(Settings.change_smarthost_setting(updated), as: :smarthost)

        apply_status =
          if socket.assigns.email_installed? do
            case MailServer.apply_smarthost(updated) do
              :ok -> :ok
              {:error, reason} -> {:error, inspect(reason)}
            end
          else
            :not_applied
          end

        {:noreply,
         socket
         |> assign(:setting, updated)
         |> assign(:form, form)
         |> assign(:apply_status, apply_status)}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :smarthost))}
    end
  end

  @impl true
  def handle_event("submit", %{"smarthost" => params}, socket) do
    case Settings.save_smarthost_setting(params) do
      {:ok, updated} ->
        form = to_form(Settings.change_smarthost_setting(updated), as: :smarthost)

        {:noreply,
         socket
         |> assign(:setting, updated)
         |> assign(:form, form)
         |> assign(:apply_status, nil)
         |> put_flash(:info, "Smarthost settings saved.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :smarthost))}
    end
  end

  @impl true
  def handle_event("toggle_password", _, socket) do
    {:noreply, assign(socket, :show_password, !socket.assigns.show_password)}
  end

  @impl true
  def handle_event("fetch_mailgun_domains", %{"mg_key" => api_key, "mg_region" => region}, socket) do
    case MailgunClient.list_domains(api_key) do
      {:ok, domains} ->
        {:noreply,
         socket
         |> assign(:mg_key, api_key)
         |> assign(:mg_region, region)
         |> assign(:mg_domains, domains)
         |> assign(:mg_domain, if(domains != [], do: hd(domains).name, else: nil))
         |> assign(
           :mg_status,
           if(domains == [], do: {:error, "No domains found on this Mailgun account."}, else: nil)
         )}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:mg_key, api_key)
         |> assign(:mg_region, region)
         |> assign(:mg_status, {:error, reason})}
    end
  end

  @impl true
  def handle_event("configure_mailgun", %{"domain" => domain_name}, socket) do
    api_key = socket.assigns.mg_key
    region = if socket.assigns.mg_region == "eu", do: :eu, else: :us

    case MailgunClient.create_smtp_credential(api_key, domain_name, region) do
      {:ok, %{login: login, password: password}} ->
        smtp_host =
          if region == :eu, do: "[smtp.eu.mailgun.org]", else: "[smtp.mailgun.org]"

        prefilled = %{
          "enabled" => "true",
          "host" => smtp_host,
          "port" => "587",
          "auth_required" => "true",
          "username" => login,
          "password" => password
        }

        form =
          to_form(Settings.change_smarthost_setting(socket.assigns.setting, prefilled),
            as: :smarthost
          )

        {:noreply,
         socket
         |> assign(:form, form)
         |> assign(:mg_domain, domain_name)
         |> assign(:mg_status, :ok)}

      {:error, reason} ->
        {:noreply, assign(socket, :mg_status, {:error, reason})}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_tab={@active_tab}>
      <div class="max-w-2xl mx-auto space-y-6">
        <%!-- Header --%>
        <div>
          <h1 class="text-2xl font-bold text-gray-900 dark:text-white">Smarthost</h1>
          <p class="mt-1 text-sm text-gray-500 dark:text-gray-400">
            Route all outbound mail through an external SMTP relay service such as Mailgun,
            SendGrid, or Mailjet to improve deliverability.
          </p>
        </div>

        <%!-- Email feature warning --%>
        <%= if !@email_installed? do %>
          <div class="flex gap-3 p-4 rounded-xl bg-amber-50 dark:bg-amber-950/30 border border-amber-200 dark:border-amber-800">
            <.icon
              name="hero-exclamation-triangle"
              class="w-5 h-5 text-amber-600 dark:text-amber-400 shrink-0 mt-0.5"
            />
            <div>
              <p class="text-sm font-medium text-amber-800 dark:text-amber-300">
                Email Server not installed
              </p>
              <p class="mt-0.5 text-sm text-amber-700 dark:text-amber-400">
                Settings saved here will be applied automatically when the Email Server feature
                is installed from the
                <.link navigate="/panel/features" class="underline font-medium">Features</.link>
                page.
              </p>
            </div>
          </div>
        <% end %>

        <%!-- Apply status banner --%>
        <%= if @apply_status do %>
          <%= cond do %>
            <% @apply_status == :ok -> %>
              <div class="flex gap-3 p-4 rounded-xl bg-emerald-50 dark:bg-emerald-950/30 border border-emerald-200 dark:border-emerald-800">
                <.icon
                  name="hero-check-circle"
                  class="w-5 h-5 text-emerald-600 dark:text-emerald-400 shrink-0 mt-0.5"
                />
                <p class="text-sm font-medium text-emerald-800 dark:text-emerald-300">
                  Postfix configuration applied and reloaded successfully.
                </p>
              </div>
            <% @apply_status == :not_applied -> %>
              <div class="flex gap-3 p-4 rounded-xl bg-blue-50 dark:bg-blue-950/30 border border-blue-200 dark:border-blue-800">
                <.icon
                  name="hero-information-circle"
                  class="w-5 h-5 text-blue-600 dark:text-blue-400 shrink-0 mt-0.5"
                />
                <p class="text-sm text-blue-800 dark:text-blue-300">
                  Settings saved. Postfix configuration will be applied when the Email Server is installed.
                </p>
              </div>
            <% match?({:error, _}, @apply_status) -> %>
              <div class="flex gap-3 p-4 rounded-xl bg-red-50 dark:bg-red-950/30 border border-red-200 dark:border-red-800">
                <.icon
                  name="hero-x-circle"
                  class="w-5 h-5 text-red-600 dark:text-red-400 shrink-0 mt-0.5"
                />
                <div>
                  <p class="text-sm font-medium text-red-800 dark:text-red-300">
                    Failed to apply Postfix configuration.
                  </p>
                  <p class="mt-0.5 text-xs text-red-700 dark:text-red-400 font-mono">
                    {elem(@apply_status, 1)}
                  </p>
                </div>
              </div>
          <% end %>
        <% end %>

        <%!-- Mailgun quick setup card --%>
        <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800">
          <div class="px-6 py-4 border-b border-gray-200 dark:border-gray-800 flex items-center gap-2">
            <.icon name="hero-bolt" class="w-4 h-4 text-purple-500" />
            <h2 class="text-base font-semibold text-gray-900 dark:text-white">
              Quick Setup with Mailgun
            </h2>
          </div>
          <div class="p-6 space-y-4">
            <p class="text-sm text-gray-500 dark:text-gray-400">
              Connect your Mailgun account to automatically create SMTP credentials
              and pre-fill the relay configuration below.
            </p>

            <%!-- Step 1: enter API key and fetch domains --%>
            <form id="mg-fetch-form" phx-submit="fetch_mailgun_domains" class="flex flex-wrap gap-2">
              <input
                type="password"
                name="mg_key"
                placeholder="Mailgun Private API key (key-...)"
                autocomplete="off"
                class="flex-1 min-w-0 px-3 py-2 text-sm bg-gray-50 dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg focus:ring-2 focus:ring-indigo-400 focus:outline-none text-gray-900 dark:text-white placeholder-gray-400"
              />
              <select
                name="mg_region"
                class="px-3 py-2 text-sm bg-gray-50 dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg focus:ring-2 focus:ring-indigo-400 focus:outline-none text-gray-900 dark:text-white"
              >
                <option value="us" selected>US region</option>
                <option value="eu">EU region</option>
              </select>
              <button
                type="submit"
                id="mg-fetch-btn"
                class="inline-flex items-center gap-1.5 px-4 py-2 rounded-lg bg-gray-100 dark:bg-gray-700 hover:bg-gray-200 dark:hover:bg-gray-600 text-gray-900 dark:text-white text-sm font-medium transition-colors"
              >
                <.icon name="hero-magnifying-glass" class="w-4 h-4" /> Find my domains
              </button>
            </form>

            <%!-- Step 2: domain list (shown after fetch) --%>
            <%= if @mg_domains && @mg_domains != [] do %>
              <div class="space-y-2">
                <p class="text-xs font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wide">
                  Select a domain — clicking it creates SMTP credentials and pre-fills the form:
                </p>
                <div class="grid grid-cols-1 sm:grid-cols-2 gap-2">
                  <%= for mg_d <- @mg_domains do %>
                    <button
                      type="button"
                      id={"mg-domain-#{mg_d.name}"}
                      phx-click="configure_mailgun"
                      phx-value-domain={mg_d.name}
                      class={[
                        "flex items-center justify-between px-4 py-3 rounded-lg border text-left transition-colors",
                        if(@mg_domain == mg_d.name && @mg_status == :ok,
                          do:
                            "border-indigo-500 bg-indigo-50 dark:bg-indigo-950/30 text-indigo-900 dark:text-indigo-100",
                          else:
                            "border-gray-200 dark:border-gray-700 hover:border-indigo-300 dark:hover:border-indigo-600 text-gray-900 dark:text-white"
                        )
                      ]}
                    >
                      <div>
                        <p class="text-sm font-medium">{mg_d.name}</p>
                        <p class="text-xs text-gray-500 dark:text-gray-400">{mg_d.smtp_login}</p>
                      </div>
                      <span class={[
                        "text-xs px-2 py-0.5 rounded-full font-medium",
                        if(mg_d.state == "active",
                          do: "bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400",
                          else: "bg-amber-100 text-amber-700 dark:bg-amber-900/30 dark:text-amber-400"
                        )
                      ]}>
                        {mg_d.state}
                      </span>
                    </button>
                  <% end %>
                </div>
              </div>
            <% end %>

            <%!-- Status feedback --%>
            <%= if @mg_status do %>
              <%= cond do %>
                <% @mg_status == :ok -> %>
                  <div class="flex items-center gap-2 p-3 rounded-lg bg-emerald-50 dark:bg-emerald-950/30 border border-emerald-200 dark:border-emerald-800">
                    <.icon
                      name="hero-check-circle"
                      class="w-4 h-4 text-emerald-600 dark:text-emerald-400 shrink-0"
                    />
                    <p class="text-sm text-emerald-800 dark:text-emerald-300">
                      SMTP credentials created for <strong>{@mg_domain}</strong>. The form below has been pre-filled — review and save.
                    </p>
                  </div>
                <% match?({:error, _}, @mg_status) -> %>
                  <div class="flex items-center gap-2 p-3 rounded-lg bg-red-50 dark:bg-red-950/30 border border-red-200 dark:border-red-800">
                    <.icon
                      name="hero-x-circle"
                      class="w-4 h-4 text-red-600 dark:text-red-400 shrink-0"
                    />
                    <p class="text-sm text-red-800 dark:text-red-300">{elem(@mg_status, 1)}</p>
                  </div>
              <% end %>
            <% end %>
          </div>
        </div>

        <%!-- Settings card --%>
        <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800">
          <div class="px-6 py-4 border-b border-gray-200 dark:border-gray-800">
            <h2 class="text-base font-semibold text-gray-900 dark:text-white">
              Relay Configuration
            </h2>
          </div>

          <.form
            for={@form}
            id="smarthost-form"
            phx-change="validate"
            phx-submit="submit"
            class="p-6 space-y-5"
          >
            <%!-- Enable toggle --%>
            <div class="flex items-center justify-between">
              <div>
                <p class="text-sm font-medium text-gray-900 dark:text-white">Enable smarthost</p>
                <p class="text-xs text-gray-500 dark:text-gray-400 mt-0.5">
                  Route all outbound mail through the configured relay
                </p>
              </div>
              <label class="relative inline-flex items-center cursor-pointer">
                <input type="hidden" name={@form[:enabled].name} value="false" />
                <input
                  type="checkbox"
                  id={@form[:enabled].id}
                  name={@form[:enabled].name}
                  value="true"
                  checked={Phoenix.HTML.Form.normalize_value("checkbox", @form[:enabled].value)}
                  class="sr-only peer"
                />
                <div class="w-11 h-6 bg-gray-200 dark:bg-gray-700 peer-focus:outline-none peer-focus:ring-2 peer-focus:ring-indigo-400 rounded-full peer peer-checked:bg-indigo-600 after:content-[''] after:absolute after:top-[2px] after:left-[2px] after:bg-white after:rounded-full after:h-5 after:w-5 after:transition-all peer-checked:after:translate-x-5">
                </div>
              </label>
            </div>

            <%!-- Host & Port --%>
            <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
              <div class="sm:col-span-2">
                <.input
                  field={@form[:host]}
                  type="text"
                  label="SMTP relay hostname"
                  placeholder="[smtp.sendgrid.net]"
                />
                <p class="mt-1 text-xs text-gray-400 dark:text-gray-500">
                  Wrap in <code class="font-mono">[brackets]</code> to skip MX lookups (recommended)
                </p>
              </div>
              <.input field={@form[:port]} type="number" label="Port" placeholder="587" />
            </div>

            <%!-- Auth required toggle --%>
            <div class="flex items-center justify-between py-3 border-t border-gray-100 dark:border-gray-800">
              <div>
                <p class="text-sm font-medium text-gray-900 dark:text-white">
                  Authentication required
                </p>
                <p class="text-xs text-gray-500 dark:text-gray-400 mt-0.5">
                  Most SMTP relay services require credentials
                </p>
              </div>
              <label class="relative inline-flex items-center cursor-pointer">
                <input type="hidden" name={@form[:auth_required].name} value="false" />
                <input
                  type="checkbox"
                  id={@form[:auth_required].id}
                  name={@form[:auth_required].name}
                  value="true"
                  checked={Phoenix.HTML.Form.normalize_value("checkbox", @form[:auth_required].value)}
                  class="sr-only peer"
                />
                <div class="w-11 h-6 bg-gray-200 dark:bg-gray-700 peer-focus:outline-none peer-focus:ring-2 peer-focus:ring-indigo-400 rounded-full peer peer-checked:bg-indigo-600 after:content-[''] after:absolute after:top-[2px] after:left-[2px] after:bg-white after:rounded-full after:h-5 after:w-5 after:transition-all peer-checked:after:translate-x-5">
                </div>
              </label>
            </div>

            <%!-- Credentials (shown when auth_required) --%>
            <%= if Phoenix.HTML.Form.normalize_value("checkbox", @form[:auth_required].value) do %>
              <div class="space-y-4 pt-1">
                <.input
                  field={@form[:username]}
                  type="text"
                  label="Username"
                  placeholder="e.g. apikey (SendGrid) or postmaster@yourdomain.com (Mailgun)"
                  autocomplete="off"
                />
                <div>
                  <.input
                    field={@form[:password]}
                    type={if @show_password, do: "text", else: "password"}
                    label="Password / API key"
                    placeholder="Paste your SMTP password or API key"
                    autocomplete="new-password"
                  />
                  <button
                    type="button"
                    id="toggle-password-btn"
                    phx-click="toggle_password"
                    class="mt-1 text-xs text-indigo-600 dark:text-indigo-400 hover:underline"
                  >
                    {if @show_password, do: "Hide", else: "Show"} password
                  </button>
                </div>
              </div>
            <% end %>

            <%!-- Actions --%>
            <div class="flex items-center gap-3 pt-2 border-t border-gray-100 dark:border-gray-800">
              <button
                type="submit"
                id="save-btn"
                name="action"
                value="save"
                class="inline-flex items-center gap-1.5 px-4 py-2 rounded-lg bg-gray-100 dark:bg-gray-800 hover:bg-gray-200 dark:hover:bg-gray-700 text-gray-900 dark:text-white text-sm font-medium transition-colors"
              >
                <.icon name="hero-check" class="w-4 h-4" /> Save
              </button>
              <button
                type="submit"
                id="save-apply-btn"
                name="action"
                value="apply"
                class="inline-flex items-center gap-1.5 px-4 py-2 rounded-lg bg-indigo-600 hover:bg-indigo-500 text-white text-sm font-medium transition-colors"
              >
                <.icon name="hero-bolt" class="w-4 h-4" /> Save & Apply
              </button>
            </div>
          </.form>
        </div>

        <%!-- Common providers reference card --%>
        <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800 p-6">
          <h3 class="text-sm font-semibold text-gray-900 dark:text-white mb-3">
            Common relay providers
          </h3>
          <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
            <div class="space-y-1">
              <p class="text-sm font-medium text-gray-700 dark:text-gray-300">SendGrid</p>
              <p class="text-xs text-gray-500 dark:text-gray-400 font-mono">
                [smtp.sendgrid.net]:587
              </p>
              <p class="text-xs text-gray-500 dark:text-gray-400">
                Username: <code class="font-mono">apikey</code>
              </p>
            </div>
            <div class="space-y-1">
              <p class="text-sm font-medium text-gray-700 dark:text-gray-300">Mailgun (US)</p>
              <p class="text-xs text-gray-500 dark:text-gray-400 font-mono">
                [smtp.mailgun.org]:587
              </p>
              <p class="text-xs text-gray-500 dark:text-gray-400">
                SMTP credentials from Mailgun dashboard
              </p>
            </div>
            <div class="space-y-1">
              <p class="text-sm font-medium text-gray-700 dark:text-gray-300">Mailjet</p>
              <p class="text-xs text-gray-500 dark:text-gray-400 font-mono">
                [in-v3.mailjet.com]:587
              </p>
              <p class="text-xs text-gray-500 dark:text-gray-400">
                API key / Secret key pair
              </p>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
