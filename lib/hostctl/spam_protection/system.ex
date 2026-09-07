defmodule Hostctl.SpamProtection.System do
  @moduledoc "Executes the bundled transactional installer on the hosting server."

  def apply(bundle) do
    if supported?() do
      path =
        Path.join(System.tmp_dir!(), "hostctl-spam-#{System.unique_integer([:positive])}.json")

      try do
        File.write!(path, Jason.encode!(bundle), [:exclusive])
        File.chmod!(path, 0o600)

        case run(["apply", path]) do
          {_, 0} -> :ok
          {output, _} -> {:error, String.slice(output, -3000, 3000)}
        end
      after
        File.rm(path)
      end
    else
      {:error, "Apply is available on a Linux hosting server with mail integration enabled."}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def status do
    if supported?() do
      case run(["status"]) do
        {output, 0} ->
          case Jason.decode(output) do
            {:ok, data} ->
              %{
                enabled: data["enabled"],
                healthy?: data["healthy"],
                digest: data["digest"],
                message: data["message"]
              }

            _ ->
              unavailable("Could not read mail protection status.")
          end

        _ ->
          unavailable("Could not check mail services. Check server privileges.")
      end
    else
      unavailable("Not applied on this machine. Requires Linux with Hostctl mail configured.")
    end
  rescue
    _ -> unavailable("Mail protection status is unavailable.")
  end

  defp unavailable(message), do: %{enabled: false, healthy?: false, digest: nil, message: message}

  defp supported? do
    match?({:unix, :linux}, :os.type()) and
      Keyword.get(Application.get_env(:hostctl, :mail_server, []), :enabled, true)
  end

  defp run(args) do
    script = Application.app_dir(:hostctl, "priv/spam_protection/manage.py")

    System.cmd(
      "sudo",
      [
        "-n",
        "systemd-run",
        "--pipe",
        "--wait",
        "--collect",
        "--quiet",
        "--property=RuntimeMaxSec=900",
        "python3",
        script | args
      ],
      stderr_to_stdout: true
    )
  end
end
