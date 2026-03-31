defmodule Hostctl.Docker do
  @moduledoc """
  Helpers for interacting with the local Docker daemon.

  This module is intentionally read-only for now and is used by the panel
  to discover running containers and their published host ports.
  """

  @type container :: %{
          id: String.t(),
          name: String.t(),
          image: String.t(),
          status: String.t(),
          ports: String.t(),
          published_ports: [integer()]
        }

  @doc "Returns true when the docker CLI is available and can talk to the daemon."
  def available? do
    case run(["version", "--format", "{{.Server.Version}}"]) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  @doc "Lists running containers with basic metadata and detected published ports."
  @spec list_containers() :: {:ok, [container()]} | {:error, atom() | String.t()}
  def list_containers do
    with {:ok, output} <- run(["ps", "--format", "{{json .}}"]),
         {:ok, containers} <- parse_ps_output(output) do
      {:ok, containers}
    else
      {:error, :command_failed} -> {:error, docker_error_message()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_ps_output(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case Jason.decode(line) do
        {:ok, row} ->
          ports = Map.get(row, "Ports", "")

          parsed =
            %{
              id: Map.get(row, "ID", ""),
              name: Map.get(row, "Names", ""),
              image: Map.get(row, "Image", ""),
              status: Map.get(row, "Status", ""),
              ports: ports,
              published_ports: parse_published_ports(ports)
            }

          {:cont, {:ok, [parsed | acc]}}

        {:error, _} ->
          {:halt, {:error, "failed to parse docker ps output"}}
      end
    end)
    |> case do
      {:ok, containers} -> {:ok, Enum.reverse(containers)}
      error -> error
    end
  end

  defp parse_published_ports(ports) when is_binary(ports) do
    Regex.scan(~r/:(\d+)->/, ports)
    |> Enum.map(fn [_, port] -> String.to_integer(port) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp parse_published_ports(_), do: []

  defp run(args) do
    [executable | base_args] = docker_command()

    try do
      case System.cmd(executable, base_args ++ args, stderr_to_stdout: true) do
        {output, 0} -> {:ok, String.trim(output)}
        {_output, _exit_code} -> {:error, :command_failed}
      end
    rescue
      ErlangError -> {:error, :command_failed}
    end
  end

  defp docker_command do
    Application.get_env(:hostctl, :docker, [])
    |> Keyword.get(:command, ["docker"])
  end

  defp docker_error_message do
    "Docker is unavailable. Ensure the docker daemon is running and this service user can execute docker commands."
  end
end
