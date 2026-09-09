defmodule Hostctl.Isolation.Linux do
  @moduledoc "Linux command boundary for account isolation."

  def call(operation, payload) do
    helper = Application.app_dir(:hostctl, "priv/isolation/runtime.py")
    encoded = payload |> Jason.encode!() |> Base.encode64()

    args = [
      "-n",
      "systemd-run",
      "--pipe",
      "--wait",
      "--collect",
      "--quiet",
      "/usr/bin/python3",
      helper,
      operation,
      encoded
    ]

    case System.cmd("sudo", args, stderr_to_stdout: true) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, %{"ok" => result}} -> {:ok, result}
          _ -> {:error, :invalid_helper_response}
        end

      {_output, _status} ->
        # Avoid surfacing command output in forms/logs; operators can run the
        # helper directly for diagnostics without exposing a privileged shell.
        {:error, :linux_provisioning_failed}
    end
  rescue
    _ in ErlangError -> {:error, :linux_helper_unavailable}
  end
end
