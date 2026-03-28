defmodule HostctlWeb.SetupLive do
  use HostctlWeb, :live_view

  alias Hostctl.Accounts
  alias Hostctl.Accounts.User

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="min-h-screen flex items-center justify-center">
        <div class="w-full max-w-md space-y-8">
          <div class="text-center">
            <div class="inline-flex items-center justify-center w-16 h-16 rounded-2xl bg-brand/10 mb-6">
              <.icon name="hero-server-stack" class="w-8 h-8 text-brand" />
            </div>
            <h1 class="text-3xl font-bold tracking-tight">Welcome to Hostctl</h1>
            <p class="mt-2 text-zinc-500">Create your administrator account to get started.</p>
          </div>

          <%!-- Step 1: setup form --%>
          <.form
            :if={!@setup_complete}
            for={@form}
            id="setup-form"
            phx-submit="save"
            phx-change="validate"
            class="bg-white dark:bg-zinc-900 rounded-2xl shadow-sm border border-zinc-200 dark:border-zinc-800 p-8 space-y-6"
          >
            <.input
              field={@form[:name]}
              type="text"
              label="Your name"
              autocomplete="name"
              placeholder="Jane Smith"
              phx-mounted={JS.focus()}
              required
            />
            <.input
              field={@form[:email]}
              type="email"
              label="Email address"
              autocomplete="username"
              placeholder="you@example.com"
              spellcheck="false"
              required
            />
            <.input
              field={@form[:password]}
              type="password"
              label="Password"
              autocomplete="new-password"
              required
            />
            <.input
              field={@form[:password_confirmation]}
              type="password"
              label="Confirm password"
              autocomplete="new-password"
              required
            />
            <.button phx-disable-with="Creating account…" class="w-full">
              Create administrator account
            </.button>
          </.form>

          <%!-- Step 2: auto-submit login form after account is created --%>
          <.form
            :if={@setup_complete}
            for={@login_form}
            id="setup-login-form"
            action={~p"/users/log-in?_action=confirmed"}
            phx-trigger-action={@setup_complete}
            class="bg-white dark:bg-zinc-900 rounded-2xl shadow-sm border border-zinc-200 dark:border-zinc-800 p-8 text-center space-y-4"
          >
            <input type="hidden" name={@login_form[:token].name} value={@login_form[:token].value} />
            <input type="hidden" name={@login_form[:remember_me].name} value="true" />
            <div class="flex items-center justify-center gap-3 text-brand">
              <.icon name="hero-check-circle" class="w-8 h-8" />
              <span class="text-lg font-semibold">Account created!</span>
            </div>
            <p class="text-zinc-500 text-sm">Logging you into the dashboard…</p>
          </.form>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    cond do
      not valid_setup_token?(token) ->
        {:ok,
         socket
         |> put_flash(:error, "This setup link is invalid or has already been used.")
         |> push_navigate(to: ~p"/users/log-in")}

      not Accounts.setup_needed?() ->
        {:ok,
         socket
         |> put_flash(:info, "Setup is already complete. Please log in.")
         |> push_navigate(to: ~p"/users/log-in")}

      true ->
        changeset = User.setup_changeset(%User{}, %{}, validate_unique: false)

        {:ok,
         socket
         |> assign(:setup_complete, false)
         |> assign(:login_form, to_form(%{}, as: "user"))
         |> assign_form(changeset)}
    end
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    changeset =
      %User{}
      |> User.setup_changeset(params, validate_unique: false)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"user" => params}, socket) do
    case Accounts.setup_admin(params) do
      {:ok, user} ->
        token = Accounts.generate_magic_link_token(user)
        login_form = to_form(%{"token" => token}, as: "user")
        {:noreply, assign(socket, setup_complete: true, login_form: login_form)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, form: to_form(changeset, as: "user"))
  end

  defp valid_setup_token?(token) do
    case Application.get_env(:hostctl, :initial_setup_token) do
      nil -> false
      stored -> Plug.Crypto.secure_compare(stored, token)
    end
  end
end
