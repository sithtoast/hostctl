defmodule HostctlWeb.FtpLive.Index do
  use HostctlWeb, :live_view

  alias Hostctl.Hosting
  alias Hostctl.Hosting.FtpAccount
  alias HostctlWeb.ResourceScope

  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    domains =
      if scope.user.role == "admin",
        do: Hosting.list_all_domains_with_users(),
        else: Hosting.list_domains(scope)

    ftp_dir_options = build_ftp_dir_options(domains)

    {:ok,
     socket
     |> stream(:ftp_accounts, [])
     |> assign(:page_title, "FTP Accounts")
     |> assign(:active_tab, :ftp)
     |> assign(:domains, domains)
     |> assign(:selected_domain_id, nil)
     |> assign(:query, "")
     |> assign(:account_scope, "all")
     |> assign(:ftp_dir_options, ftp_dir_options)
     |> assign(:editing_ftp_id, nil)
     |> assign(:ftp_edit_form, nil)
     |> assign(:ftp_access_mode, "single")
     |> assign(:ftp_edit_access_mode, "single")
     |> assign(:ftp_edit_selected_paths, [])
     |> assign_ftp_form()}
  end

  def handle_params(params, _url, socket) do
    domain = ResourceScope.selected(socket.assigns.domains, params["domain_id"])
    socket = socket |> assign(:selected_domain_id, domain && domain.id) |> reload_accounts()
    {:noreply, socket}
  end

  def handle_event("scope_domain", %{"domain_id" => id}, socket),
    do: {:noreply, push_patch(socket, to: ~p"/ftp?#{%{domain_id: id}}")}

  def handle_event("filter_accounts", params, socket) do
    {:noreply,
     socket
     |> assign(query: params["query"] || "", account_scope: params["account_scope"] || "all")
     |> reload_accounts()}
  end

  def handle_event("set_ftp_mode", %{"mode" => mode}, socket) when mode in ["single", "multi"] do
    {:noreply, assign(socket, :ftp_access_mode, mode)}
  end

  def handle_event("set_ftp_edit_mode", %{"mode" => mode}, socket)
      when mode in ["single", "multi"] do
    socket = assign(socket, :ftp_edit_access_mode, mode)

    socket =
      if socket.assigns.editing_ftp_id do
        account =
          Hosting.list_all_ftp_accounts(socket.assigns.current_scope)
          |> Enum.find(&(&1.id == socket.assigns.editing_ftp_id))

        if account, do: stream_insert(socket, :ftp_accounts, account), else: socket
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("validate_ftp", %{"ftp_account" => params}, socket) do
    params = prepare_ftp_params(params, socket.assigns.ftp_access_mode)

    form =
      %FtpAccount{}
      |> Hosting.change_ftp_account(params)
      |> to_form(action: :validate)

    {:noreply, assign(socket, :ftp_form, form)}
  end

  def handle_event("save_ftp", %{"ftp_account" => params}, socket) do
    params = prepare_ftp_params(params, socket.assigns.ftp_access_mode)
    user = socket.assigns.current_scope.user

    case Hosting.create_ftp_account(user, params) do
      {:ok, account} ->
        account = Hosting.get_ftp_account_with_user!(account.id)

        {:noreply,
         socket
         |> stream_insert(:ftp_accounts, account)
         |> assign_ftp_form()
         |> assign(:ftp_access_mode, "single")
         |> reload_accounts()
         |> put_flash(:info, "FTP account #{account.username} created.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :ftp_form, to_form(changeset))}
    end
  end

  def handle_event("edit_ftp", %{"id" => id}, socket) do
    account =
      Hosting.list_all_ftp_accounts(socket.assigns.current_scope)
      |> Enum.find(&(to_string(&1.id) == id))

    if account do
      form = Hosting.change_ftp_account_for_update(account) |> to_form()
      edit_mode = if account.mounts && account.mounts != [], do: "multi", else: "single"
      selected_paths = Enum.map(account.mounts || [], & &1["path"])

      {:noreply,
       socket
       |> assign(:editing_ftp_id, account.id)
       |> assign(:ftp_edit_form, form)
       |> assign(:ftp_edit_access_mode, edit_mode)
       |> assign(:ftp_edit_selected_paths, selected_paths)
       |> stream_insert(:ftp_accounts, account)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel_edit_ftp", _params, socket) do
    {:noreply, assign(socket, :editing_ftp_id, nil)}
  end

  def handle_event("validate_edit_ftp", %{"ftp_account" => params}, socket) do
    account =
      Hosting.list_all_ftp_accounts(socket.assigns.current_scope)
      |> Enum.find(&(&1.id == socket.assigns.editing_ftp_id))

    if account do
      params = prepare_ftp_params(params, socket.assigns.ftp_edit_access_mode)

      form =
        Hosting.change_ftp_account_for_update(account, params)
        |> to_form(action: :validate)

      {:noreply, assign(socket, :ftp_edit_form, form)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("save_edit_ftp", %{"ftp_account" => params}, socket) do
    account =
      Hosting.list_all_ftp_accounts(socket.assigns.current_scope)
      |> Enum.find(&(&1.id == socket.assigns.editing_ftp_id))

    if account do
      params = prepare_ftp_params(params, socket.assigns.ftp_edit_access_mode)

      case Hosting.update_ftp_account(account, params) do
        {:ok, updated} ->
          updated = Hosting.get_ftp_account_with_user!(updated.id)

          {:noreply,
           socket
           |> assign(:editing_ftp_id, nil)
           |> reload_accounts()
           |> put_flash(:info, "FTP account #{updated.username} updated.")}

        {:error, changeset} ->
          {:noreply, assign(socket, :ftp_edit_form, to_form(changeset))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("delete_ftp", %{"id" => id}, socket) do
    account =
      Hosting.list_all_ftp_accounts(socket.assigns.current_scope)
      |> Enum.find(&(to_string(&1.id) == id))

    if account do
      {:ok, _} = Hosting.delete_ftp_account(account)
      {:noreply, stream_delete(socket, :ftp_accounts, account)}
    else
      {:noreply, socket}
    end
  end

  defp assign_ftp_form(socket) do
    assign(socket, :ftp_form, to_form(Hosting.change_ftp_account(%FtpAccount{})))
  end

  defp build_ftp_dir_options(domains) do
    Enum.flat_map(domains, fn d ->
      d_root = Path.dirname(d.document_root)
      doc_root_name = Path.basename(d.document_root)

      base_options =
        if d.document_root == d_root do
          [{"#{d.name}", d_root}]
        else
          [{"#{d.name}", d_root}, {"#{d.name}/#{doc_root_name}", d.document_root}]
        end

      sub_options =
        Hosting.list_subdomains(d)
        |> Enum.map(fn sub -> {"#{sub.name}.#{d.name}", sub.document_root} end)

      sub_fqdns = MapSet.new(sub_options, fn {label, _} -> label end)

      s3_sub_options =
        Hosting.list_s3_backends(d)
        |> Enum.filter(&(is_binary(&1.subdomain) && &1.subdomain != ""))
        |> Enum.map(fn b ->
          fqdn = "#{b.subdomain}.#{d.name}"
          {fqdn, "/var/www/#{d.name}/#{fqdn}"}
        end)
        |> Enum.reject(fn {label, _} -> MapSet.member?(sub_fqdns, label) end)

      base_options ++ sub_options ++ s3_sub_options
    end)
  end

  defp prepare_ftp_params(params, "multi") do
    mount_paths =
      params
      |> Map.get("mount_paths", [])
      |> List.wrap()
      |> Enum.reject(&(&1 == ""))

    mounts =
      Enum.map(mount_paths, fn path ->
        name = path |> String.replace(~r|^/var/www/|, "") |> String.replace("/", "-")
        %{"name" => name, "path" => path}
      end)

    params
    |> Map.put("mounts", mounts)
    |> Map.put("home_dir", nil)
    |> Map.delete("mount_paths")
  end

  defp prepare_ftp_params(params, _mode) do
    params
    |> Map.put("mounts", [])
    |> Map.delete("mount_paths")
  end

  defp reload_accounts(socket) do
    accounts =
      Hosting.list_all_ftp_accounts(socket.assigns.current_scope)
      |> Enum.filter(fn account ->
        domains = ResourceScope.ftp_domains(account, socket.assigns.domains)

        (is_nil(socket.assigns.selected_domain_id) ||
           Enum.any?(domains, &(&1.id == socket.assigns.selected_domain_id))) &&
          String.contains?(
            String.downcase(account.username),
            String.downcase(socket.assigns.query)
          ) &&
          (socket.assigns.account_scope == "all" ||
             (socket.assigns.account_scope == "shared" && length(domains) > 1) ||
             (socket.assigns.account_scope == "single" && length(domains) == 1))
      end)

    stream(socket, :ftp_accounts, accounts, reset: true)
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
        <%!-- Header --%>
        <div>
          <h1 class="text-2xl font-bold text-gray-900 dark:text-white">FTP Accounts</h1>
          <p class="mt-1 text-sm text-gray-500 dark:text-gray-400">
            Manage FTP access across all your domains.
          </p>
        </div>

        <HostctlWeb.ResourceComponents.domain_scope
          domains={@domains}
          selected_domain_id={@selected_domain_id}
          id="ftp-scope"
        />
        <.form
          for={to_form(%{"query" => @query, "account_scope" => @account_scope})}
          id="ftp-filters"
          phx-change="filter_accounts"
          class="ui-filterbar"
        >
          <.input name="query" value={@query} type="search" label="Search logins" phx-debounce="200" />
          <.input
            name="account_scope"
            value={@account_scope}
            type="select"
            label="Account scope"
            options={[{"All accounts", "all"}, {"Single-domain", "single"}, {"Shared", "shared"}]}
          />
        </.form>
        <%!-- Create new account --%>
        <details id="ftp-create-panel" class="ui-panel ui-disclosure">
          <summary>Create FTP account <span>One directory or multiple websites</span></summary>
          <div class="p-6">
            <.form
              for={@ftp_form}
              id="ftp-form"
              phx-change="validate_ftp"
              phx-submit="save_ftp"
              class="space-y-4"
            >
              <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
                <.input
                  field={@ftp_form[:username]}
                  type="text"
                  placeholder="ftpuser"
                  label="Username"
                />
                <.input field={@ftp_form[:password]} type="password" label="Password" />
              </div>
              <%!-- Access mode toggle --%>
              <div>
                <p class="block text-sm font-semibold leading-6 text-zinc-800 dark:text-zinc-200 mb-2">
                  Directory access
                </p>
                <div class="flex rounded-lg border border-gray-300 dark:border-gray-700 w-fit overflow-hidden">
                  <button
                    type="button"
                    phx-click="set_ftp_mode"
                    phx-value-mode="single"
                    class={[
                      "px-4 py-2 text-xs font-medium transition-colors",
                      if(@ftp_access_mode == "single",
                        do: "bg-indigo-600 text-white",
                        else:
                          "text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-800"
                      )
                    ]}
                  >
                    Single Directory
                  </button>
                  <button
                    type="button"
                    phx-click="set_ftp_mode"
                    phx-value-mode="multi"
                    class={[
                      "px-4 py-2 text-xs font-medium transition-colors border-l border-gray-300 dark:border-gray-700",
                      if(@ftp_access_mode == "multi",
                        do: "bg-indigo-600 text-white",
                        else:
                          "text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-800"
                      )
                    ]}
                  >
                    Multi-Domain Virtual Root
                  </button>
                </div>
              </div>
              <%= if @ftp_access_mode == "single" do %>
                <.input
                  field={@ftp_form[:home_dir]}
                  type="select"
                  label="Home directory"
                  options={@ftp_dir_options}
                />
              <% else %>
                <div>
                  <p class="block text-sm font-semibold leading-6 text-zinc-800 dark:text-zinc-200 mb-2">
                    Select directories to expose
                  </p>
                  <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-2">
                    <%= for {label, path} <- @ftp_dir_options do %>
                      <label class="flex items-center gap-2 p-2 rounded-lg border border-gray-200 dark:border-gray-700 hover:bg-gray-50 dark:hover:bg-gray-800 cursor-pointer">
                        <input
                          type="checkbox"
                          name="ftp_account[mount_paths][]"
                          value={path}
                          class="rounded border-gray-300 text-indigo-600 focus:ring-indigo-500"
                        />
                        <span class="text-sm text-gray-700 dark:text-gray-300">{label}</span>
                      </label>
                    <% end %>
                  </div>
                </div>
              <% end %>
              <div class="flex justify-end">
                <button
                  type="submit"
                  class="px-4 py-2 bg-indigo-600 hover:bg-indigo-700 text-white text-sm font-medium rounded-lg transition-colors"
                >
                  Create FTP Account
                </button>
              </div>
            </.form>
          </div>
        </details>

        <%!-- Accounts list --%>
        <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800">
          <div class="px-6 py-4 border-b border-gray-200 dark:border-gray-800">
            <h3 class="text-base font-semibold text-gray-900 dark:text-white">All Accounts</h3>
          </div>
          <div
            id="ftp-accounts"
            phx-update="stream"
            class="divide-y divide-gray-100 dark:divide-gray-800"
          >
            <div
              id="ftp-empty"
              class="hidden only:flex items-center justify-center py-10 text-sm text-gray-400"
            >
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
                  class="space-y-3"
                >
                  <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
                    <div>
                      <p class="text-xs text-gray-500 mb-1">Username</p>
                      <p class="text-sm font-medium text-gray-900 dark:text-white">
                        {account.username}
                        <span class="ml-2 text-xs font-normal text-gray-400">
                          {if @current_scope.user.role != "client" and account.user,
                            do: account.user.email}
                        </span>
                      </p>
                    </div>
                    <.input
                      field={@ftp_edit_form[:password]}
                      type="password"
                      label="New password (optional)"
                    />
                  </div>
                  <%!-- Access mode toggle --%>
                  <div>
                    <p class="block text-sm font-semibold leading-6 text-zinc-800 dark:text-zinc-200 mb-2">
                      Directory access
                    </p>
                    <div class="flex rounded-lg border border-gray-300 dark:border-gray-700 w-fit overflow-hidden">
                      <button
                        type="button"
                        phx-click="set_ftp_edit_mode"
                        phx-value-mode="single"
                        class={[
                          "px-4 py-2 text-xs font-medium transition-colors",
                          if(@ftp_edit_access_mode == "single",
                            do: "bg-indigo-600 text-white",
                            else:
                              "text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-800"
                          )
                        ]}
                      >
                        Single Directory
                      </button>
                      <button
                        type="button"
                        phx-click="set_ftp_edit_mode"
                        phx-value-mode="multi"
                        class={[
                          "px-4 py-2 text-xs font-medium transition-colors border-l border-gray-300 dark:border-gray-700",
                          if(@ftp_edit_access_mode == "multi",
                            do: "bg-indigo-600 text-white",
                            else:
                              "text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-800"
                          )
                        ]}
                      >
                        Multi-Domain Virtual Root
                      </button>
                    </div>
                  </div>
                  <%= if @ftp_edit_access_mode == "single" do %>
                    <.input
                      field={@ftp_edit_form[:home_dir]}
                      type="select"
                      label="Home directory"
                      options={@ftp_dir_options}
                    />
                  <% else %>
                    <div>
                      <p class="block text-sm font-semibold leading-6 text-zinc-800 dark:text-zinc-200 mb-2">
                        Select directories to expose
                      </p>
                      <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-2">
                        <%= for {label, path} <- @ftp_dir_options do %>
                          <label class="flex items-center gap-2 p-2 rounded-lg border border-gray-200 dark:border-gray-700 hover:bg-gray-50 dark:hover:bg-gray-800 cursor-pointer">
                            <input
                              type="checkbox"
                              name="ftp_account[mount_paths][]"
                              value={path}
                              checked={path in @ftp_edit_selected_paths}
                              class="rounded border-gray-300 text-indigo-600 focus:ring-indigo-500"
                            />
                            <span class="text-sm text-gray-700 dark:text-gray-300">{label}</span>
                          </label>
                        <% end %>
                      </div>
                    </div>
                  <% end %>
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
                    <div class="flex items-center gap-2">
                      <p class="text-sm font-medium text-gray-900 dark:text-white">
                        {account.username}
                      </p>
                      <%= if @current_scope.user.role != "client" and account.user do %>
                        <span class="text-xs text-gray-400 dark:text-gray-500">
                          {account.user.email}
                        </span>
                      <% end %>
                    </div>
                    <% accessible_domains = ResourceScope.ftp_domains(account, @domains) %>
                    <span
                      :if={length(accessible_domains) > 1}
                      id={"ftp-shared-#{account.id}"}
                      class="inline-flex rounded bg-indigo-50 px-2 py-1 text-xs text-indigo-700 dark:bg-indigo-950 dark:text-indigo-300"
                    >
                      Shared · {length(accessible_domains)} domains
                    </span>
                    <p class="text-xs text-gray-500">
                      {Enum.map_join(accessible_domains, ", ", & &1.name)}
                    </p>
                    <%= if account.mounts && account.mounts != [] do %>
                      <p class="text-xs text-gray-500">
                        Directories: {Enum.map_join(account.mounts, ", ", & &1["path"])}
                      </p>
                    <% else %>
                      <p class="text-xs text-gray-500">{account.home_dir || "/"}</p>
                    <% end %>
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
                      Manage
                    </button>
                    <button
                      phx-click="delete_ftp"
                      phx-value-id={account.id}
                      data-confirm="Delete this FTP login and remove its access to every assigned directory? Website files are not deleted."
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
      </div>
    </Layouts.app>
    """
  end
end
