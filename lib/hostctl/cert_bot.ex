defmodule Hostctl.CertBot do
  @moduledoc """
  Handles Let's Encrypt certificate provisioning via Certbot.

  When Cloudflare is configured as the DNS provider the DNS-01 challenge is
  used via the `certbot-dns-cloudflare` plugin (must be installed). This is
  required when the domain is proxied through Cloudflare because it intercepts
  HTTP traffic and breaks HTTP-01 challenges.

  When no Cloudflare token is configured the webroot HTTP-01 challenge is used
  instead.

  ## Configuration

      config :hostctl, :certbot,
        enabled: true,
        certbot_cmd: "certbot",
        email: nil   # Let's Encrypt account email – also reads CERTBOT_EMAIL env var

  Set `enabled: false` in test/dev environments to skip all certbot calls.
  """

  require Logger

  alias Hostctl.Settings
  alias Hostctl.Settings.DnsProviderSetting
  alias Hostctl.Hosting.Domain
  alias Hostctl.Hosting.SslCertificate

  @doc """
  Provisions a Let's Encrypt certificate for the given domain.

  Detects whether Cloudflare DNS is configured and picks the appropriate
  challenge method automatically.

  Returns `{:ok, expires_at}` on success where `expires_at` is a `DateTime`,
  or `{:error, reason}` on failure.
  """
  def provision(%Domain{} = domain, %SslCertificate{cert_type: "lets_encrypt"}) do
    if enabled?() do
      setting = Settings.get_dns_provider_setting()
      do_provision(domain, setting)
    else
      Logger.info("[CertBot] Certbot disabled – skipping provisioning for #{domain.name}")
      {:error, :disabled}
    end
  end

  def provision(_domain, _cert), do: {:error, :not_lets_encrypt}

  # ---------------------------------------------------------------------------
  # Challenge strategies
  # ---------------------------------------------------------------------------

  defp do_provision(
         %Domain{} = domain,
         %DnsProviderSetting{provider: "cloudflare", cloudflare_api_token: token}
       )
       when is_binary(token) and token != "" do
    Logger.info("[CertBot] Using DNS-01 challenge via Cloudflare for #{domain.name}")
    creds_file = write_cloudflare_credentials(token)

    try do
      run_certbot(domain, [
        "--dns-cloudflare",
        "--dns-cloudflare-credentials",
        creds_file,
        "--dns-cloudflare-propagation-seconds",
        "20"
      ])
    after
      File.rm(creds_file)
    end
  end

  defp do_provision(%Domain{} = domain, _setting) do
    webroot = domain.document_root || "/var/www/#{domain.name}/public"
    Logger.info("[CertBot] Using HTTP-01 webroot challenge for #{domain.name}")
    run_certbot(domain, ["--webroot", "-w", webroot])
  end

  # ---------------------------------------------------------------------------
  # Core certbot invocation
  # ---------------------------------------------------------------------------

  defp run_certbot(%Domain{name: domain_name}, extra_args) do
    cmd = certbot_cmd()
    email_args = build_email_args()

    args =
      ["certonly", "--non-interactive", "--agree-tos"] ++
        email_args ++
        extra_args ++
        ["-d", domain_name, "-d", "www.#{domain_name}"]

    Logger.info("[CertBot] Running: sudo #{cmd} #{Enum.join(args, " ")}")

    case System.cmd("sudo", [cmd | args], stderr_to_stdout: true) do
      {output, 0} ->
        Logger.info("[CertBot] Certificate obtained for #{domain_name}:\n#{output}")
        {:ok, read_cert_expiry(domain_name)}

      {output, exit_code} ->
        Logger.error(
          "[CertBot] Provisioning failed for #{domain_name} (exit #{exit_code}):\n#{String.trim(output)}"
        )

        {:error, {:certbot_failed, exit_code, output}}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp write_cloudflare_credentials(api_token) do
    path =
      Path.join(
        System.tmp_dir!(),
        "hostctl-certbot-cf-#{:erlang.unique_integer([:positive])}.ini"
      )

    content = "dns_cloudflare_api_token = #{api_token}\n"
    File.write!(path, content)
    File.chmod!(path, 0o600)
    path
  end

  defp build_email_args do
    case certbot_email() do
      email when is_binary(email) and email != "" -> ["--email", email, "--no-eff-email"]
      _ -> ["--register-unsafely-without-email"]
    end
  end

  # Reads the certificate expiry date from the cert file Certbot writes.
  defp read_cert_expiry(domain_name) do
    cert_path = "/etc/letsencrypt/live/#{domain_name}/cert.pem"

    with {output, 0} <-
           System.cmd("openssl", ["x509", "-enddate", "-noout", "-in", cert_path],
             stderr_to_stdout: true
           ),
         [_, date_str] <- Regex.run(~r/notAfter=(.+)/, output),
         {:ok, expires_at} <- parse_openssl_date(String.trim(date_str)) do
      expires_at
    else
      _ ->
        # Fallback: Let's Encrypt certs are always 90 days
        DateTime.utc_now() |> DateTime.add(90, :day) |> DateTime.truncate(:second)
    end
  end

  # Parse OpenSSL's "Mar 28 12:00:00 2026 GMT" format.
  defp parse_openssl_date(date_str) do
    months = %{
      "Jan" => 1,
      "Feb" => 2,
      "Mar" => 3,
      "Apr" => 4,
      "May" => 5,
      "Jun" => 6,
      "Jul" => 7,
      "Aug" => 8,
      "Sep" => 9,
      "Oct" => 10,
      "Nov" => 11,
      "Dec" => 12
    }

    case Regex.run(~r/(\w{3})\s+(\d+)\s+(\d+):(\d+):(\d+)\s+(\d{4})/, date_str) do
      [_, month_str, day, hour, min, sec, year] ->
        with {:ok, month} <- Map.fetch(months, month_str),
             {:ok, naive} <-
               NaiveDateTime.new(
                 String.to_integer(year),
                 month,
                 String.to_integer(day),
                 String.to_integer(hour),
                 String.to_integer(min),
                 String.to_integer(sec)
               ),
             {:ok, dt} <- DateTime.from_naive(naive, "Etc/UTC") do
          {:ok, dt}
        else
          _ -> {:error, :parse_failed}
        end

      _ ->
        {:error, :parse_failed}
    end
  end

  # ---------------------------------------------------------------------------
  # Config helpers
  # ---------------------------------------------------------------------------

  defp certbot_config, do: Application.get_env(:hostctl, :certbot, [])
  defp enabled?, do: Keyword.get(certbot_config(), :enabled, true)
  defp certbot_cmd, do: Keyword.get(certbot_config(), :certbot_cmd, "certbot")

  defp certbot_email do
    Keyword.get(certbot_config(), :email) ||
      System.get_env("CERTBOT_EMAIL")
  end
end
