defmodule HostctlWeb.EmailLive.Index do
  use HostctlWeb, :live_view

  alias Hostctl.Hosting
  alias Hostctl.Hosting.EmailAccount

  def mount(_params, _session, socket) do
    domains = Hosting.list_domains(socket.assigns.current_scope)
    all_accounts = Enum.flat_map(domains, &Hosting.list_email_accounts/1)

    {:ok,
     socket
     |> assign(:page_title, "Email Accounts")
     |> assign(:active_tab, :email)
     |> assign(:domains, domains)
     |> assign(:selected_domain_id, nil)
     |> assign(:accounts_empty?, all_accounts == [])
     |> assign_form()
     |> stream(:email_accounts, all_accounts)}
  end

  def handle_event("select_domain", %{"domain_id" => domain_id}, socket) do
    domain_id = if domain_id == "", do: nil, else: String.to_integer(domain_id)

    accounts =
      if domain_id do
        domain = Hosting.get_domain!(socket.assigns.current_scope, domain_id)
        Hosting.list_email_accounts(domain)
      else
        Enum.flat_map(socket.assigns.domains, &Hosting.list_email_accounts/1)
      end

    {:noreply,
     socket
     |> assign(:selected_domain_id, domain_id)
     |> assign(:accounts_empty?, accounts == [])
     |> stream(:email_accounts, accounts, reset: true)}
  end

  def handle_event("validate", %{"email_account" => params}, socket) do
    form =
      %EmailAccount{}
      |> Hosting.change_email_account(params)
      |> to_form(action: :validate)

    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("save", %{"email_account" => params}, socket) do
    domain_id = socket.assigns.selected_domain_id || get_first_domain_id(socket)
    domain = Hosting.get_domain!(socket.assigns.current_scope, domain_id)

    case Hosting.create_email_account(domain, params) do
      {:ok, account} ->
        {:noreply,
         socket
         |> assign(:accounts_empty?, false)
         |> stream_insert(:email_accounts, account)
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
      all_accounts = Enum.flat_map(socket.assigns.domains, &Hosting.list_email_accounts/1)

      {:noreply,
       socket
       |> assign(:accounts_empty?, all_accounts == [])
       |> stream_delete(:email_accounts, account)
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

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_tab={@active_tab}>
      <div class="space-y-6">
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-bold text-gray-900 dark:text-white">Email Accounts</h1>
            <p class="mt-1 text-sm text-gray-500 dark:text-gray-400">
              Manage email accounts for your domains
            </p>
          </div>
        </div>

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
          <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800 p-6">
            <h2 class="text-base font-semibold text-gray-900 dark:text-white mb-4">
              Create Email Account
            </h2>
            <.form
              for={@form}
              id="email-account-form"
              phx-change="validate"
              phx-submit="save"
              class="space-y-4"
            >
              <div class="flex flex-col sm:flex-row items-start gap-3">
                <div class="flex-1 w-full sm:w-auto">
                  <.input field={@form[:username]} type="text" label="Username" placeholder="info" errors={[]} />
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
                  <p :for={msg <- Enum.map(@form[:username].errors, &translate_error(&1))} class="flex items-center gap-1.5 text-sm text-error">
                    <.icon name="hero-exclamation-circle" class="size-4" /> Username {msg}
                  </p>
                  <p :for={msg <- Enum.map(@form[:password].errors, &translate_error(&1))} class="flex items-center gap-1.5 text-sm text-error">
                    <.icon name="hero-exclamation-circle" class="size-4" /> Password {msg}
                  </p>
                  <p :for={msg <- Enum.map(@form[:quota_mb].errors, &translate_error(&1))} class="flex items-center gap-1.5 text-sm text-error">
                    <.icon name="hero-exclamation-circle" class="size-4" /> Quota {msg}
                  </p>
                </div>
              <% end %>
            </.form>
          </div>

          <%!-- Filter by domain --%>
          <div class="flex items-center gap-3">
            <span class="text-sm text-gray-600 dark:text-gray-400">Filter by domain:</span>
            <div class="flex gap-2 flex-wrap">
              <button
                phx-click="select_domain"
                phx-value-domain_id=""
                class={[
                  "px-3 py-1 rounded-full text-xs font-medium transition-colors",
                  if(@selected_domain_id == nil,
                    do: "bg-indigo-600 text-white",
                    else:
                      "bg-gray-100 dark:bg-gray-800 text-gray-600 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-700"
                  )
                ]}
              >
                All
              </button>
              <button
                :for={domain <- @domains}
                phx-click="select_domain"
                phx-value-domain_id={domain.id}
                class={[
                  "px-3 py-1 rounded-full text-xs font-medium transition-colors",
                  if(@selected_domain_id == domain.id,
                    do: "bg-indigo-600 text-white",
                    else:
                      "bg-gray-100 dark:bg-gray-800 text-gray-600 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-700"
                  )
                ]}
              >
                {domain.name}
              </button>
            </div>
          </div>

          <%!-- Accounts list --%>
          <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800 overflow-hidden">
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
              <tbody id="email-accounts" phx-update="stream" class="divide-y divide-gray-100 dark:divide-gray-800">
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
                          {account.username}
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
