defmodule HostctlWeb.Router do
  use HostctlWeb, :router

  import HostctlWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {HostctlWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :dev_auth do
    plug :dev_basic_auth
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:hostctl, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:browser, :dev_auth]

      live_dashboard "/dashboard", metrics: HostctlWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", HostctlWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{HostctlWeb.UserAuth, :require_authenticated}] do
      # User settings
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email

      # Dashboard
      live "/", DashboardLive, :index

      # Domains
      live "/domains", DomainLive.Index, :index
      live "/domains/new", DomainLive.Index, :new
      live "/domains/:id", DomainLive.Show, :show
      live "/domains/:domain_id/dns", DnsLive.Index, :index

      # Email
      live "/email", EmailLive.Index, :index

      # Databases
      live "/databases", DatabaseLive.Index, :index

      # FTP
      live "/ftp", DomainLive.Index, :index

      # Cron
      live "/cron", DomainLive.Index, :index

      # Updates
      live "/updates", UpdatesLive, :index
    end

    live_session :require_admin_or_reseller,
      on_mount: [{HostctlWeb.UserAuth, :require_admin_or_reseller}] do
      live "/users/new", UserLive.Registration, :new

      # Panel users management (admin + reseller)
      live "/panel/users", PanelLive.Users, :index
    end

    live_session :require_admin,
      on_mount: [{HostctlWeb.UserAuth, :require_admin}] do
      # Panel settings (admin only)
      live "/panel/settings", PanelLive.Settings, :index
      live "/panel/features", PanelLive.Features, :index
      live "/panel/smarthost", PanelLive.Smarthost, :index
      live "/panel/databases", PanelLive.Databases, :index
      live "/panel/emails", PanelLive.Emails, :index
      live "/panel/backup", PanelLive.Backup, :index
      live "/panel/backups", PanelLive.CompletedBackups, :index
    end

    get "/panel/backups/:id/download", BackupDownloadController, :show

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", HostctlWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{HostctlWeb.UserAuth, :mount_current_scope}] do
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
      live "/setup/:token", SetupLive, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end

  defp dev_basic_auth(conn, _opts) do
    credentials =
      Application.get_env(:hostctl, :dev_basic_auth, username: "admin", password: "changeme!")

    Plug.BasicAuth.basic_auth(conn, credentials)
  end
end
