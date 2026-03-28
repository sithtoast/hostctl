defmodule Hostctl.DNS.Cloudflare do
  @moduledoc """
  Cloudflare DNS API client.

  All functions require a valid API token with DNS edit permissions.
  Uses the Cloudflare v4 API: https://api.cloudflare.com/client/v4
  """

  @base_url "https://api.cloudflare.com/client/v4"

  # ---------------------------------------------------------------------------
  # Zone management
  # ---------------------------------------------------------------------------

  @doc """
  Look up a Cloudflare zone by domain name.

  Returns `{:ok, zone_id}` if found, `{:error, reason}` otherwise.
  """
  def find_zone(api_token, domain_name) do
    case get(api_token, "/zones", params: [name: domain_name]) do
      {:ok, %{"result" => [%{"id" => zone_id} | _]}} ->
        {:ok, zone_id}

      {:ok, %{"result" => []}} ->
        {:error, :zone_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  List all DNS records for a Cloudflare zone.

  Returns `{:ok, [record]}` or `{:error, reason}`.
  """
  def list_records(api_token, cloudflare_zone_id) do
    case get(api_token, "/zones/#{cloudflare_zone_id}/dns_records", params: [per_page: 500]) do
      {:ok, %{"result" => records}} -> {:ok, records}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Record CRUD
  # ---------------------------------------------------------------------------

  @doc """
  Creates a DNS record on Cloudflare.

  Returns `{:ok, cloudflare_record_id}` or `{:error, reason}`.
  """
  def create_record(api_token, cloudflare_zone_id, record) do
    body = build_record_body(record)

    case post(api_token, "/zones/#{cloudflare_zone_id}/dns_records", body) do
      {:ok, %{"result" => %{"id" => record_id}}} -> {:ok, record_id}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Updates an existing DNS record on Cloudflare.

  Returns `:ok` or `{:error, reason}`.
  """
  def update_record(api_token, cloudflare_zone_id, cloudflare_record_id, record) do
    body = build_record_body(record)

    case put(api_token, "/zones/#{cloudflare_zone_id}/dns_records/#{cloudflare_record_id}", body) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Deletes a DNS record from Cloudflare.

  Returns `:ok` or `{:error, reason}`.
  """
  def delete_record(api_token, cloudflare_zone_id, cloudflare_record_id) do
    case delete(api_token, "/zones/#{cloudflare_zone_id}/dns_records/#{cloudflare_record_id}") do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Verifies that the API token has sufficient permissions by checking /user/tokens/verify.

  Returns `{:ok, :valid}` or `{:error, reason}`.
  """
  def verify_token(api_token) do
    case get(api_token, "/user/tokens/verify") do
      {:ok, %{"result" => %{"status" => "active"}}} -> {:ok, :valid}
      {:ok, _} -> {:error, :token_invalid}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp build_record_body(record) do
    body = %{
      "type" => record.type,
      "name" => record.name,
      "content" => record.value,
      "ttl" => record.ttl || 3600
    }

    if record.priority do
      Map.put(body, "priority", record.priority)
    else
      body
    end
  end

  defp auth_headers(api_token) do
    [{"Authorization", "Bearer #{api_token}"}, {"Content-Type", "application/json"}]
  end

  defp get(api_token, path, opts \\ []) do
    params = Keyword.get(opts, :params, [])

    Req.get(@base_url <> path,
      params: params,
      headers: auth_headers(api_token)
    )
    |> handle_response()
  end

  defp post(api_token, path, body) do
    Req.post(@base_url <> path,
      json: body,
      headers: auth_headers(api_token)
    )
    |> handle_response()
  end

  defp put(api_token, path, body) do
    Req.put(@base_url <> path,
      json: body,
      headers: auth_headers(api_token)
    )
    |> handle_response()
  end

  defp delete(api_token, path) do
    Req.delete(@base_url <> path,
      headers: auth_headers(api_token)
    )
    |> handle_response()
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}})
       when status in 200..299 do
    {:ok, body}
  end

  defp handle_response({:ok, %Req.Response{body: %{"errors" => [%{"message" => msg} | _]}}}) do
    {:error, msg}
  end

  defp handle_response({:ok, %Req.Response{status: status}}) do
    {:error, "HTTP #{status}"}
  end

  defp handle_response({:error, exception}) do
    {:error, Exception.message(exception)}
  end
end
