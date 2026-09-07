defmodule Hostctl.EmailDelivery.System do
  @moduledoc "Generate a server-owned DKIM key; only return the public portion."
  def prepare_key(domain, selector) do
    if match?({:unix, :linux}, :os.type()) do
      script = Application.app_dir(:hostctl, "priv/email_delivery/key.py")

      args = [
        "-n",
        "systemd-run",
        "--pipe",
        "--wait",
        "--collect",
        "--quiet",
        "--property=RuntimeMaxSec=60",
        "python3",
        script,
        domain
      ]

      args = if selector, do: args ++ [selector], else: args

      case System.cmd("sudo", args, stderr_to_stdout: true) do
        {output, 0} ->
          with {:ok, %{"selector" => selector, "public_key" => key}} <- Jason.decode(output),
               true <- Regex.match?(~r/\Ahc[a-f0-9]{16}\z/, selector),
               true <- Regex.match?(~r/\A[A-Za-z0-9+\/]+={0,2}\z/, key) do
            {:ok, %{selector: selector, public_key: key}}
          else
            _ -> {:error, "Could not read the DKIM public key"}
          end

        _ ->
          {:error, "Key preparation failed; check mail server privileges and Rspamd installation"}
      end
    else
      {:error, "DKIM keys must be prepared on the Linux mail server"}
    end
  rescue
    _ -> {:error, "DKIM key preparation is unavailable on this machine"}
  end
end
