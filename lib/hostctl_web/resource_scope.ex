defmodule HostctlWeb.ResourceScope do
  @moduledoc "Domain selection resolved against authorized domains, never raw path prefixes from the client."
  alias Hostctl.Hosting

  def selected(domains, value) when value in [nil, ""] do
    case domains do
      [domain] -> domain
      _ -> nil
    end
  end

  def selected(_domains, "all"), do: nil

  def selected(domains, value) do
    Enum.find(domains, &(to_string(&1.id) == to_string(value))) ||
      raise Ecto.NoResultsError, queryable: Hosting.Domain
  end

  def ftp_domains(account, domains) do
    paths =
      case account.mounts do
        mounts when is_list(mounts) and mounts != [] -> Enum.map(mounts, & &1["path"])
        _ -> [account.home_dir]
      end

    Enum.filter(domains, fn domain ->
      roots = ["/var/www/#{domain.name}", domain.document_root]
      Enum.any?(paths, fn path -> Enum.any?(roots, &overlap?(path, &1)) end)
    end)
  end

  defp overlap?(a, b) when is_binary(a) and is_binary(b) do
    a = Path.expand(a)
    b = Path.expand(b)
    a == b or String.starts_with?(a, b <> "/") or String.starts_with?(b, a <> "/")
  end

  defp overlap?(_, _), do: false
end
