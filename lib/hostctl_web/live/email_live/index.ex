defmodule HostctlWeb.EmailLive.Index do
  use HostctlWeb, :live_view

  alias Hostctl.Hosting
  alias Hostctl.Hosting.EmailAccount
  alias Hostctl.Settings
  alias HostctlWeb.ResourceScope

  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    is_admin = scope.user.role == "admin"

    domains =
      if is_admin do
        Hosting.list_all_domains_with_users()
      else
        Hosting.list_domains(scope)
      end

    {:ok,
     socket
     |> assign(:page_title, "Email Accounts")
     |> assign(:active_tab, :email)
     |> assign(:is_admin?, is_admin)
     |> assign(:domains, domains)
     |> assign(:selected_domain_id, nil)
     |> assign(:query, "")
     |> assign(:accounts_empty?, true)
     |> assign(:webmail_links, webmail_links())
     |> assign_form()
     |> stream(:email_accounts, [])}
  end

  def handle_params(params, _uri, socket) do
    domain = ResourceScope.selected(socket.assigns.domains, params["domain_id"])
    {:noreply, socket |> assign(:selected_domain_id, domain && domain.id) |> reload_resources()}
  end

  def handle_event("scope_domain", %{"domain_id" => id}, socket),
    do: {:noreply, push_patch(socket, to: ~p"/email?#{%{domain_id: id}}")}

  def handle_event("select_domain", params, socket),
    do: handle_event("scope_domain", params, socket)

  def handle_event("search_resources", %{"query" => query}, socket),
    do: {:noreply, socket |> assign(:query, query) |> reload_resources()}

  def handle_event("validate", %{"email_account" => params}, socket) do
    form =
      %EmailAccount{}
      |> Hosting.change_email_account(params)
      |> to_form(action: :validate)

    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("save", %{"email_account" => params}, socket) do
    domain_id = socket.assigns.selected_domain_id || get_first_domain_id(socket)
    domain = find_domain!(socket, domain_id)

    case Hosting.create_email_account(domain, params) do
      {:ok, account} ->
        {:noreply,
         socket
         |> reload_resources()
         |> assign_form()
         |> put_flash(:info, "Email account #{account.username}@#{domain.name} created.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    accounts = Enum.flat_map(socket.assigns.domains, &Hosting.list_email_accounts/1)
    account = Enum.find(accounts, &(to_string(&1.id) == id))

    if account do
      {:ok, _} = Hosting.delete_email_account(account)

      {:noreply,
       socket
       |> reload_resources()
       |> put_flash(:info, "Email account deleted.")}
    else
      {:noreply, socket}
    end
  end

  defp assign_form(socket) do
    assign(socket, :form, to_form(Hosting.change_email_account(%EmailAccount{})))
  end

  defp get_first_domain_id(socket) do
    case socket.assigns.domains do
      [domain | _] -> domain.id
      [] -> nil
    end
  end

  defp find_domain!(socket, domain_id) do
    if socket.assigns.is_admin? do
      Hosting.get_domain_for_admin!(domain_id)
    else
      Hosting.get_domain!(socket.assigns.current_scope, domain_id)
    end
  end

  defp webmail_links do
    [
      {"roundcube", "Roundcube", "/roundcube", "hero-inbox-stack"},
      {"snappymail", "SnappyMail", "/snappymail", "hero-bolt"}
    ]
    |> Enum.filter(fn {key, _, _, _} -> Settings.feature_enabled?(key) end)
  end

  defp reload_resources(socket) do
    resources =
      socket.assigns.domains
      |> Enum.filter(
        &(is_nil(socket.assigns.selected_domain_id) || &1.id == socket.assigns.selected_domain_id)
      )
      |> Enum.flat_map(&Hosting.list_email_accounts/1)
      |> Enum.filter(
        &String.contains?(String.downcase(&1.username), String.downcase(socket.assigns.query))
      )

    socket
    |> assign(:accounts_empty?, resources == [])
    |> stream(:email_accounts, resources, reset: true)
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      update_status={assigns[:update_status]}
      flash={@flash}
      current_scope={@current_scope}
      active_tab={@active_tab}
    >
      <div class="space-y-6">
        <div class="flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1 class="text-2xl font-bold text-gray-900 dark:text-white">Email Accounts</h1>
            <p class="mt-1 text-sm text-gray-500 dark:text-gray-400">
              Manage email accounts for your domains
            </p>
          </div>
          <%= if @webmail_links != [] do %>
            <div class="flex items-center gap-2">
              <a
                :for={{_key, label, path, icon} <- @webmail_links}
                href={path}
                target="_blank"
                rel="noopener noreferrer"
                class="inline-flex items-center gap-2 px-4 py-2 bg-white dark:bg-gray-900 border border-gray-200 dark:border-gray-700 text-gray-700 dark:text-gray-200 text-sm font-medium rounded-lg hover:bg-gray-50 dark:hover:bg-gray-800 transition-colors"
              >
                <.icon name={icon} class="w-4 h-4" />
                {label}
                <.icon name="hero-arrow-top-right-on-square" class="w-3.5 h-3.5 text-gray-400" />
              </a>
            </div>
          <% end %>
        </div>

        <HostctlWeb.ResourceComponents.domain_scope
          domains={@domains}
          selected_domain_id={@selected_domain_id}
          id="email-scope"
        />
        <.form for={to_form(%{"query" => @query})} id="email-search" phx-change="search_resources">
          <.input type="search" name="query" value={@query} label="Search email" phx-debounce="200" />
        </.form>

        <%= if @domains == [] do %>
          <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800 p-12 text-center">
            <.icon
              name="hero-envelope"
              class="w-10 h-10 text-gray-300 dark:text-gray-600 mx-auto mb-3"
            />
            <p class="text-sm font-medium text-gray-900 dark:text-white">No domains yet</p>
            <p class="text-sm text-gray-500 dark:text-gray-400 mb-4">
              Add a domain first to create email accounts.
            </p>
            <.link
              navigate={~p"/domains/new"}
              class="inline-flex items-center gap-2 px-4 py-2 bg-indigo-600 hover:bg-indigo-700 text-white text-sm font-medium rounded-lg transition-colors"
            >
              <.icon name="hero-plus" class="w-4 h-4" /> Add Domain
            </.link>
          </div>
        <% else %>
          <%!-- Create account form --%>
          <details
            id="create-email-panel"
            class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800 p-6"
          >
            <summary class="cursor-pointer text-sm font-semibold text-indigo-600 dark:text-indigo-300">
              Create Email Account
            </summary>
            <.form
              for={@form}
              id="email-account-form"
              phx-change="validate"
              phx-submit="save"
              class="mt-5 space-y-4"
            >
              <div class="flex flex-col sm:flex-row items-start gap-3">
                <div class="flex-1 w-full sm:w-auto">
                  <.input
                    field={@form[:username]}
                    type="text"
                    label="Username"
                    placeholder="info"
                    errors={[]}
                  />
                </div>
                <span class="hidden sm:block mt-8 text-gray-500 dark:text-gray-400 text-sm">@</span>
                <div class="flex-1 w-full sm:w-auto fieldset mb-2">
                  <label for="domain-select">
                    <span class="label mb-1">Domain</span>
                    <select
                      id="domain-select"
                      name="domain_id"
                      phx-change="select_domain"
                      class="w-full input"
                    >
                      <option
                        :for={domain <- @domains}
                        value={domain.id}
                        selected={@selected_domain_id == domain.id}
                      >
                        {domain.name}
                      </option>
                    </select>
                  </label>
                </div>
                <div class="flex-1 w-full sm:w-auto">
                  <.input field={@form[:password]} type="password" label="Password" errors={[]} />
                </div>
                <div class="w-full sm:w-28">
                  <.input field={@form[:quota_mb]} type="number" label="Quota (MB)" errors={[]} />
                </div>
                <div class="mt-0 sm:mt-6">
                  <button
                    type="submit"
                    class="px-4 py-2 bg-indigo-600 hover:bg-indigo-700 text-white text-sm font-medium rounded-lg transition-colors whitespace-nowrap"
                  >
                    Create Account
                  </button>
                </div>
              </div>
              <%= if @form.source.action do %>
                <div class="flex flex-wrap gap-x-4 gap-y-1">
                  <p
                    :for={msg <- Enum.map(@form[:username].errors, &translate_error(&1))}
                    class="flex items-center gap-1.5 text-sm text-error"
                  >
                    <.icon name="hero-exclamation-circle" class="size-4" /> Username {msg}
                  </p>
                  <p
                    :for={msg <- Enum.map(@form[:password].errors, &translate_error(&1))}
                    class="flex items-center gap-1.5 text-sm text-error"
                  >
                    <.icon name="hero-exclamation-circle" class="size-4" /> Password {msg}
                  </p>
                  <p
                    :for={msg <- Enum.map(@form[:quota_mb].errors, &translate_error(&1))}
                    class="flex items-center gap-1.5 text-sm text-error"
                  >
                    <.icon name="hero-exclamation-circle" class="size-4" /> Quota {msg}
                  </p>
                </div>
              <% end %>
            </.form>
          </details>

          <%!-- Accounts list --%>
          <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800 overflow-x-auto">
            <div
              :if={@accounts_empty?}
              class="flex flex-col items-center justify-center py-16 gap-3"
            >
              <.icon
                name="hero-envelope"
                class="w-10 h-10 text-gray-300 dark:text-gray-600 mx-auto"
              />
              <p class="text-sm text-gray-400 mt-2">No email accounts yet.</p>
            </div>
            <table class={[
              "min-w-full divide-y divide-gray-200 dark:divide-gray-800",
              if(@accounts_empty?, do: "hidden")
            ]}>
              <thead>
                <tr class="bg-gray-50 dark:bg-gray-800/50">
                  <th class="px-6 py-3 text-left text-xs font-semibold text-gray-500 uppercase tracking-wider">
                    Email Address
                  </th>
                  <th class="px-6 py-3 text-left text-xs font-semibold text-gray-500 uppercase tracking-wider">
                    Quota
                  </th>
                  <th class="px-6 py-3 text-left text-xs font-semibold text-gray-500 uppercase tracking-wider">
                    Status
                  </th>
                  <th class="relative px-6 py-3"><span class="sr-only">Actions</span></th>
                </tr>
              </thead>
              <tbody
                id="email-accounts"
                phx-update="stream"
                class="divide-y divide-gray-100 dark:divide-gray-800"
              >
                <tr
                  :for={{id, account} <- @streams.email_accounts}
                  id={id}
                  class="hover:bg-gray-50 dark:hover:bg-gray-800/50 transition-colors"
                >
                  <td class="px-6 py-4">
                    <div class="flex items-center gap-3">
                      <div class="flex items-center justify-center w-8 h-8 rounded-full bg-indigo-100 dark:bg-indigo-900/30 text-indigo-600 dark:text-indigo-400 text-xs font-bold shrink-0">
                        {String.upcase(String.slice(account.username, 0, 1))}
                      </div>
                      <p class="text-sm font-medium text-gray-900 dark:text-white">
                        {account.username}<span class="text-gray-400 dark:text-gray-500 font-normal">@{account.domain.name}</span>
                      </p>
                    </div>
                  </td>
                  <td class="px-6 py-4 text-sm text-gray-600 dark:text-gray-400">
                    {account.quota_mb} MB
                  </td>
                  <td class="px-6 py-4">
                    <span class={[
                      "inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium",
                      if(account.status == "active",
                        do: "bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400",
                        else: "bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-400"
                      )
                    ]}>
                      {account.status}
                    </span>
                  </td>
                  <td class="px-6 py-4 text-right">
                    <a
                      :for={{key, label, path, _icon} <- @webmail_links}
                      id={"webmail-#{account.id}-#{key}"}
                      href={path}
                      target="_blank"
                      rel="noopener noreferrer"
                      aria-label={"Open #{label} webmail for #{account.username}@#{account.domain.name}"}
                      class="mr-4 whitespace-nowrap text-sm text-indigo-600 dark:text-indigo-400"
                    >
                      {if length(@webmail_links) == 1, do: "Webmail", else: label}
                      <.icon name="hero-arrow-top-right-on-square" class="size-3.5" />
                    </a>

                    <button
                      phx-click="delete"
                      phx-value-id={account.id}
                      data-confirm="Delete this email account?"
                      class="text-xs font-medium text-red-500 hover:text-red-600"
                    >
                      Delete
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
