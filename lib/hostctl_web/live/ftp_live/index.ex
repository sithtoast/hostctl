defmodule HostctlWeb.FtpLive.Index do
  use HostctlWeb, :live_view

  alias Hostctl.Hosting
  alias Hostctl.Hosting.FtpAccount

  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    domains = Hosting.list_domains(scope)
    ftp_accounts = Hosting.list_all_ftp_accounts(scope)
    ftp_dir_options = build_ftp_dir_options(domains)

    {:ok,
     socket
     |> stream(:ftp_accounts, ftp_accounts)
     |> assign(:page_title, "FTP Accounts")
     |> assign(:active_tab, :ftp)
     |> assign(:domains, domains)
     |> assign(:ftp_dir_options, ftp_dir_options)
     |> assign(:editing_ftp_id, nil)
     |> assign(:ftp_edit_form, nil)
     |> assign(:ftp_access_mode, "single")
     |> assign(:ftp_edit_access_mode, "single")
     |> assign(:ftp_edit_selected_paths, [])
     |> assign_ftp_form()}
  end

  def handle_params(_params, _url, socket) do
    {:noreply, socket}
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
    {domain_id_str, params} = Map.pop(params, "domain_id")
    domain = Enum.find(socket.assigns.domains, &(to_string(&1.id) == domain_id_str))

    if domain do
      params = prepare_ftp_params(params, socket.assigns.ftp_access_mode)

      case Hosting.create_ftp_account(domain, params) do
        {:ok, account} ->
          account = Hosting.get_ftp_account_with_domain!(account.id)

          {:noreply,
           socket
           |> stream_insert(:ftp_accounts, account)
           |> assign_ftp_form()
           |> assign(:ftp_access_mode, "single")
           |> put_flash(:info, "FTP account #{account.username} created.")}

        {:error, changeset} ->
          {:noreply, assign(socket, :ftp_form, to_form(changeset))}
      end
    else
      {:noreply, put_flash(socket, :error, "Please select a domain.")}
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
          updated = Hosting.get_ftp_account_with_domain!(updated.id)

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

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_tab={@active_tab}>
      <div class="space-y-6">
        <%!-- Header --%>
        <div>
          <h1 class="text-2xl font-bold text-gray-900 dark:text-white">FTP Accounts</h1>
          <p class="mt-1 text-sm text-gray-500 dark:text-gray-400">
            Manage FTP access across all your domains.
          </p>
        </div>

        <%!-- Create new account --%>
        <%= if @domains != [] do %>
          <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800">
            <div class="px-6 py-4 border-b border-gray-200 dark:border-gray-800">
              <h3 class="text-base font-semibold text-gray-900 dark:text-white">
                New FTP Account
              </h3>
            </div>
            <div class="p-6">
              <.form
                for={@ftp_form}
                id="ftp-form"
                phx-change="validate_ftp"
                phx-submit="save_ftp"
                class="space-y-4"
              >
                <div class="grid grid-cols-1 gap-3 sm:grid-cols-3">
                  <%!-- Domain picker (plain select — not a changeset field) --%>
                  <div>
                    <label class="block text-sm font-semibold leading-6 text-zinc-800 dark:text-zinc-200 mb-1">
                      Domain
                    </label>
                    <select
                      name="ftp_account[domain_id]"
                      class="mt-1 block w-full rounded-lg border border-gray-300 dark:border-gray-700 bg-white dark:bg-gray-800 text-gray-900 dark:text-white px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500"
                    >
                      <%= for domain <- @domains do %>
                        <option value={domain.id}>{domain.name}</option>
                      <% end %>
                    </select>
                  </div>
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
          </div>
        <% else %>
          <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800 p-8 text-center">
            <.icon name="hero-folder" class="w-10 h-10 mx-auto text-gray-300 dark:text-gray-600 mb-3" />
            <p class="text-sm text-gray-500 dark:text-gray-400">
              Add a domain first before creating FTP accounts.
            </p>
            <.link
              navigate={~p"/domains"}
              class="mt-3 inline-block text-sm text-indigo-500 hover:text-indigo-600 font-medium"
            >
              Go to Domains &rarr;
            </.link>
          </div>
        <% end %>

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
                  class="space-y-3"
                >
                  <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
                    <div>
                      <p class="text-xs text-gray-500 mb-1">Username</p>
                      <p class="text-sm font-medium text-gray-900 dark:text-white">
                        {account.username}
                        <span class="ml-2 text-xs font-normal text-gray-400">
                          {account.domain && account.domain.name}
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
                      <span class="text-xs text-gray-400 dark:text-gray-500">
                        {account.domain && account.domain.name}
                      </span>
                    </div>
                    <%= if account.mounts && account.mounts != [] do %>
                      <p class="text-xs text-gray-500">
                        Virtual: {Enum.map_join(account.mounts, ", ", & &1["name"])}
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
      </div>
    </Layouts.app>
    """
  end
end
