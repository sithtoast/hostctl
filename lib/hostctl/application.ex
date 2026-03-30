defmodule Hostctl.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    metrics_children =
      if Application.get_env(:hostctl, Hostctl.Metrics.Collector, [])[:enabled] != false do
        [Hostctl.Metrics.Collector]
      else
        []
      end

    backup_children =
      if Application.get_env(:hostctl, Hostctl.Backup.Runner, [])[:enabled] != false do
        [Hostctl.Backup.Runner]
      else
        []
      end

    children =
      [
        HostctlWeb.Telemetry,
        Hostctl.Repo,
        {DNSCluster, query: Application.get_env(:hostctl, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Hostctl.PubSub},
        {Task.Supervisor, name: Hostctl.TaskSupervisor}
      ] ++
        metrics_children ++
        backup_children ++
        [
          # Start to serve requests, typically the last entry
          HostctlWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Hostctl.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    HostctlWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
