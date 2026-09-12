defmodule Hostctl.DNS.Cloudflare do
  @moduledoc """
  Cloudflare DNS API client.

  All functions require a valid API token with DNS edit permissions.
  Uses the Cloudflare v4 API: https://api.cloudflare.com/client/v4
  """

  alias Hostctl.DNS.Record

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
    list_record_pages(api_token, cloudflare_zone_id, 1, [])
  end

  defp list_record_pages(api_token, zone_id, page, acc) do
    case get(api_token, "/zones/#{zone_id}/dns_records", params: [per_page: 500, page: page]) do
      {:ok, %{"result" => records} = body} ->
        pages = get_in(body, ["result_info", "total_pages"]) || 1

        if page < pages do
          list_record_pages(api_token, zone_id, page + 1, acc ++ records)
        else
          {:ok, acc ++ records}
        end

      {:error, reason} ->
        {:error, reason}
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
    with {:ok, body} <- Record.body(record),
         {:ok, %{"result" => %{"id" => record_id}}} <-
           post(api_token, "/zones/#{cloudflare_zone_id}/dns_records", body) do
      {:ok, record_id}
    end
  end

  @doc """
  Updates an existing DNS record on Cloudflare.

  Returns `:ok` or `{:error, reason}`.
  """
  def update_record(api_token, cloudflare_zone_id, cloudflare_record_id, record) do
    with {:ok, body} <- Record.body(record),
         {:ok, _} <-
           request(
             api_token,
             :patch,
             "/zones/#{cloudflare_zone_id}/dns_records/#{cloudflare_record_id}",
             json: body
           ) do
      :ok
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

  defp get(api_token, path, opts \\ []), do: request(api_token, :get, path, opts)
  defp post(api_token, path, body), do: request(api_token, :post, path, json: body)
  defp delete(api_token, path), do: request(api_token, :delete, path, [])

  defp request(api_token, method, path, opts) do
    Application.get_env(:hostctl, :cloudflare_request_options, [])
    |> Keyword.merge(opts)
    |> Keyword.merge(
      method: method,
      url: @base_url <> path,
      headers: [{"Authorization", "Bearer #{api_token}"}, {"Content-Type", "application/json"}]
    )
    |> Req.request()
    |> handle_response()
  end

  defp handle_response({:ok, %Req.Response{body: %{"success" => false} = body}}) do
    {:error, get_in(body, ["errors", Access.at(0), "message"]) || "Cloudflare request failed"}
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
