defmodule HostctlWeb.DomainLive.Show do
  use HostctlWeb, :live_view

  alias Hostctl.Hosting
  alias Hostctl.Hosting.{SslCertificate, Subdomain}
  alias Hostctl.Settings
  alias Hostctl.WebServer
  alias Hostctl.MailServer

  def mount(%{"id" => id}, _session, socket) do
    domain = Hosting.get_domain!(socket.assigns.current_scope, id)
    subdomains = Hosting.list_subdomains(domain)
    ssl_cert = Hosting.get_ssl_certificate(domain)
    cron_jobs = Hosting.list_cron_jobs(domain)
    ftp_accounts = Hosting.list_ftp_accounts(domain)

    # If an active cert exists but ssl_enabled is still false (e.g. cert was
    # provisioned before the auto-enable logic was added), fix it now.
    domain =
      if ssl_cert && ssl_cert.status == "active" && !domain.ssl_enabled do
        case Hosting.update_domain(socket.assigns.current_scope, domain, %{ssl_enabled: true}) do
          {:ok, updated} -> updated
          _ -> domain
        end
      else
        domain
      end

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Hostctl.PubSub, "domain:#{domain.id}:ssl")
    end

    # Pre-populate log lines from any previously persisted log
    existing_log_lines =
      if ssl_cert && ssl_cert.log do
        ssl_cert.log
        |> String.split("\n")
        |> Enum.with_index()
        |> Enum.map(fn {line, idx} -> %{id: idx, text: line} end)
      else
        []
      end

    # Build home directory options from the domain's document_root
    domain_root = Path.dirname(domain.document_root)

    ftp_home_options =
      [
        {domain_root, domain_root},
        {domain.document_root, domain.document_root}
      ]

    {:ok,
     socket
     |> stream(:ssl_log_lines, existing_log_lines)
     |> assign(:page_title, domain.name)
     |> assign(:active_tab, :domains)
     |> assign(:domain, domain)
     |> assign(:ssl_cert, ssl_cert)
     |> assign(:active_section, :overview)
     |> assign(:editing_ftp_id, nil)
     |> assign(:ftp_edit_form, nil)
     |> assign(:ftp_home_options, ftp_home_options)
     |> stream(:subdomains, subdomains)
     |> stream(:cron_jobs, cron_jobs)
     |> stream(:ftp_accounts, ftp_accounts)
     |> assign_ssl_form()
     |> assign_subdomain_form()
     |> assign_cron_form()
     |> assign_ftp_form()
     |> assign_smarthost_form()}
  end

  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  def handle_info({:ssl_cert_updated, cert}, socket) do
    # Reload domain too so ssl_enabled toggle reflects any auto-update
    domain = Hosting.get_domain!(socket.assigns.current_scope, cert.domain_id)
    {:noreply, socket |> assign(:ssl_cert, cert) |> assign(:domain, domain)}
  end

  def handle_info({:ssl_log, line}, socket) do
    idx = socket.assigns[:ssl_log_counter] || 0
    entry = %{id: idx, text: line}

    {:noreply,
     socket
     |> assign(:ssl_log_counter, idx + 1)
     |> stream_insert(:ssl_log_lines, entry)}
  end

  def handle_event("set_section", %{"section" => section}, socket) do
    section = String.to_existing_atom(section)
    domain = socket.assigns.domain

    # Re-stream collections when their tab becomes visible, because
    # phx-update="stream" containers that weren't in the DOM at mount
    # time will have lost their initial data.
    socket =
      case section do
        :subdomains ->
          stream(socket, :subdomains, Hosting.list_subdomains(domain), reset: true)

        :cron ->
          stream(socket, :cron_jobs, Hosting.list_cron_jobs(domain), reset: true)

        :ftp ->
          stream(socket, :ftp_accounts, Hosting.list_ftp_accounts(domain), reset: true)

        :smarthost ->
          socket

        _ ->
          socket
      end

    {:noreply, assign(socket, :active_section, section)}
  end

  def handle_event("sync_nginx", _params, socket) do
    case WebServer.sync_domain(socket.assigns.domain) do
      :ok ->
        {:noreply, put_flash(socket, :info, "Nginx config rebuilt and reloaded.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Nginx sync failed: #{inspect(reason)}")}
    end
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

  def handle_event("request_ssl", %{"ssl_certificate" => params}, socket) do
    domain = socket.assigns.domain
    email = params["email"]

    case Hosting.create_ssl_certificate(domain, %{
           cert_type: "lets_encrypt",
           status: "pending",
           email: email
         }) do
      {:ok, cert} ->
        {:noreply,
         socket
         |> assign(:ssl_cert, cert)
         |> assign(:ssl_log_counter, 0)
         |> stream(:ssl_log_lines, [], reset: true)
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

  def handle_event("edit_ftp", %{"id" => id}, socket) do
    ftp_accounts = Hosting.list_ftp_accounts(socket.assigns.domain)
    account = Enum.find(ftp_accounts, &(to_string(&1.id) == id))

    if account do
      form = Hosting.change_ftp_account_for_update(account) |> to_form()

      {:noreply,
       socket
       |> assign(:editing_ftp_id, account.id)
       |> assign(:ftp_edit_form, form)
       |> stream_insert(:ftp_accounts, account)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel_edit_ftp", _params, socket) do
    {:noreply, assign(socket, :editing_ftp_id, nil)}
  end

  def handle_event("validate_edit_ftp", %{"ftp_account" => params}, socket) do
    ftp_accounts = Hosting.list_ftp_accounts(socket.assigns.domain)
    account = Enum.find(ftp_accounts, &(&1.id == socket.assigns.editing_ftp_id))

    if account do
      form =
        Hosting.change_ftp_account_for_update(account, params)
        |> to_form(action: :validate)

      {:noreply, assign(socket, :ftp_edit_form, form)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("save_edit_ftp", %{"ftp_account" => params}, socket) do
    ftp_accounts = Hosting.list_ftp_accounts(socket.assigns.domain)
    account = Enum.find(ftp_accounts, &(&1.id == socket.assigns.editing_ftp_id))

    if account do
      case Hosting.update_ftp_account(account, params) do
        {:ok, updated} ->
          {:noreply,
           socket
           |> stream_insert(:ftp_accounts, updated)
           |> assign(:editing_ftp_id, nil)
           |> put_flash(:info, "FTP account #{updated.username} updated.")}

        {:error, changeset} ->
          {:noreply, assign(socket, :ftp_edit_form, to_form(changeset))}
      end
    else
      {:noreply, socket}
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

  # Smarthost events
  def handle_event("validate_smarthost", %{"smarthost" => params}, socket) do
    changeset =
      Hosting.change_domain_smarthost_setting(socket.assigns.smarthost_setting, params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :smarthost_form, to_form(changeset, as: :smarthost))}
  end

  def handle_event("submit_smarthost", %{"action" => "apply"} = params, socket) do
    domain = socket.assigns.domain
    smarthost_params = Map.get(params, "smarthost", %{})

    case Hosting.save_domain_smarthost_setting(domain, smarthost_params) do
      {:ok, setting} ->
        apply_status =
          if Settings.feature_enabled?("email") do
            case MailServer.apply_domain_smarthost(setting) do
              :ok -> :applied
              {:error, _reason} -> :apply_failed
            end
          else
            :saved
          end

        socket =
          socket
          |> assign(:smarthost_setting, setting)
          |> assign(
            :smarthost_form,
            to_form(Hosting.change_domain_smarthost_setting(setting), as: :smarthost)
          )
          |> assign(:smarthost_apply_status, apply_status)

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :smarthost_form, to_form(changeset, as: :smarthost))}
    end
  end

  def handle_event("submit_smarthost", %{"smarthost" => params}, socket) do
    domain = socket.assigns.domain

    case Hosting.save_domain_smarthost_setting(domain, params) do
      {:ok, setting} ->
        socket =
          socket
          |> assign(:smarthost_setting, setting)
          |> assign(
            :smarthost_form,
            to_form(Hosting.change_domain_smarthost_setting(setting), as: :smarthost)
          )
          |> assign(:smarthost_apply_status, :saved)

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :smarthost_form, to_form(changeset, as: :smarthost))}
    end
  end

  def handle_event("toggle_smarthost_password", _params, socket) do
    {:noreply, update(socket, :smarthost_show_password, &(!&1))}
  end

  defp assign_ssl_form(socket) do
    user_email = socket.assigns.current_scope.user.email
    changeset = Hosting.change_ssl_certificate(%SslCertificate{}, %{email: user_email})
    assign(socket, :ssl_form, to_form(changeset, as: :ssl_certificate))
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

  defp assign_smarthost_form(socket) do
    setting = Hosting.get_domain_smarthost_setting(socket.assigns.domain)

    socket
    |> assign(:smarthost_setting, setting)
    |> assign(
      :smarthost_form,
      to_form(Hosting.change_domain_smarthost_setting(setting), as: :smarthost)
    )
    |> assign(:smarthost_show_password, false)
    |> assign(:smarthost_apply_status, nil)
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
          <% base_tabs = [
            {"Overview", :overview, "hero-home"},
            {"Subdomains", :subdomains, "hero-link"},
            {"DNS", :dns, "hero-server"},
            {"SSL", :ssl, "hero-lock-closed"},
            {"Cron Jobs", :cron, "hero-clock"}
          ]

          tabs =
            if Settings.feature_enabled?("ftp") do
              base_tabs ++ [{"FTP", :ftp, "hero-folder"}]
            else
              base_tabs
            end

          tabs =
            if Settings.feature_enabled?("email") do
              tabs ++ [{"Smarthost", :smarthost, "hero-envelope-open"}]
            else
              tabs
            end %>
          <%= for {label, section, icon} <- tabs do %>
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
              value={
                cond do
                  @ssl_cert && @ssl_cert.status == "active" -> "Active"
                  @ssl_cert && @ssl_cert.status == "pending" -> "Issuing…"
                  @ssl_cert && @ssl_cert.status == "expired" -> "Expired"
                  true -> "None"
                end
              }
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
              <button
                phx-click="sync_nginx"
                class="flex flex-col items-center gap-2 p-4 rounded-lg border border-gray-200 dark:border-gray-700 hover:border-orange-300 dark:hover:border-orange-700 hover:bg-orange-50 dark:hover:bg-orange-950/30 transition-colors"
              >
                <.icon name="hero-arrow-path" class="w-5 h-5 text-gray-500 dark:text-gray-400" />
                <span class="text-xs font-medium text-gray-700 dark:text-gray-300">
                  Rebuild Config
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
              <div class="space-y-4">
                <div class="flex items-center gap-3">
                  <div class={[
                    "flex items-center justify-center w-10 h-10 rounded-lg",
                    cond do
                      @ssl_cert.status == "active" -> "bg-green-100 dark:bg-green-900/30"
                      @ssl_cert.status == "expired" -> "bg-red-100 dark:bg-red-900/30"
                      true -> "bg-yellow-100 dark:bg-yellow-900/30"
                    end
                  ]}>
                    <%= cond do %>
                      <% @ssl_cert.status == "active" -> %>
                        <.icon
                          name="hero-lock-closed"
                          class="w-5 h-5 text-green-600 dark:text-green-400"
                        />
                      <% @ssl_cert.status == "expired" -> %>
                        <.icon
                          name="hero-exclamation-triangle"
                          class="w-5 h-5 text-red-600 dark:text-red-400"
                        />
                      <% true -> %>
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
                      cond do
                        @ssl_cert.status == "active" -> "text-green-600 dark:text-green-400"
                        @ssl_cert.status == "expired" -> "text-red-600 dark:text-red-400"
                        true -> "text-yellow-600 dark:text-yellow-400"
                      end
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

                <%!-- Live / persisted log output --%>
                <div>
                  <p class="text-xs font-medium text-gray-500 dark:text-gray-400 mb-1.5 uppercase tracking-wide">
                    Certbot output
                  </p>
                  <div
                    id="ssl-log"
                    phx-update="stream"
                    phx-hook=".SslLogScroll"
                    class="bg-gray-950 rounded-lg p-4 font-mono text-xs text-green-400 overflow-y-auto max-h-72 space-y-0.5"
                  >
                    <div class="hidden only:block text-gray-600">Waiting for output…</div>
                    <div
                      :for={{id, entry} <- @streams.ssl_log_lines}
                      id={id}
                      class="whitespace-pre-wrap break-all leading-5"
                    >
                      {entry.text}
                    </div>
                  </div>
                  <script :type={Phoenix.LiveView.ColocatedHook} name=".SslLogScroll">
                    export default {
                      updated() { this.el.scrollTop = this.el.scrollHeight }
                    }
                  </script>
                </div>
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
                <.form
                  for={@ssl_form}
                  id="ssl-request-form"
                  phx-submit="request_ssl"
                  class="flex flex-col items-center gap-3"
                >
                  <.input
                    field={@ssl_form[:email]}
                    type="email"
                    placeholder="you@example.com"
                    label="Let's Encrypt email"
                    class="w-72 px-3 py-2 text-sm border border-gray-300 dark:border-gray-700 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-white focus:outline-none focus:ring-2 focus:ring-indigo-500"
                  />
                  <button
                    type="submit"
                    class="inline-flex items-center gap-2 px-4 py-2 bg-green-600 hover:bg-green-700 text-white text-sm font-medium rounded-lg transition-colors"
                  >
                    <.icon name="hero-lock-closed" class="w-4 h-4" /> Request Free SSL
                  </button>
                </.form>
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
                  type="select"
                  label="Home directory"
                  options={@ftp_home_options}
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
                class="px-6 py-3"
              >
                <%= if @editing_ftp_id == account.id do %>
                  <.form
                    for={@ftp_edit_form}
                    id={"ftp-edit-form-#{account.id}"}
                    phx-change="validate_edit_ftp"
                    phx-submit="save_edit_ftp"
                    class="grid grid-cols-1 gap-3 sm:grid-cols-4 items-end"
                  >
                    <div>
                      <p class="text-xs text-gray-500 mb-1">Username</p>
                      <p class="text-sm font-medium text-gray-900 dark:text-white">
                        {account.username}
                      </p>
                    </div>
                    <.input
                      field={@ftp_edit_form[:password]}
                      type="password"
                      label="New password (optional)"
                    />
                    <.input
                      field={@ftp_edit_form[:home_dir]}
                      type="select"
                      label="Home directory"
                      options={@ftp_home_options}
                    />
                    <div class="flex items-center gap-2">
                      <button
                        type="submit"
                        class="px-3 py-1.5 bg-indigo-600 hover:bg-indigo-700 text-white text-xs font-medium rounded-lg transition-colors"
                      >
                        Save
                      </button>
                      <button
                        type="button"
                        phx-click="cancel_edit_ftp"
                        class="px-3 py-1.5 text-gray-600 hover:text-gray-800 dark:text-gray-400 dark:hover:text-gray-200 text-xs font-medium rounded-lg border border-gray-300 dark:border-gray-700 transition-colors"
                      >
                        Cancel
                      </button>
                    </div>
                  </.form>
                <% else %>
                  <div class="flex items-center justify-between">
                    <div>
                      <p class="text-sm font-medium text-gray-900 dark:text-white">
                        {account.username}
                      </p>
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
                        phx-click="edit_ftp"
                        phx-value-id={account.id}
                        class="text-xs text-indigo-500 hover:text-indigo-600"
                      >
                        Edit
                      </button>
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
                <% end %>
              </div>
            </div>
          </div>
        <% end %>

        <%!-- Smarthost --%>
        <%= if @active_section == :smarthost do %>
          <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800">
            <div class="px-6 py-5 border-b border-gray-200 dark:border-gray-800">
              <h3 class="text-base font-semibold text-gray-900 dark:text-white">Domain Smarthost</h3>
              <p class="mt-1 text-sm text-gray-500 dark:text-gray-400">
                Override the server-wide relay for outgoing mail from {@domain.name}.
              </p>
            </div>
            <div class="p-6">
              <.form
                for={@smarthost_form}
                id="smarthost-form"
                phx-change="validate_smarthost"
                phx-submit="submit_smarthost"
                class="space-y-5"
              >
                <%!-- Enable toggle --%>
                <div class="flex items-center gap-3">
                  <.input
                    field={@smarthost_form[:enabled]}
                    type="checkbox"
                    label="Enable domain smarthost"
                  />
                </div>

                <div class={[
                  @smarthost_form[:enabled].value != true && "opacity-50 pointer-events-none"
                ]}>
                  <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
                    <.input
                      field={@smarthost_form[:host]}
                      type="text"
                      label="Relay host"
                      placeholder="smtp.mailgun.org"
                    />
                    <.input
                      field={@smarthost_form[:port]}
                      type="number"
                      label="Port"
                      placeholder="587"
                    />
                  </div>

                  <div class="mt-4 flex items-center gap-3">
                    <.input
                      field={@smarthost_form[:auth_required]}
                      type="checkbox"
                      label="Authentication required"
                    />
                  </div>

                  <div class={[
                    "mt-4 grid grid-cols-1 gap-4 sm:grid-cols-2",
                    @smarthost_form[:auth_required].value != true && "opacity-50 pointer-events-none"
                  ]}>
                    <.input
                      field={@smarthost_form[:username]}
                      type="text"
                      label="Username"
                      placeholder="postmaster@mg.example.com"
                    />
                    <div class="relative">
                      <.input
                        field={@smarthost_form[:password]}
                        type={if(@smarthost_show_password, do: "text", else: "password")}
                        label="Password / API key"
                        placeholder="••••••••"
                      />
                      <button
                        type="button"
                        phx-click="toggle_smarthost_password"
                        class="absolute right-3 top-8 text-gray-400 hover:text-gray-600 dark:hover:text-gray-300"
                      >
                        <.icon
                          name={if(@smarthost_show_password, do: "hero-eye-slash", else: "hero-eye")}
                          class="w-4 h-4"
                        />
                      </button>
                    </div>
                  </div>
                </div>

                <div class="flex items-center justify-between pt-2">
                  <div class="text-sm">
                    <%= cond do %>
                      <% @smarthost_apply_status == :applied -> %>
                        <span class="text-green-600 dark:text-green-400 flex items-center gap-1">
                          <.icon name="hero-check-circle" class="w-4 h-4" /> Saved &amp; applied
                        </span>
                      <% @smarthost_apply_status == :saved -> %>
                        <span class="text-blue-600 dark:text-blue-400 flex items-center gap-1">
                          <.icon name="hero-check" class="w-4 h-4" /> Saved
                        </span>
                      <% @smarthost_apply_status == :apply_failed -> %>
                        <span class="text-red-600 dark:text-red-400 flex items-center gap-1">
                          <.icon name="hero-x-circle" class="w-4 h-4" /> Saved, but apply failed
                        </span>
                      <% true -> %>
                        <span></span>
                    <% end %>
                  </div>
                  <div class="flex gap-2">
                    <button
                      type="submit"
                      name="action"
                      value="save"
                      class="px-4 py-2 text-sm font-medium text-gray-700 dark:text-gray-300 bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg hover:bg-gray-50 dark:hover:bg-gray-700 transition-colors"
                    >
                      Save
                    </button>
                    <button
                      type="submit"
                      name="action"
                      value="apply"
                      class="px-4 py-2 text-sm font-medium text-white bg-indigo-600 hover:bg-indigo-700 rounded-lg transition-colors"
                    >
                      Save &amp; Apply
                    </button>
                  </div>
                </div>
              </.form>
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
