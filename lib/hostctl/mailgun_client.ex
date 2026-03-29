defmodule Hostctl.MailgunClient do
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
    Req.get("#{@us_base}/v3/domains", auth: {"api", api_key})
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
  Creates (or updates) a dedicated `hostctl` SMTP credential for `domain_name`.

  Attempts `POST /v3/{domain}/credentials` with `login=hostctl`. If that login
  already exists, falls back to `PUT /v3/{domain}/credentials/hostctl` to reset
  the password to the freshly generated one.

  Returns `{:ok, %{login: "hostctl@domain", password: password}}` or
  `{:error, reason}`.
  """
  def create_smtp_credential(api_key, domain_name, region \\ :us) do
    base = if region == :eu, do: @eu_base, else: @us_base
    password = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
    login = "hostctl"
    creds_url = "#{base}/v3/#{URI.encode(domain_name, &URI.char_unreserved?/1)}/credentials"

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

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp parse({:ok, %Req.Response{status: status, body: body}}, success_fn)
       when status in 200..299 do
    success_fn.(body)
  end

  defp parse({:ok, %Req.Response{body: %{"message" => msg}}}, _), do: {:error, msg}
  defp parse({:ok, %Req.Response{status: status}}, _), do: {:error, "HTTP #{status}"}
  defp parse({:error, exception}, _), do: {:error, Exception.message(exception)}
end
