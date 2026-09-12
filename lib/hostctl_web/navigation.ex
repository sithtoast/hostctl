defmodule HostctlWeb.Navigation do
  @moduledoc "Shared destinations for the panel navigation and administration overview."

  def hosting do
    [
      {:dashboard, "Overview", "/", "hero-squares-2x2"},
      {:domains, "Domains", "/domains", "hero-globe-alt"},
      {:email, "Email accounts", "/email", "hero-envelope"},
      {:databases, "Databases", "/databases", "hero-circle-stack"},
      {:ftp, "FTP accounts", "/ftp", "hero-folder"},
      {:cron, "Cron jobs", "/cron", "hero-clock"}
    ]
  end

  def groups do
    [
      {:admin_mail, "Email services", "/panel/mail",
       [
         {:panel_spam_protection, "Spam protection", "/panel/spam-protection",
          "hero-shield-check"},
         {:panel_email_delivery, "Delivery & DNS", "/panel/email-delivery",
          "hero-paper-airplane"},
         {:panel_smarthost, "Smarthost", "/panel/smarthost", "hero-envelope-open"},
         {:panel_emails, "All mailboxes", "/panel/emails", "hero-envelope"}
       ]},
      {:admin_backup, "Backups & migration", "/panel/migration",
       [
         {:panel_backup, "Schedules & destinations", "/panel/backup", "hero-arrow-down-tray"},
         {:panel_completed_backups, "Completed backups", "/panel/backups", "hero-archive-box"},
         {:panel_plesk_import, "Plesk import", "/panel/plesk-import",
          "hero-arrow-down-on-square-stack"}
       ]},
      {:admin_system, "System & access", "/panel/system",
       [
         {:panel_resources, "Account resources", "/panel/resources", "hero-cpu-chip"},
         {:updates, "Updates", "/updates", "hero-arrow-up-circle"},
         {:panel_docker, "Docker", "/panel/docker", "hero-cube"},
         {:panel_features, "Features", "/panel/features", "hero-puzzle-piece"},
         {:panel_settings, "Panel settings", "/panel/settings", "hero-adjustments-horizontal"},
         {:panel_users, "Panel users", "/panel/users", "hero-users"},
         {:panel_databases, "All databases", "/panel/databases", "hero-circle-stack"},
         {:panel_ftp, "All FTP accounts", "/panel/ftp", "hero-folder"}
       ]}
    ]
  end

  def title(tab) do
    entries =
      hosting() ++
        Enum.flat_map(groups(), fn {key, label, path, items} ->
          [{key, label, path, ""} | items]
        end)

    case Enum.find(entries, &(elem(&1, 0) == tab)) do
      {_, label, _, _} -> label
      nil -> if(tab == :admin_overview, do: "Administration", else: "Account settings")
    end
  end

  def group_active?(tab, key, items), do: tab == key or Enum.any?(items, &(elem(&1, 0) == tab))
end
