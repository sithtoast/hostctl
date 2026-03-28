defmodule HostctlWeb.DomainLive.Show do
  use HostctlWeb, :live_view

  alias Hostctl.Hosting
  alias Hostctl.Hosting.Subdomain

  def mount(%{"id" => id}, _session, socket) do
    domain = Hosting.get_domain!(socket.assigns.current_scope, id)
    subdomains = Hosting.list_subdomains(domain)
    ssl_cert = Hosting.get_ssl_certificate(domain)
    cron_jobs = Hosting.list_cron_jobs(domain)
    ftp_accounts = Hosting.list_ftp_accounts(domain)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Hostctl.PubSub, "domain:#{domain.id}:ssl")
    end

    {:ok,
     socket
     |> assign(:page_title, domain.name)
     |> assign(:active_tab, :domains)
     |> assign(:domain, domain)
     |> assign(:ssl_cert, ssl_cert)
     |> assign(:active_section, :overview)
     |> stream(:subdomains, subdomains)
     |> stream(:cron_jobs, cron_jobs)
     |> stream(:ftp_accounts, ftp_accounts)
     |> assign_subdomain_form()
     |> assign_cron_form()
     |> assign_ftp_form()}
  end

  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  def handle_info({:ssl_cert_updated, cert}, socket) do
    {:noreply, assign(socket, :ssl_cert, cert)}
  end

  def handle_event("set_section", %{"section" => section}, socket) do
    {:noreply, assign(socket, :active_section, String.to_existing_atom(section))}
  end

  def handle_event("toggle_ssl", _params, socket) do
    domain = socket.assigns.domain

    case Hosting.update_domain(socket.assigns.current_scope, domain, %{
           ssl_enabled: !domain.ssl_enabled
         }) do
      {:ok, updated} ->
        {:noreply, socket |> assign(:domain, updated) |> put_flash(:info, "SSL setting updated.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not update SSL setting.")}
    end
  end

  def handle_event("request_ssl", _params, socket) do
    domain = socket.assigns.domain

    case Hosting.create_ssl_certificate(domain, %{cert_type: "lets_encrypt", status: "pending"}) do
      {:ok, cert} ->
        {:noreply,
         socket
         |> assign(:ssl_cert, cert)
         |> put_flash(:info, "SSL certificate request initiated for #{domain.name}.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not initiate SSL request.")}
    end
  end

  # Subdomain events
  def handle_event("validate_subdomain", %{"subdomain" => params}, socket) do
    form =
      %Subdomain{}
      |> Hosting.change_subdomain(params)
      |> to_form(action: :validate)

    {:noreply, assign(socket, :subdomain_form, form)}
  end

  def handle_event("save_subdomain", %{"subdomain" => params}, socket) do
    case Hosting.create_subdomain(socket.assigns.domain, params) do
      {:ok, subdomain} ->
        {:noreply,
         socket
         |> stream_insert(:subdomains, subdomain)
         |> assign_subdomain_form()
         |> put_flash(:info, "Subdomain #{subdomain.name}.#{socket.assigns.domain.name} created.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :subdomain_form, to_form(changeset))}
    end
  end

  def handle_event("delete_subdomain", %{"id" => id}, socket) do
    subdomains = Hosting.list_subdomains(socket.assigns.domain)
    subdomain = Enum.find(subdomains, &(to_string(&1.id) == id))

    if subdomain do
      {:ok, _} = Hosting.delete_subdomain(subdomain)
      {:noreply, stream_delete(socket, :subdomains, subdomain)}
    else
      {:noreply, socket}
    end
  end

  # Cron job events
  def handle_event("validate_cron", %{"cron_job" => params}, socket) do
    form =
      socket.assigns.domain
      |> Ecto.build_assoc(:cron_jobs)
      |> Hosting.change_cron_job(params)
      |> to_form(action: :validate)

    {:noreply, assign(socket, :cron_form, form)}
  end

  def handle_event("save_cron", %{"cron_job" => params}, socket) do
    case Hosting.create_cron_job(socket.assigns.domain, params) do
      {:ok, cron_job} ->
        {:noreply,
         socket
         |> stream_insert(:cron_jobs, cron_job)
         |> assign_cron_form()
         |> put_flash(:info, "Cron job created.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :cron_form, to_form(changeset))}
    end
  end

  def handle_event("delete_cron", %{"id" => id}, socket) do
    cron_jobs = Hosting.list_cron_jobs(socket.assigns.domain)
    cron_job = Enum.find(cron_jobs, &(to_string(&1.id) == id))

    if cron_job do
      {:ok, _} = Hosting.delete_cron_job(cron_job)
      {:noreply, stream_delete(socket, :cron_jobs, cron_job)}
    else
      {:noreply, socket}
    end
  end

  # FTP events
  def handle_event("validate_ftp", %{"ftp_account" => params}, socket) do
    form =
      socket.assigns.domain
      |> Ecto.build_assoc(:ftp_accounts)
      |> Hosting.change_ftp_account(params)
      |> to_form(action: :validate)

    {:noreply, assign(socket, :ftp_form, form)}
  end

  def handle_event("save_ftp", %{"ftp_account" => params}, socket) do
    case Hosting.create_ftp_account(socket.assigns.domain, params) do
      {:ok, account} ->
        {:noreply,
         socket
         |> stream_insert(:ftp_accounts, account)
         |> assign_ftp_form()
         |> put_flash(:info, "FTP account #{account.username} created.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :ftp_form, to_form(changeset))}
    end
  end

  def handle_event("delete_ftp", %{"id" => id}, socket) do
    ftp_accounts = Hosting.list_ftp_accounts(socket.assigns.domain)
    account = Enum.find(ftp_accounts, &(to_string(&1.id) == id))

    if account do
      {:ok, _} = Hosting.delete_ftp_account(account)
      {:noreply, stream_delete(socket, :ftp_accounts, account)}
    else
      {:noreply, socket}
    end
  end

  defp assign_subdomain_form(socket) do
    assign(socket, :subdomain_form, to_form(Hosting.change_subdomain(%Subdomain{})))
  end

  defp assign_cron_form(socket) do
    assign(socket, :cron_form, to_form(Hosting.change_cron_job(%Hostctl.Hosting.CronJob{})))
  end

  defp assign_ftp_form(socket) do
    assign(socket, :ftp_form, to_form(Hosting.change_ftp_account(%Hostctl.Hosting.FtpAccount{})))
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_tab={@active_tab}>
      <div class="space-y-6">
        <%!-- Header --%>
        <div class="flex items-center gap-4">
          <.link
            navigate={~p"/domains"}
            class="text-gray-400 hover:text-gray-600 dark:hover:text-gray-200"
          >
            <.icon name="hero-arrow-left" class="w-5 h-5" />
          </.link>
          <div class="flex-1">
            <div class="flex items-center gap-3">
              <h1 class="text-2xl font-bold text-gray-900 dark:text-white">{@domain.name}</h1>
              <span class={[
                "inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium",
                cond do
                  @domain.status == "active" ->
                    "bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400"

                  @domain.status == "suspended" ->
                    "bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-400"

                  true ->
                    "bg-yellow-100 text-yellow-700 dark:bg-yellow-900/30 dark:text-yellow-400"
                end
              ]}>
                {@domain.status}
              </span>
            </div>
            <p class="mt-0.5 text-sm text-gray-500 dark:text-gray-400">
              PHP {@domain.php_version} &middot; {if @domain.document_root,
                do: @domain.document_root,
                else: "Default root"}
            </p>
          </div>
        </div>

        <%!-- Section tabs --%>
        <div class="flex gap-1 p-1 bg-gray-100 dark:bg-gray-800 rounded-lg w-fit">
          <%= for {label, section, icon} <- [
            {"Overview", :overview, "hero-home"},
            {"Subdomains", :subdomains, "hero-link"},
            {"DNS", :dns, "hero-server"},
            {"SSL", :ssl, "hero-lock-closed"},
            {"Cron Jobs", :cron, "hero-clock"},
            {"FTP", :ftp, "hero-folder"}
          ] do %>
            <button
              phx-click="set_section"
              phx-value-section={section}
              class={[
                "flex items-center gap-1.5 px-3 py-1.5 rounded-md text-sm font-medium transition-colors",
                if(@active_section == section,
                  do: "bg-white dark:bg-gray-700 text-gray-900 dark:text-white shadow-sm",
                  else: "text-gray-600 dark:text-gray-400 hover:text-gray-900 dark:hover:text-white"
                )
              ]}
            >
              <.icon name={icon} class="w-3.5 h-3.5" />
              {label}
            </button>
          <% end %>
        </div>

        <%!-- Overview --%>
        <%= if @active_section == :overview do %>
          <div class="grid grid-cols-1 gap-4 sm:grid-cols-3">
            <.info_card
              label="Document Root"
              value={@domain.document_root || "Not set"}
              icon="hero-folder"
            />
            <.info_card
              label="PHP Version"
              value={"PHP #{@domain.php_version}"}
              icon="hero-code-bracket"
            />
            <.info_card
              label="SSL Certificate"
              value={if @domain.ssl_enabled, do: "Active", else: "Disabled"}
              icon="hero-lock-closed"
            />
          </div>

          <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800 p-6">
            <h3 class="text-base font-semibold text-gray-900 dark:text-white mb-4">Quick Actions</h3>
            <div class="grid grid-cols-2 gap-3 sm:grid-cols-4">
              <button
                phx-click="set_section"
                phx-value-section="dns"
                class="flex flex-col items-center gap-2 p-4 rounded-lg border border-gray-200 dark:border-gray-700 hover:border-indigo-300 dark:hover:border-indigo-700 hover:bg-indigo-50 dark:hover:bg-indigo-950/30 transition-colors"
              >
                <.icon name="hero-server" class="w-5 h-5 text-gray-500 dark:text-gray-400" />
                <span class="text-xs font-medium text-gray-700 dark:text-gray-300">Manage DNS</span>
              </button>
              <.link
                navigate={~p"/email"}
                class="flex flex-col items-center gap-2 p-4 rounded-lg border border-gray-200 dark:border-gray-700 hover:border-indigo-300 dark:hover:border-indigo-700 hover:bg-indigo-50 dark:hover:bg-indigo-950/30 transition-colors"
              >
                <.icon name="hero-envelope" class="w-5 h-5 text-gray-500 dark:text-gray-400" />
                <span class="text-xs font-medium text-gray-700 dark:text-gray-300">
                  Email Accounts
                </span>
              </.link>
              <.link
                navigate={~p"/databases"}
                class="flex flex-col items-center gap-2 p-4 rounded-lg border border-gray-200 dark:border-gray-700 hover:border-indigo-300 dark:hover:border-indigo-700 hover:bg-indigo-50 dark:hover:bg-indigo-950/30 transition-colors"
              >
                <.icon name="hero-circle-stack" class="w-5 h-5 text-gray-500 dark:text-gray-400" />
                <span class="text-xs font-medium text-gray-700 dark:text-gray-300">Databases</span>
              </.link>
              <button
                phx-click="set_section"
                phx-value-section="ssl"
                class="flex flex-col items-center gap-2 p-4 rounded-lg border border-gray-200 dark:border-gray-700 hover:border-indigo-300 dark:hover:border-indigo-700 hover:bg-indigo-50 dark:hover:bg-indigo-950/30 transition-colors"
              >
                <.icon name="hero-lock-closed" class="w-5 h-5 text-gray-500 dark:text-gray-400" />
                <span class="text-xs font-medium text-gray-700 dark:text-gray-300">
                  SSL Certificate
                </span>
              </button>
            </div>
          </div>
        <% end %>

        <%!-- Subdomains --%>
        <%= if @active_section == :subdomains do %>
          <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800">
            <div class="px-6 py-4 border-b border-gray-200 dark:border-gray-800">
              <h3 class="text-base font-semibold text-gray-900 dark:text-white">Subdomains</h3>
            </div>
            <div class="p-6 border-b border-gray-200 dark:border-gray-800">
              <.form
                for={@subdomain_form}
                id="subdomain-form"
                phx-change="validate_subdomain"
                phx-submit="save_subdomain"
                class="flex gap-3"
              >
                <div class="flex-1">
                  <.input
                    field={@subdomain_form[:name]}
                    type="text"
                    placeholder="www"
                    label="Subdomain name"
                  />
                </div>
                <div class="flex-1">
                  <.input
                    field={@subdomain_form[:document_root]}
                    type="text"
                    placeholder="/var/www/sub"
                    label="Document root (optional)"
                  />
                </div>
                <div class="flex items-end pb-0.5">
                  <button
                    type="submit"
                    class="px-4 py-2 bg-indigo-600 hover:bg-indigo-700 text-white text-sm font-medium rounded-lg transition-colors whitespace-nowrap"
                  >
                    Add Subdomain
                  </button>
                </div>
              </.form>
            </div>
            <div
              id="subdomains"
              phx-update="stream"
              class="divide-y divide-gray-100 dark:divide-gray-800"
            >
              <div class="hidden only:flex items-center justify-center py-10 text-sm text-gray-400">
                No subdomains yet.
              </div>
              <div
                :for={{id, sub} <- @streams.subdomains}
                id={id}
                class="flex items-center justify-between px-6 py-3"
              >
                <div>
                  <p class="text-sm font-medium text-gray-900 dark:text-white">
                    {sub.name}.{@domain.name}
                  </p>
                  <p class="text-xs text-gray-500">{sub.document_root || "Default"}</p>
                </div>
                <button
                  phx-click="delete_subdomain"
                  phx-value-id={sub.id}
                  data-confirm="Delete this subdomain?"
                  class="text-xs text-red-500 hover:text-red-600"
                >
                  Delete
                </button>
              </div>
            </div>
          </div>
        <% end %>

        <%!-- DNS --%>
        <%= if @active_section == :dns do %>
          <.link
            navigate={~p"/domains/#{@domain.id}/dns"}
            class="inline-flex items-center gap-2 px-4 py-2 bg-indigo-600 hover:bg-indigo-700 text-white text-sm font-medium rounded-lg transition-colors"
          >
            <.icon name="hero-arrow-right" class="w-4 h-4" /> Open DNS Manager
          </.link>
        <% end %>

        <%!-- SSL --%>
        <%= if @active_section == :ssl do %>
          <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800 p-6">
            <h3 class="text-base font-semibold text-gray-900 dark:text-white mb-4">
              SSL Certificate
            </h3>
            <%= if @ssl_cert do %>
              <div class="space-y-3">
                <div class="flex items-center gap-3">
                  <div class={[
                    "flex items-center justify-center w-10 h-10 rounded-lg",
                    if(@ssl_cert.status == "active",
                      do: "bg-green-100 dark:bg-green-900/30",
                      else: "bg-yellow-100 dark:bg-yellow-900/30"
                    )
                  ]}>
                    <%= if @ssl_cert.status == "active" do %>
                      <.icon
                        name="hero-lock-closed"
                        class="w-5 h-5 text-green-600 dark:text-green-400"
                      />
                    <% else %>
                      <.icon
                        name="hero-arrow-path"
                        class="w-5 h-5 text-yellow-600 dark:text-yellow-400 animate-spin"
                      />
                    <% end %>
                  </div>
                  <div>
                    <p class="text-sm font-medium text-gray-900 dark:text-white capitalize">
                      {@ssl_cert.cert_type} certificate
                    </p>
                    <p class={[
                      "text-xs capitalize",
                      if(@ssl_cert.status == "active",
                        do: "text-green-600 dark:text-green-400",
                        else: "text-yellow-600 dark:text-yellow-400"
                      )
                    ]}>
                      {@ssl_cert.status}
                      <%= if @ssl_cert.status == "pending" do %>
                        – issuing certificate, this may take a minute…
                      <% end %>
                    </p>
                  </div>
                </div>
                <%= if @ssl_cert.expires_at do %>
                  <p class="text-sm text-gray-600 dark:text-gray-400">
                    Expires: {Calendar.strftime(@ssl_cert.expires_at, "%B %d, %Y")}
                  </p>
                <% end %>
              </div>
            <% else %>
              <div class="text-center py-6">
                <.icon
                  name="hero-lock-open"
                  class="w-10 h-10 text-gray-300 dark:text-gray-600 mx-auto mb-3"
                />
                <p class="text-sm font-medium text-gray-900 dark:text-white">No SSL certificate</p>
                <p class="text-sm text-gray-500 dark:text-gray-400 mb-4">
                  Secure your domain with a free Let's Encrypt certificate
                </p>
                <button
                  phx-click="request_ssl"
                  class="inline-flex items-center gap-2 px-4 py-2 bg-green-600 hover:bg-green-700 text-white text-sm font-medium rounded-lg transition-colors"
                >
                  <.icon name="hero-lock-closed" class="w-4 h-4" /> Request Free SSL
                </button>
              </div>
            <% end %>
          </div>
        <% end %>

        <%!-- Cron Jobs --%>
        <%= if @active_section == :cron do %>
          <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800">
            <div class="px-6 py-4 border-b border-gray-200 dark:border-gray-800">
              <h3 class="text-base font-semibold text-gray-900 dark:text-white">Cron Jobs</h3>
            </div>
            <div class="p-6 border-b border-gray-200 dark:border-gray-800">
              <.form
                for={@cron_form}
                id="cron-form"
                phx-change="validate_cron"
                phx-submit="save_cron"
                class="grid grid-cols-1 gap-3 sm:grid-cols-3"
              >
                <.input
                  field={@cron_form[:schedule]}
                  type="text"
                  placeholder="* * * * *"
                  label="Schedule (cron)"
                />
                <div class="sm:col-span-2">
                  <.input
                    field={@cron_form[:command]}
                    type="text"
                    placeholder="/usr/bin/php /var/www/artisan schedule:run"
                    label="Command"
                  />
                </div>
                <div class="sm:col-span-3 flex justify-end">
                  <button
                    type="submit"
                    class="px-4 py-2 bg-indigo-600 hover:bg-indigo-700 text-white text-sm font-medium rounded-lg transition-colors"
                  >
                    Add Cron Job
                  </button>
                </div>
              </.form>
            </div>
            <div
              id="cron-jobs"
              phx-update="stream"
              class="divide-y divide-gray-100 dark:divide-gray-800"
            >
              <div class="hidden only:flex items-center justify-center py-10 text-sm text-gray-400">
                No cron jobs yet.
              </div>
              <div
                :for={{id, job} <- @streams.cron_jobs}
                id={id}
                class="flex items-center justify-between px-6 py-3"
              >
                <div class="flex items-center gap-4">
                  <span class="font-mono text-xs px-2 py-1 bg-gray-100 dark:bg-gray-800 rounded text-gray-600 dark:text-gray-300">
                    {job.schedule}
                  </span>
                  <p class="text-sm text-gray-900 dark:text-white font-mono">{job.command}</p>
                </div>
                <button
                  phx-click="delete_cron"
                  phx-value-id={job.id}
                  data-confirm="Delete this cron job?"
                  class="text-xs text-red-500 hover:text-red-600"
                >
                  Delete
                </button>
              </div>
            </div>
          </div>
        <% end %>

        <%!-- FTP --%>
        <%= if @active_section == :ftp do %>
          <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800">
            <div class="px-6 py-4 border-b border-gray-200 dark:border-gray-800">
              <h3 class="text-base font-semibold text-gray-900 dark:text-white">FTP Accounts</h3>
            </div>
            <div class="p-6 border-b border-gray-200 dark:border-gray-800">
              <.form
                for={@ftp_form}
                id="ftp-form"
                phx-change="validate_ftp"
                phx-submit="save_ftp"
                class="grid grid-cols-1 gap-3 sm:grid-cols-3"
              >
                <.input
                  field={@ftp_form[:username]}
                  type="text"
                  placeholder="ftpuser"
                  label="Username"
                />
                <.input field={@ftp_form[:password]} type="password" label="Password" />
                <.input
                  field={@ftp_form[:home_dir]}
                  type="text"
                  placeholder="/var/www"
                  label="Home directory"
                />
                <div class="sm:col-span-3 flex justify-end">
                  <button
                    type="submit"
                    class="px-4 py-2 bg-indigo-600 hover:bg-indigo-700 text-white text-sm font-medium rounded-lg transition-colors"
                  >
                    Create FTP Account
                  </button>
                </div>
              </.form>
            </div>
            <div
              id="ftp-accounts"
              phx-update="stream"
              class="divide-y divide-gray-100 dark:divide-gray-800"
            >
              <div class="hidden only:flex items-center justify-center py-10 text-sm text-gray-400">
                No FTP accounts yet.
              </div>
              <div
                :for={{id, account} <- @streams.ftp_accounts}
                id={id}
                class="flex items-center justify-between px-6 py-3"
              >
                <div>
                  <p class="text-sm font-medium text-gray-900 dark:text-white">{account.username}</p>
                  <p class="text-xs text-gray-500">{account.home_dir || "/"}</p>
                </div>
                <div class="flex items-center gap-3">
                  <span class={[
                    "inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium",
                    if(account.status == "active",
                      do: "bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400",
                      else: "bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-400"
                    )
                  ]}>
                    {account.status}
                  </span>
                  <button
                    phx-click="delete_ftp"
                    phx-value-id={account.id}
                    data-confirm="Delete this FTP account?"
                    class="text-xs text-red-500 hover:text-red-600"
                  >
                    Delete
                  </button>
                </div>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :icon, :string, required: true

  defp info_card(assigns) do
    ~H"""
    <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800 p-5">
      <div class="flex items-center gap-3">
        <div class="flex items-center justify-center w-9 h-9 rounded-lg bg-gray-100 dark:bg-gray-800 shrink-0">
          <.icon name={@icon} class="w-4 h-4 text-gray-500 dark:text-gray-400" />
        </div>
        <div>
          <p class="text-xs text-gray-500 dark:text-gray-400">{@label}</p>
          <p class="text-sm font-semibold text-gray-900 dark:text-white">{@value}</p>
        </div>
      </div>
    </div>
    """
  end
end
