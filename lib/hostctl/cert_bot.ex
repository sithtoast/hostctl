defmodule Hostctl.CertBot do
  @moduledoc """
  Handles Let's Encrypt certificate provisioning via Certbot.

  When Cloudflare is configured as the DNS provider the DNS-01 challenge is
  used via the `certbot-dns-cloudflare` plugin (must be installed). This is
  required when the domain is proxied through Cloudflare because it intercepts
  HTTP traffic and breaks HTTP-01 challenges.

  When no Cloudflare token is configured the webroot HTTP-01 challenge is used
  instead.

  ## Live log streaming

  Certbot output is streamed line-by-line via PubSub on the topic
  `"domain:<domain_id>:ssl"` as `{:ssl_log, line}` messages. Subscribe from a
  LiveView to display real-time progress.

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

  Broadcasts each line of certbot output as `{:ssl_log, line}` on the topic
  `"domain:<domain_id>:ssl"`.

  Returns `{:ok, expires_at, full_log}` on success or `{:error, reason, full_log}`
  on failure.
  """
  def provision(%Domain{} = domain, %SslCertificate{cert_type: "lets_encrypt"} = cert) do
    if enabled?() do
      setting = Settings.get_dns_provider_setting()
      do_provision(domain, cert, setting)
    else
      Logger.info("[CertBot] Certbot disabled – skipping provisioning for #{domain.name}")
      {:error, :disabled, ""}
    end
  end

  def provision(_domain, _cert), do: {:error, :not_lets_encrypt, ""}

  # ---------------------------------------------------------------------------
  # Challenge strategies
  # ---------------------------------------------------------------------------

  defp do_provision(
         %Domain{} = domain,
         cert,
         %DnsProviderSetting{provider: "cloudflare", cloudflare_api_token: token}
       )
       when is_binary(token) and token != "" do
    broadcast_log(domain.id, "Using DNS-01 challenge via Cloudflare DNS provider")
    creds_file = write_cloudflare_credentials(token)

    try do
      run_certbot(domain, cert, [
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

  defp do_provision(%Domain{} = domain, cert, _setting) do
    webroot = domain.document_root || "/var/www/#{domain.name}/public"
    broadcast_log(domain.id, "Using HTTP-01 webroot challenge")
    run_certbot(domain, cert, ["--webroot", "-w", webroot])
  end

  # ---------------------------------------------------------------------------
  # Core certbot invocation — streams output line-by-line via Port
  # ---------------------------------------------------------------------------

  defp run_certbot(%Domain{name: domain_name, id: domain_id}, cert, extra_args) do
    cmd = certbot_cmd()
    le_dir = letsencrypt_dir()
    email_args = build_email_args(cert)

    dir_args = [
      "--config-dir",
      le_dir,
      "--work-dir",
      Path.join(le_dir, "work"),
      "--logs-dir",
      Path.join(le_dir, "logs")
    ]

    args =
      ["certonly", "--non-interactive", "--agree-tos"] ++
        email_args ++
        dir_args ++
        extra_args ++
        ["-d", domain_name, "-d", "www.#{domain_name}"]

    broadcast_log(domain_id, "Running: #{cmd} #{Enum.join(args, " ")}")
    Logger.info("[CertBot] Running: #{cmd} #{Enum.join(args, " ")}")

    port =
      Port.open({:spawn_executable, System.find_executable(cmd)}, [
        :binary,
        :stderr_to_stdout,
        :exit_status,
        {:line, 4096},
        {:args, args}
      ])

    {exit_code, log_lines} = collect_port_output(port, domain_id, [])
    full_log = Enum.join(log_lines, "\n")

    if exit_code == 0 do
      Logger.info("[CertBot] Certificate obtained for #{domain_name}")
      broadcast_log(domain_id, "Certificate successfully obtained!")
      {:ok, read_cert_expiry(domain_name), full_log}
    else
      Logger.error(
        "[CertBot] Provisioning failed for #{domain_name} (exit #{exit_code}):\n#{full_log}"
      )

      broadcast_log(domain_id, "ERROR: Certbot exited with code #{exit_code}")
      {:error, {:certbot_failed, exit_code, full_log}, full_log}
    end
  end

  defp collect_port_output(port, domain_id, acc) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        broadcast_log(domain_id, line)
        collect_port_output(port, domain_id, acc ++ [line])

      {^port, {:data, {:noeol, line}}} ->
        collect_port_output(port, domain_id, acc ++ [line])

      {^port, {:exit_status, code}} ->
        {code, acc}
    end
  end

  defp broadcast_log(domain_id, line) do
    Phoenix.PubSub.broadcast(
      Hostctl.PubSub,
      "domain:#{domain_id}:ssl",
      {:ssl_log, line}
    )
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

  defp build_email_args(cert) do
    email =
      (cert.email && cert.email != "" && cert.email) ||
        certbot_email()

    case email do
      e when is_binary(e) and e != "" -> ["--email", e, "--no-eff-email"]
      _ -> ["--register-unsafely-without-email"]
    end
  end

  # Reads the certificate expiry date from the cert file Certbot writes.
  defp read_cert_expiry(domain_name) do
    cert_path = Path.join(letsencrypt_dir(), "live/#{domain_name}/cert.pem")

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

  defp letsencrypt_dir,
    do: Keyword.get(certbot_config(), :letsencrypt_dir, "/var/lib/hostctl/letsencrypt")

  defp certbot_email do
    Keyword.get(certbot_config(), :email) ||
      System.get_env("CERTBOT_EMAIL")
  end
end
