defmodule Hostctl.Metrics.Collector do
  @moduledoc """
  Periodic background collector for per-domain resource metrics.

  Two independent timers run concurrently:
  - Disk usage (default every 15 minutes): runs `du -sm <site_root>` for each domain
  - Bandwidth (default every hour): parses each domain's Nginx access log, summing
    `$body_bytes_sent` for lines matching the current calendar month/year. The result
    is stored in `domain_bandwidth_snapshots` (one row per domain per month) and also
    reflected on `domains.bandwidth_used_mb` for quick display.

  Monthly reset is implicit: when the month rolls over, the log file for the new month
  contains no entries yet, so the parsed total naturally starts at 0. Past months'
  snapshots remain in the database as historical records.

  The collector is disabled in test by setting:
    config :hostctl, Hostctl.Metrics.Collector, enabled: false
  """

  use GenServer
  require Logger

  alias Hostctl.{Hosting, Repo}
  alias Hostctl.Hosting.Domain

  @disk_interval_ms :timer.minutes(15)
  @bandwidth_interval_ms :timer.hours(1)
  # Short delay on startup so the app can fully boot before the first collection.
  @initial_delay_ms :timer.seconds(30)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Process.send_after(self(), :collect_disk, @initial_delay_ms)
    Process.send_after(self(), :collect_bandwidth, @initial_delay_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:collect_disk, state) do
    collect_disk_usage()
    Process.send_after(self(), :collect_disk, @disk_interval_ms)
    {:noreply, state}
  end

  def handle_info(:collect_bandwidth, state) do
    collect_bandwidth_usage()
    Process.send_after(self(), :collect_bandwidth, @bandwidth_interval_ms)
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Disk collection
  # ---------------------------------------------------------------------------

  defp collect_disk_usage do
    domains = Repo.all(Domain)

    for domain <- domains do
      site_root =
        if domain.document_root do
          Path.dirname(domain.document_root)
        else
          "/var/www/#{domain.name}"
        end

      case System.cmd("du", ["-sm", "--", site_root], stderr_to_stdout: true) do
        {output, 0} ->
          mb =
            output
            |> String.split("\t")
            |> List.first()
            |> String.trim()
            |> Integer.parse()
            |> case do
              {n, _} -> n
              :error -> 0
            end

          Hosting.update_domain_metrics(domain, %{disk_usage_mb: mb})

        {reason, _exit_code} ->
          Logger.warning("Disk collection failed for #{domain.name}: #{String.trim(reason)}")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Bandwidth collection
  # ---------------------------------------------------------------------------

  defp collect_bandwidth_usage do
    now = DateTime.utc_now()
    year = now.year
    month = now.month
    domains = Repo.all(Domain)
    nginx_log_dir = Application.get_env(:hostctl, :nginx_log_dir, "/var/log/nginx")

    for domain <- domains do
      log_path = Path.join(nginx_log_dir, "#{domain.name}.access.log")
      mb = parse_nginx_log_mb(log_path, year, month)
      Hosting.upsert_bandwidth_snapshot(domain, year, month, mb)
    end
  end

  @doc false
  def parse_nginx_log_mb(log_path, year, month) do
    # Nginx combined log format (default):
    #   $remote_addr - $remote_user [$time_local] "$request" $status $body_bytes_sent ...
    # When split by whitespace, $body_bytes_sent is at index 9.
    # $time_local looks like: [29/Mar/2026:10:30:45  — we filter by "/Mon/YYYY:" substring.
    month_tag = "/#{month_abbrev(month)}/#{year}:"

    if File.exists?(log_path) do
      log_path
      |> File.stream!([], :line)
      |> Stream.filter(&String.contains?(&1, month_tag))
      |> Stream.map(&parse_bytes_from_line/1)
      |> Stream.reject(&is_nil/1)
      |> Enum.sum()
      |> bytes_to_mb()
    else
      0
    end
  end

  defp parse_bytes_from_line(line) do
    parts = String.split(line, " ")

    case Enum.at(parts, 9) do
      nil ->
        nil

      bytes_str ->
        case Integer.parse(bytes_str) do
          {n, _} when n >= 0 -> n
          _ -> nil
        end
    end
  end

  defp bytes_to_mb(bytes) when is_integer(bytes), do: div(bytes, 1_048_576)

  defp month_abbrev(1), do: "Jan"
  defp month_abbrev(2), do: "Feb"
  defp month_abbrev(3), do: "Mar"
  defp month_abbrev(4), do: "Apr"
  defp month_abbrev(5), do: "May"
  defp month_abbrev(6), do: "Jun"
  defp month_abbrev(7), do: "Jul"
  defp month_abbrev(8), do: "Aug"
  defp month_abbrev(9), do: "Sep"
  defp month_abbrev(10), do: "Oct"
  defp month_abbrev(11), do: "Nov"
  defp month_abbrev(12), do: "Dec"
end
