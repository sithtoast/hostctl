defmodule Mix.Tasks.Hostctl.Plesk.Import do
  use Mix.Task

  alias Hostctl.Accounts
  alias Hostctl.Accounts.Scope
  alias Hostctl.Hosting
  alias Hostctl.Plesk.Importer

  @shortdoc "Import domains from Plesk backup/API"

  @moduledoc """
  Imports domain inventory from Plesk into Hostctl.

  Examples:

      mix hostctl.plesk.import --source backup --backup-path /path/to/extracted_backup
      mix hostctl.plesk.import --source backup --backup-path /path --user-email admin@example.com --apply
      mix hostctl.plesk.import --source api --api-url https://plesk.example.com:8443 --api-key YOUR_KEY
      mix hostctl.plesk.import --source api --api-url https://plesk.example.com:8443 --api-key YOUR_KEY --user-email admin@example.com --apply

  Notes:
  - Without `--apply`, this task is a dry-run preview.
  - With `--apply`, `--user-email` is required and only missing domains are created.
  """

  @switches [
    source: :string,
    backup_path: :string,
    api_url: :string,
    api_key: :string,
    username: :string,
    password: :string,
    user_email: :string,
    owner_login: :string,
    system_user: :string,
    apply: :boolean,
    apply_dns_template: :boolean
  ]

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    source = opts[:source] || "backup"
    apply? = opts[:apply] == true

    case {source, apply?} do
      {"backup", false} ->
        run_backup_preview(opts)

      {"backup", true} ->
        run_backup_apply(opts)

      {"api", false} ->
        run_api_preview(opts)

      {"api", true} ->
        run_api_apply(opts)

      _ ->
        Mix.raise("--source must be one of: backup, api")
    end
  end

  defp run_backup_preview(opts) do
    backup_path = required_opt!(opts, :backup_path)

    case Importer.backup_subscriptions(backup_path) do
      {:ok, subscriptions} ->
        subscriptions = filter_subscriptions(subscriptions, opts)
        names = subscriptions |> Enum.map(& &1.domain) |> Enum.sort()
        print_backup_preview(names, subscriptions, maybe_scope(opts))

      {:error, reason} ->
        Mix.raise(reason)
    end
  end

  defp run_backup_apply(opts) do
    backup_path = required_opt!(opts, :backup_path)
    scope = required_scope!(opts)

    case Importer.backup_subscriptions(backup_path) do
      {:ok, subscriptions} ->
        subscriptions = filter_subscriptions(subscriptions, opts)
        names = subscriptions |> Enum.map(& &1.domain) |> Enum.sort()

        case Importer.import_domains(scope, names,
               dry_run: false,
               apply_dns_template: opts[:apply_dns_template] == true
             ) do
          {:ok, result} ->
            print_apply_result(result)
        end

      {:error, reason} ->
        Mix.raise(reason)
    end
  end

  defp run_api_preview(opts) do
    api_url = required_opt!(opts, :api_url)

    case Importer.api_domain_names(api_url, auth_opts(opts)) do
      {:ok, names} ->
        print_preview(names, maybe_scope(opts))

      {:error, reason} ->
        Mix.raise(reason)
    end
  end

  defp run_api_apply(opts) do
    api_url = required_opt!(opts, :api_url)
    scope = required_scope!(opts)

    case Importer.import_from_api(scope, api_url, auth_opts(opts),
           dry_run: false,
           apply_dns_template: opts[:apply_dns_template] == true
         ) do
      {:ok, result} ->
        print_apply_result(result)

      {:error, reason} ->
        Mix.raise(reason)
    end
  end

  defp maybe_scope(opts) do
    case opts[:user_email] do
      nil ->
        nil

      email ->
        case Accounts.get_user_by_email(email) do
          nil ->
            Mix.shell().error(
              "Warning: user not found for --user-email #{email}; showing raw preview."
            )

            nil

          user ->
            Scope.for_user(user)
        end
    end
  end

  defp required_scope!(opts) do
    email = required_opt!(opts, :user_email)

    case Accounts.get_user_by_email(email) do
      nil -> Mix.raise("No user found for --user-email #{email}")
      user -> Scope.for_user(user)
    end
  end

  defp required_opt!(opts, key) do
    value = opts[key]

    if is_binary(value) and String.trim(value) != "" do
      value
    else
      Mix.raise("Missing required option --#{key}")
    end
  end

  defp auth_opts(opts) do
    [api_key: opts[:api_key], username: opts[:username], password: opts[:password]]
  end

  defp print_preview(names, nil) do
    Mix.shell().info("Preview mode: #{length(names)} domains found in source.")
    print_name_sample(names)

    Mix.shell().info(
      "Tip: pass --user-email to also show already-existing domains for that user."
    )
  end

  defp print_preview(names, %Scope{} = scope) do
    existing =
      scope
      |> Hosting.list_domains()
      |> Enum.map(& &1.name)
      |> MapSet.new()

    {existing_names, missing_names} = Enum.split_with(names, &MapSet.member?(existing, &1))

    Mix.shell().info("Preview mode: #{length(names)} domains found in source.")
    Mix.shell().info("Already in Hostctl for user: #{length(existing_names)}")
    Mix.shell().info("Would be created: #{length(missing_names)}")

    if missing_names != [] do
      Mix.shell().info("Sample to create:")
      print_name_sample(missing_names)
    end
  end

  defp print_backup_preview(names, subscriptions, scope) do
    print_preview(names, scope)

    owner_groups =
      subscriptions
      |> Enum.group_by(fn sub -> {sub.owner_login, sub.owner_type, sub.system_user} end)
      |> Enum.sort_by(fn {{owner_login, _owner_type, _system_user}, _subs} ->
        owner_login || ""
      end)

    Mix.shell().info("Ownership/system-user groups: #{length(owner_groups)}")

    owner_groups
    |> Enum.take(20)
    |> Enum.each(fn {{owner_login, owner_type, system_user}, subs} ->
      Mix.shell().info(
        "- owner=#{owner_login || "unknown"} type=#{owner_type || "unknown"} system_user=#{system_user || "unknown"} domains=#{length(subs)}"
      )
    end)

    if length(owner_groups) > 20 do
      Mix.shell().info("... and #{length(owner_groups) - 20} more ownership groups")
    end
  end

  defp print_apply_result(result) do
    Mix.shell().info("Import complete.")
    Mix.shell().info("Total input: #{result.total_input}")
    Mix.shell().info("Created: #{result.created_count}")
    Mix.shell().info("Skipped existing: #{result.skipped_existing_count}")
    Mix.shell().info("Failed: #{result.failed_count}")

    if result.failed_count > 0 do
      Mix.shell().error("Failures:")
      Enum.each(result.failed, &Mix.shell().error("- " <> &1))
    end
  end

  defp print_name_sample(names) do
    names
    |> Enum.take(20)
    |> Enum.each(&Mix.shell().info("- " <> &1))

    if length(names) > 20 do
      Mix.shell().info("... and #{length(names) - 20} more")
    end
  end

  defp filter_subscriptions(subscriptions, opts) do
    owner_login_filter = normalize_filter_value(opts[:owner_login])
    system_user_filter = normalize_filter_value(opts[:system_user])

    Enum.filter(subscriptions, fn sub ->
      owner_ok? =
        is_nil(owner_login_filter) or String.downcase(sub.owner_login || "") == owner_login_filter

      system_ok? =
        is_nil(system_user_filter) or String.downcase(sub.system_user || "") == system_user_filter

      owner_ok? and system_ok?
    end)
  end

  defp normalize_filter_value(nil), do: nil

  defp normalize_filter_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end
end
