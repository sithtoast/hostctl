defmodule Hostctl.MailgunClient do
  require Logger

  @moduledoc """
  HTTP client for the Mailgun REST API.

  Used to streamline smarthost configuration by fetching the user's Mailgun
  domain list and creating dedicated SMTP credentials.

  All requests use HTTP Basic Auth with `api:<key>` as the credential pair.
  Credential operations use the region-appropriate base URL:
    - US: https://api.mailgun.net
    - EU: https://api.eu.mailgun.net
  """

  @us_base "https://api.mailgun.net"
  @eu_base "https://api.eu.mailgun.net"

  @doc """
  Lists all sending domains on the account.

  Always queries the US base URL — Mailgun treats domain *names* as global
  account data so this returns domains from both regions.

  Returns `{:ok, [%{name, smtp_login, state}]}` or `{:error, reason}`.
  """
  def list_domains(api_key) do
    Req.get("#{@us_base}/v4/domains", auth: {"api", api_key})
    |> parse(fn body ->
      items = body["items"] || []

      domains =
        Enum.map(items, fn d ->
          %{
            name: d["name"],
            smtp_login: d["smtp_login"] || "postmaster@#{d["name"]}",
            state: d["state"] || "unknown"
          }
        end)

      {:ok, domains}
    end)
  end

  @doc """
  Retrieves an existing Mailgun domain and its DNS records.

  Returns `{:ok, %{domain: map, sending_dns_records: list, receiving_dns_records: list}}`
  or `{:error, reason}` (including `{:error, "HTTP 404"}` when not found).
  """
  def get_domain(api_key, domain_name, region \\ :us) do
    base = if region == :eu, do: @eu_base, else: @us_base
    encoded = URI.encode(domain_name, &URI.char_unreserved?/1)
    url = "#{base}/v4/domains/#{encoded}"
    Logger.info("[Mailgun] GET #{url}")

    case Req.get(url, auth: {"api", api_key}) do
      {:ok, %Req.Response{status: 404}} ->
        Logger.info("[Mailgun] Domain #{domain_name} not found (404)")
        {:error, "HTTP 404"}

      response ->
        parse(response, fn body ->
          {:ok,
           %{
             domain: body["domain"],
             sending_dns_records: body["sending_dns_records"] || [],
             receiving_dns_records: body["receiving_dns_records"] || []
           }}
        end)
    end
  end

  @doc """
  Creates a new Mailgun domain and returns its DNS records.

  Returns `{:ok, %{domain: map, sending_dns_records: list, receiving_dns_records: list}}`
  or `{:error, reason}`.
  """
  def create_domain(api_key, domain_name, region \\ :us) do
    base = if region == :eu, do: @eu_base, else: @us_base
    Logger.info("[Mailgun] Creating domain #{domain_name} in #{region} region")

    Req.post("#{base}/v4/domains", auth: {"api", api_key}, form: [name: domain_name])
    |> parse(fn body ->
      {:ok,
       %{
         domain: body["domain"],
         sending_dns_records: body["sending_dns_records"] || [],
         receiving_dns_records: body["receiving_dns_records"] || []
       }}
    end)
  end

  @doc """
  Creates (or updates) a dedicated `hostctl` SMTP credential for `domain_name`.

  Attempts `POST /v3/{domain}/credentials` with `login=hostctl`. If that login
  already exists, falls back to `PUT /v3/{domain}/credentials/hostctl` to reset
  the password to the freshly generated one.

  Returns `{:ok, %{login: "hostctl@domain", password: password}}` or
  `{:error, reason}`.
  """
  def create_smtp_credential(api_key, domain_name, region \\ :us) do
    base = if region == :eu, do: @eu_base, else: @us_base
    Logger.info("[Mailgun] Creating SMTP credential for #{domain_name}")
    password = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
    login = "hostctl"
    encoded_domain = URI.encode(domain_name, &URI.char_unreserved?/1)
    creds_url = "#{base}/v3/domains/#{encoded_domain}/credentials"

    case Req.post(creds_url,
           auth: {"api", api_key},
           form: [login: login, password: password]
         )
         |> parse(fn _ -> {:ok, :created} end) do
      {:ok, :created} ->
        {:ok, %{login: "#{login}@#{domain_name}", password: password}}

      {:error, _} ->
        # Credential likely already exists — update the password instead
        Req.put("#{creds_url}/#{login}",
          auth: {"api", api_key},
          form: [password: password]
        )
        |> parse(fn _ -> {:ok, %{login: "#{login}@#{domain_name}", password: password}} end)
    end
  end

  @doc """
  Fetches the DMARC DNS records Mailgun wants configured for a domain.

  Returns `{:ok, [%{type, name, value}]}` or `{:error, reason}`.
  """
  def get_dmarc_records(api_key, domain_name, region \\ :us) do
    base = if region == :eu, do: @eu_base, else: @us_base
    encoded = URI.encode(domain_name, &URI.char_unreserved?/1)
    url = "#{base}/v1/dmarc-records/#{encoded}"
    Logger.info("[Mailgun] GET #{url}")

    Req.get(url, auth: {"api", api_key})
    |> parse(fn body ->
      # Response: %{"entry" => "<desired TXT value>", "current" => "...", "configured" => bool}
      records =
        case body["entry"] do
          entry when is_binary(entry) and entry != "" ->
            [%{type: "TXT", name: "_dmarc.#{domain_name}", value: entry, ttl: 300}]

          _ ->
            Logger.warning("[Mailgun] No DMARC entry in response: #{inspect(body)}")
            []
        end

      {:ok, records}
    end)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp parse({:ok, %Req.Response{status: status, body: body}}, success_fn)
       when status in 200..299 do
    success_fn.(body)
  end

  defp parse({:ok, %Req.Response{status: status, body: %{"message" => msg}}}, _) do
    Logger.warning("[Mailgun] HTTP #{status}: #{msg}")
    {:error, msg}
  end

  defp parse({:ok, %Req.Response{status: status}}, _) do
    Logger.warning("[Mailgun] HTTP #{status}")
    {:error, "HTTP #{status}"}
  end

  defp parse({:error, exception}, _) do
    Logger.error("[Mailgun] Request failed: #{Exception.message(exception)}")
    {:error, Exception.message(exception)}
  end
end
