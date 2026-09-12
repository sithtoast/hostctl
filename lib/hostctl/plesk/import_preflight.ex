defmodule Hostctl.Plesk.ImportPreflight do
  @moduledoc "Installs required hosting components before any domain import mutations."
  alias Hostctl.FeatureSetup

  def required_features(categories, inventory, s3_targets) do
    ftp? = "ftp_accounts" in categories
    mail? = Enum.any?(["mail_accounts", "mail_content"], &(&1 in categories))
    databases? = Enum.any?(["databases", "db_users"], &(&1 in categories))
    dbs = Map.get(inventory, "databases", []) ++ Map.get(inventory, "db_users", [])

    mysql? =
      databases? and Enum.any?(dbs, &(db_type(&1) not in ["postgresql", "postgres", "pgsql"]))

    pg? = databases? and Enum.any?(dbs, &(db_type(&1) in ["postgresql", "postgres", "pgsql"]))

    mount? =
      "web_files" in categories and is_map(s3_targets) and
        Enum.any?(
          Map.values(s3_targets),
          &(is_map(&1) and Map.get(&1, :ftp_mount_enabled, false))
        )

    []
    |> add(ftp? or mount?, "ftp")
    |> add(mail?, "email")
    |> add(mysql?, "mysql")
    |> add(pg?, "postgresql")
    |> add(mount?, "rclone")
    |> add("statistics" in categories, "goaccess")
  end

  def run(categories, inventory, targets, progress, installer \\ &FeatureSetup.ensure_installed/1) do
    required_features(categories, inventory, targets)
    |> Enum.reduce_while(:ok, fn key, :ok ->
      progress.(key)

      case installer.(key) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, "#{key} prerequisite failed: #{inspect(reason)}"}}
        _ -> {:halt, {:error, "#{key} prerequisite did not complete"}}
      end
    end)
  end

  defp db_type(item), do: Map.get(item, :db_type) || Map.get(item, "db_type") || "mysql"
  defp add(keys, true, key), do: keys ++ [key]
  defp add(keys, false, _), do: keys
end
