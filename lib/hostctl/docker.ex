defmodule Hostctl.Docker do
  @moduledoc """
  Helpers for interacting with the local Docker daemon.

  Supports container discovery, management (start/stop), environment variable inspection,
  registry search, and Docker Compose stack operations.
  """

  @type container :: %{
          id: String.t(),
          name: String.t(),
          image: String.t(),
          status: String.t(),
          ports: String.t(),
          published_ports: [integer()]
        }

  @type inspect_result :: %{
          id: String.t(),
          name: String.t(),
          image: String.t(),
          state: String.t(),
          ports: map(),
          env: map(),
          restart_policy: String.t()
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

  @doc "Lists all containers (running and stopped)."
  def list_all_containers do
    with {:ok, output} <- run(["ps", "-a", "--format", "{{json .}}"]),
         {:ok, containers} <- parse_ps_output(output) do
      {:ok, containers}
    else
      {:error, :command_failed} -> {:error, docker_error_message()}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Starts a stopped container by name or ID."
  def start_container(container_id) when is_binary(container_id) do
    case run(["start", container_id]) do
      {:ok, _} -> :ok
      {:error, :command_failed} -> {:error, "Failed to start container"}
      error -> error
    end
  end

  @doc "Stops a running container by name or ID."
  def stop_container(container_id) when is_binary(container_id) do
    case run(["stop", container_id]) do
      {:ok, _} -> :ok
      {:error, :command_failed} -> {:error, "Failed to stop container"}
      error -> error
    end
  end

  @doc "Restarts a container by name or ID."
  def restart_container(container_id) when is_binary(container_id) do
    case run(["restart", container_id]) do
      {:ok, _} -> :ok
      {:error, :command_failed} -> {:error, "Failed to restart container"}
      error -> error
    end
  end

  @doc "Inspects a container and returns detailed metadata including environment variables."
  @spec inspect_container(String.t()) :: {:ok, inspect_result()} | {:error, String.t()}
  def inspect_container(container_id) when is_binary(container_id) do
    with {:ok, output} <- run(["inspect", container_id]),
         [json_obj | _] <- Jason.decode!(output),
         name <- Map.get(json_obj, "Name", "") |> String.trim_leading("/"),
         config <- Map.get(json_obj, "Config", %{}),
         state <- Map.get(json_obj, "State", %{}),
         host_config <- Map.get(json_obj, "HostConfig", %{}),
         network_settings <- Map.get(json_obj, "NetworkSettings", %{}) do
      restart_policy =
        host_config
        |> Map.get("RestartPolicy", %{})
        |> Map.get("Name", "")

      {:ok,
       %{
         id: Map.get(json_obj, "Id", ""),
         name: name,
         image: Map.get(config, "Image", ""),
         state: Map.get(state, "Status", "unknown"),
         ports: parse_port_bindings(Map.get(network_settings, "Ports", %{})),
         env: parse_env_list(Map.get(config, "Env", [])),
         restart_policy: restart_policy
       }}
    else
      {:error, _} -> {:error, "Failed to inspect container"}
      _ -> {:error, "Invalid container response"}
    end
  rescue
    _ -> {:error, "Failed to parse container details"}
  end

  @doc "Gets environment variables from a container."
  def get_container_env(container_id) when is_binary(container_id) do
    case inspect_container(container_id) do
      {:ok, details} -> {:ok, details.env}
      error -> error
    end
  end

  @doc "Search Docker Hub registry for images matching a query."
  def search_registry(query) when is_binary(query) do
    with {:ok, output} <-
           run([
             "search",
             "--format",
             "table {{.Name}}\\t{{.StarCount}}\\t{{.Description}}",
             query
           ]) do
      {:ok,
       output
       |> String.split("\n", trim: true)
       |> Enum.drop(1)
       |> Enum.map(&parse_search_result/1)
       |> Enum.reject(&is_nil/1)}
    else
      {:error, :command_failed} -> {:error, "Search failed or registry unavailable"}
      error -> error
    end
  end

  @doc "Lists active Docker Compose stacks (requires docker compose command)."
  def list_compose_stacks do
    case run(["compose", "ls", "--format", "json"]) do
      {:ok, output} ->
        case Jason.decode(output) do
          {:ok, stacks} ->
            {:ok,
             stacks
             |> Enum.map(fn stack ->
               %{
                 name: Map.get(stack, "Name", ""),
                 status: Map.get(stack, "Status", "unknown"),
                 container_count: Map.get(stack, "Containers", 0)
               }
             end)}

          {:error, _} ->
            {:error, "Failed to parse compose stacks"}
        end

      {:error, :command_failed} ->
        {:error, "Docker Compose not available or no stacks running"}

      error ->
        error
    end
  end

  @doc "Pulls an image from registry."
  def pull_image(image_name) when is_binary(image_name) do
    case run(["pull", image_name]) do
      {:ok, output} -> {:ok, String.trim(output)}
      {:error, :command_failed} -> {:error, "Failed to pull image"}
      error -> error
    end
  end

  @doc "Lists locally available images with repository, tag, ID, and size."
  def list_images do
    case run(["images", "--format", "{{json .}}"]) do
      {:ok, ""} ->
        {:ok, []}

      {:ok, output} ->
        images =
          output
          |> String.split("\n", trim: true)
          |> Enum.reduce([], fn line, acc ->
            case Jason.decode(line) do
              {:ok, row} ->
                [
                  %{
                    id: Map.get(row, "ID", ""),
                    repository: Map.get(row, "Repository", "<none>"),
                    tag: Map.get(row, "Tag", "<none>"),
                    size: Map.get(row, "Size", ""),
                    created: Map.get(row, "CreatedSince", "")
                  }
                  | acc
                ]

              _ ->
                acc
            end
          end)
          |> Enum.reverse()

        {:ok, images}

      {:error, :command_failed} ->
        {:error, docker_error_message()}

      error ->
        error
    end
  end

  @doc "Removes a local image by ID or name:tag."
  def remove_image(image_id) when is_binary(image_id) do
    case run(["rmi", image_id]) do
      {:ok, _} ->
        :ok

      {:error, :command_failed} ->
        {:error, "Failed to remove image. Is it in use by a container?"}

      error ->
        error
    end
  end

  @doc "Removes a stopped container by name or ID."
  def remove_container(container_id) when is_binary(container_id) do
    case run(["rm", container_id]) do
      {:ok, _} -> :ok
      {:error, :command_failed} -> {:error, "Failed to remove container. Is it still running?"}
      error -> error
    end
  end

  @doc """
  Renames a container.
  """
  def rename_container(container_id, new_name)
      when is_binary(container_id) and is_binary(new_name) do
    case run(["rename", container_id, new_name]) do
      {:ok, _} -> :ok
      {:error, :command_failed} -> {:error, "Failed to rename container"}
      error -> error
    end
  end

  @doc """
  Recreates a container with new settings.

  Stops and removes the old container, then runs a new one from the same image
  with the provided options. Returns `{:ok, new_container_id}` on success.
  """
  def recreate_container(container_name, opts \\ []) when is_binary(container_name) do
    with {:ok, details} <- inspect_container(container_name),
         :ok <- stop_container_if_running(details),
         :ok <- remove_container(container_name) do
      image = details.image
      run_container(image, opts)
    end
  end

  defp stop_container_if_running(%{state: "running", name: name}) do
    stop_container(name)
  end

  defp stop_container_if_running(_), do: :ok

  @doc """
  Runs a new container from an image with optional name, port mappings, env vars, and detach mode.

  Options:
    * `:name` - container name (string)
    * `:ports` - list of port mapping strings, e.g. ["8080:80", "5432:5432"]
    * `:env` - list of {key, value} tuples or keyword list for environment variables
    * `:restart` - restart policy, e.g. "unless-stopped", "always"
  """
  def run_container(image, opts \\ []) when is_binary(image) do
    name = Keyword.get(opts, :name)
    ports = Keyword.get(opts, :ports, [])
    env = Keyword.get(opts, :env, [])
    restart = Keyword.get(opts, :restart)

    args =
      ["run", "-d"] ++
        name_args(name) ++
        restart_args(restart) ++
        port_args(ports) ++
        env_args(env) ++
        [image]

    case run(args) do
      {:ok, container_id} -> {:ok, String.trim(container_id)}
      {:error, :command_failed} -> {:error, "Failed to run container from image #{image}"}
      error -> error
    end
  end

  defp name_args(nil), do: []
  defp name_args(""), do: []
  defp name_args(name), do: ["--name", name]

  defp restart_args(nil), do: []
  defp restart_args(""), do: []
  defp restart_args(policy), do: ["--restart", policy]

  defp port_args(ports) do
    Enum.flat_map(ports, fn port ->
      port = String.trim(port)
      if port == "", do: [], else: ["-p", port]
    end)
  end

  defp env_args(env) do
    Enum.flat_map(env, fn
      {key, value} ->
        key = String.trim(to_string(key))
        if key == "", do: [], else: ["-e", "#{key}=#{value}"]
    end)
  end

  @doc "Starts services defined in a compose stack by project name and config file path."
  def compose_up(project_name) when is_binary(project_name) do
    case run(["compose", "-p", project_name, "up", "-d"]) do
      {:ok, _} -> :ok
      {:error, :command_failed} -> {:error, "Failed to start compose stack"}
      error -> error
    end
  end

  @doc "Stops services in a compose stack by project name."
  def compose_down(project_name) when is_binary(project_name) do
    case run(["compose", "-p", project_name, "down"]) do
      {:ok, _} -> :ok
      {:error, :command_failed} -> {:error, "Failed to stop compose stack"}
      error -> error
    end
  end

  @doc "Restarts services in a compose stack by project name."
  def compose_restart(project_name) when is_binary(project_name) do
    case run(["compose", "-p", project_name, "restart"]) do
      {:ok, _} -> :ok
      {:error, :command_failed} -> {:error, "Failed to restart compose stack"}
      error -> error
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

  defp parse_port_bindings(ports) when is_map(ports) do
    ports
    |> Enum.reduce(%{}, fn {port_proto, bindings}, acc ->
      case bindings do
        nil ->
          acc

        bindings_list when is_list(bindings_list) ->
          host_ports =
            bindings_list
            |> Enum.map(&Map.get(&1, "HostPort", ""))
            |> Enum.reject(&(&1 == ""))

          Map.put(acc, port_proto, host_ports)

        _ ->
          acc
      end
    end)
  end

  defp parse_port_bindings(_), do: %{}

  defp parse_env_list(env_list) when is_list(env_list) do
    env_list
    |> Enum.reduce(%{}, fn env_str, acc ->
      case String.split(env_str, "=", parts: 2) do
        [key, value] -> Map.put(acc, key, value)
        _ -> acc
      end
    end)
  end

  defp parse_env_list(_), do: %{}

  defp parse_search_result(line) do
    case String.split(line, ~r/\s+/, parts: 3) do
      [name, stars, description] ->
        %{
          name: name,
          stars: String.to_integer(String.trim(stars)),
          description: String.trim(description)
        }

      [name | _] ->
        %{name: name, stars: 0, description: ""}

      _ ->
        nil
    end
  end
end
