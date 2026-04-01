defmodule Hostctl.Plesk.Importer do
  @moduledoc """
  Imports domain inventory from Plesk backups or the Plesk REST API.

  This module is intentionally conservative:
  - It only creates missing domains in Hostctl.
  - It never updates or deletes existing Hostctl domains.
  - It supports dry-run previews before writing anything.
  """

  alias Hostctl.Accounts.Scope
  alias Hostctl.Hosting

  @domain_info_regex ~r/<domain-info[^>]*\sname="([^"]+)"/

  @doc """
  Extracts domain names from an extracted Plesk backup folder.

  Preferred source is `.discovered/*/object_index` because it is compact and fast.
  Falls back to scanning the root `backup_info_*.xml` file.
  """
  def backup_domain_names(backup_path) when is_binary(backup_path) do
    with {:ok, subscriptions} <- backup_subscriptions(backup_path) do
      {:ok, subscriptions |> Enum.map(& &1.domain) |> Enum.uniq() |> Enum.sort()}
    end
  end

  @doc """
  Extracts domain subscriptions from an extracted Plesk backup folder.

  Returns a list of maps:

      %{domain: "example.com", owner_login: "admin", owner_type: "admin", system_user: "example"}

  If only XML fallback data is available, owner/system fields are nil.
  """
  def backup_subscriptions(backup_path) when is_binary(backup_path) do
    with :ok <- ensure_directory(backup_path) do
      object_index_subscriptions =
        backup_path
        |> object_index_paths()
        |> Enum.flat_map(fn path ->
          case File.read(path) do
            {:ok, content} -> subscriptions_from_object_index_content(content)
            _ -> []
          end
        end)

      if object_index_subscriptions != [] do
        {:ok,
         object_index_subscriptions
         |> Enum.uniq_by(& &1.domain)
         |> Enum.sort_by(& &1.domain)}
      else
        from_root_backup_info_xml_subscriptions(backup_path)
      end
    end
  end

  @doc """
  Extracts domain names from Plesk API response at `/api/v2/domains`.
  """
  def api_domain_names(api_url, auth_opts \\ []) when is_binary(api_url) and is_list(auth_opts) do
    url = normalize_api_url(api_url)

    headers =
      [{"accept", "application/json"}]
      |> Kernel.++(auth_headers(auth_opts))

    case Req.get(url: url <> "/api/v2/domains", headers: headers) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        names = domain_names_from_api_response(body)

        if names == [] do
          {:error, "No domain names were found in Plesk API response."}
        else
          {:ok, names}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "Plesk API request failed with HTTP #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Plesk API request failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Imports domains from an extracted Plesk backup into a Hostctl user scope.

  Options:
    - `:dry_run` (default: true)
    - `:apply_dns_template` (default: false)
  """
  def import_from_backup(%Scope{} = scope, backup_path, opts \\ []) do
    with {:ok, domain_names} <- backup_domain_names(backup_path) do
      import_domains(scope, domain_names, opts)
    end
  end

  @doc """
  Imports domains discovered from Plesk API into a Hostctl user scope.

  Options:
    - `:dry_run` (default: true)
    - `:apply_dns_template` (default: false)
  """
  def import_from_api(%Scope{} = scope, api_url, auth_opts, opts \\ [])
      when is_binary(api_url) and is_list(auth_opts) and is_list(opts) do
    with {:ok, domain_names} <- api_domain_names(api_url, auth_opts) do
      import_domains(scope, domain_names, opts)
    end
  end

  @doc """
  Imports a set of domain names into a Hostctl scope.
  """
  def import_domains(%Scope{} = scope, domain_names, opts \\ []) when is_list(domain_names) do
    dry_run = Keyword.get(opts, :dry_run, true)
    apply_dns_template = Keyword.get(opts, :apply_dns_template, false)

    normalized_names =
      domain_names
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.sort()

    existing_names =
      scope
      |> Hosting.list_domains()
      |> Enum.map(& &1.name)
      |> MapSet.new()

    initial = %{created: [], planned: [], skipped_existing: [], failed: []}

    result =
      Enum.reduce(normalized_names, initial, fn name, acc ->
        cond do
          MapSet.member?(existing_names, name) ->
            %{acc | skipped_existing: [name | acc.skipped_existing]}

          dry_run ->
            %{acc | planned: [name | acc.planned]}

          true ->
            attrs = %{name: name, apply_dns_template: apply_dns_template}

            case Hosting.create_domain(scope, attrs) do
              {:ok, _domain} ->
                %{acc | created: [name | acc.created]}

              {:error, changeset} ->
                message = changeset_error_summary(changeset)
                %{acc | failed: ["#{name}: #{message}" | acc.failed]}
            end
        end
      end)

    {:ok,
     %{
       dry_run: dry_run,
       total_input: length(normalized_names),
       planned_count: length(result.planned),
       created_count: length(result.created),
       skipped_existing_count: length(result.skipped_existing),
       failed_count: length(result.failed),
       planned: Enum.reverse(result.planned),
       created: Enum.reverse(result.created),
       skipped_existing: Enum.reverse(result.skipped_existing),
       failed: Enum.reverse(result.failed)
     }}
  end

  @doc """
  Imports domains and subdomains from subscriptions with merged subdomain data.

  This function creates parent domains first, then creates subdomains under them.
  Subscriptions should already have subdomains merged via `SSHProbe.merge_subdomains/1`.

  Options:
    - `:dry_run` (default: true)
    - `:apply_dns_template` (default: false)
  """
  def import_subscriptions(%Scope{} = scope, subscriptions, opts \\ [])
      when is_list(subscriptions) do
    dry_run = Keyword.get(opts, :dry_run, true)

    # Import parent domains
    domain_names = Enum.map(subscriptions, & &1.domain)
    {:ok, domain_result} = import_domains(scope, domain_names, opts)

    # Collect all subdomains with their parent domain reference
    all_subdomains =
      Enum.flat_map(subscriptions, fn sub ->
        sub
        |> Map.get(:subdomains, [])
        |> Enum.map(&Map.put(&1, :parent_domain, sub.domain))
      end)

    subdomain_result =
      if dry_run do
        %{
          planned: Enum.map(all_subdomains, & &1.full_name),
          planned_count: length(all_subdomains),
          created: [],
          created_count: 0,
          skipped: [],
          skipped_count: 0,
          failed: [],
          failed_count: 0
        }
      else
        do_import_subdomains(scope, all_subdomains)
      end

    {:ok, Map.put(domain_result, :subdomain_result, subdomain_result)}
  end

  defp do_import_subdomains(scope, subdomains) do
    initial = %{created: [], skipped: [], failed: []}

    result =
      Enum.reduce(subdomains, initial, fn sub, acc ->
        parent_domain = Hosting.get_domain_by_name(scope, sub.parent_domain)

        cond do
          is_nil(parent_domain) ->
            msg = "#{sub.full_name}: parent domain #{sub.parent_domain} not found"
            %{acc | failed: [msg | acc.failed]}

          subdomain_exists?(parent_domain, sub.name) ->
            %{acc | skipped: [sub.full_name | acc.skipped]}

          true ->
            case Hosting.create_subdomain(parent_domain, %{name: sub.name}) do
              {:ok, _subdomain} ->
                %{acc | created: [sub.full_name | acc.created]}

              {:error, changeset} ->
                message = changeset_error_summary(changeset)
                %{acc | failed: ["#{sub.full_name}: #{message}" | acc.failed]}
            end
        end
      end)

    %{
      planned: [],
      planned_count: 0,
      created: Enum.reverse(result.created),
      created_count: length(result.created),
      skipped: Enum.reverse(result.skipped),
      skipped_count: length(result.skipped),
      failed: Enum.reverse(result.failed),
      failed_count: length(result.failed)
    }
  end

  defp subdomain_exists?(domain, subdomain_name) do
    domain
    |> Hosting.list_subdomains()
    |> Enum.any?(&(&1.name == subdomain_name))
  end

  @doc false
  def domains_from_object_index_content(content) when is_binary(content) do
    content
    |> subscriptions_from_object_index_content()
    |> Enum.map(& &1.domain)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc false
  def subscriptions_from_object_index_content(content) when is_binary(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, "\t", trim: false) do
        ["subscription", domain, _guid, owner_login, owner_type, system_user | _rest]
        when is_binary(domain) and domain != "" ->
          [
            %{
              domain: domain,
              owner_login: normalize_blank(owner_login),
              owner_type: normalize_blank(owner_type),
              system_user: normalize_blank(system_user)
            }
          ]

        ["subscription", domain | _rest] when is_binary(domain) and domain != "" ->
          [%{domain: domain, owner_login: nil, owner_type: nil, system_user: nil}]

        _ ->
          []
      end
    end)
    |> Enum.uniq_by(& &1.domain)
    |> Enum.sort_by(& &1.domain)
  end

  @doc false
  def domains_from_xml_content(content) when is_binary(content) do
    @domain_info_regex
    |> Regex.scan(content, capture: :all_but_first)
    |> Enum.map(fn [domain] -> domain end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc false
  def domain_names_from_api_response(body) do
    body
    |> extract_api_domain_items()
    |> Enum.flat_map(fn item ->
      case item do
        %{"name" => name} when is_binary(name) and name != "" -> [name]
        %{name: name} when is_binary(name) and name != "" -> [name]
        _ -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp from_root_backup_info_xml_subscriptions(backup_path) do
    backup_info_path =
      Path.wildcard(Path.join(backup_path, "backup_info_*.xml"))
      |> Enum.sort()
      |> List.first()

    if is_nil(backup_info_path) do
      {:error,
       "Could not find any .discovered object_index or root backup_info_*.xml in #{backup_path}."}
    else
      with {:ok, content} <- File.read(backup_info_path) do
        names = domains_from_xml_content(content)

        subscriptions =
          names
          |> Enum.map(fn domain ->
            %{domain: domain, owner_login: nil, owner_type: nil, system_user: nil}
          end)

        if names == [] do
          {:error, "No <domain-info> entries were found in #{backup_info_path}."}
        else
          {:ok, subscriptions}
        end
      else
        {:error, reason} ->
          {:error, "Unable to read #{backup_info_path}: #{inspect(reason)}"}
      end
    end
  end

  defp object_index_paths(backup_path) do
    Path.wildcard(Path.join([backup_path, ".discovered", "*", "object_index"]))
  end

  defp ensure_directory(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, _} -> {:error, "#{path} is not a directory."}
      {:error, reason} -> {:error, "Cannot access #{path}: #{inspect(reason)}"}
    end
  end

  defp normalize_api_url(url) do
    url
    |> String.trim()
    |> String.trim_trailing("/")
  end

  defp auth_headers(auth_opts) do
    api_key = Keyword.get(auth_opts, :api_key)
    username = Keyword.get(auth_opts, :username)
    password = Keyword.get(auth_opts, :password)

    cond do
      is_binary(api_key) and api_key != "" ->
        [{"x-api-key", api_key}]

      is_binary(username) and username != "" and is_binary(password) and password != "" ->
        token = Base.encode64("#{username}:#{password}")
        [{"authorization", "Basic " <> token}]

      true ->
        []
    end
  end

  defp extract_api_domain_items(body) when is_list(body), do: body

  defp extract_api_domain_items(body) when is_map(body) do
    cond do
      is_list(body["data"]) -> body["data"]
      is_list(body[:data]) -> body[:data]
      is_list(body["domains"]) -> body["domains"]
      is_list(body[:domains]) -> body[:domains]
      is_list(body["result"]) -> body["result"]
      is_list(body[:result]) -> body[:result]
      true -> []
    end
  end

  defp extract_api_domain_items(_), do: []

  defp normalize_blank(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_blank(_), do: nil

  defp changeset_error_summary(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.flat_map(fn {field, messages} ->
      Enum.map(messages, fn message -> "#{field} #{message}" end)
    end)
    |> case do
      [] -> "unknown validation error"
      messages -> Enum.join(messages, "; ")
    end
  end
end
