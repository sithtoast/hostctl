defmodule Hostctl.Resources.ProcessReader do
  @moduledoc "Reads Linux process metadata without command arguments or environment variables."

  def snapshot do
    if match?({:unix, :linux}, :os.type()) do
      case System.cmd("ps", ["-e", "-o", "pid=,euid=,euser:32=,pcpu=,rss=,comm="],
             env: [{"LC_ALL", "C"}],
             stderr_to_stdout: true
           ) do
        {output, 0} -> parse(output)
        _ -> {:error, :process_access_failed}
      end
    else
      {:error, :linux_required}
    end
  rescue
    _ -> {:error, :process_access_failed}
  end

  @doc false
  def parse(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, records} ->
      case String.split(String.trim(line), ~r/\s+/, parts: 6) do
        [pid, uid, username, cpu, rss, command] ->
          with {pid, ""} when pid > 0 <- Integer.parse(pid),
               {uid, ""} when uid >= 0 <- Integer.parse(uid),
               {cpu, ""} when cpu >= 0 <- Float.parse(cpu),
               {rss, ""} when rss >= 0 <- Integer.parse(rss) do
            {:cont,
             {:ok,
              [
                %{
                  id: pid,
                  pid: pid,
                  uid: uid,
                  linux_user: username,
                  cpu: cpu,
                  rss_kb: rss,
                  command: command
                }
                | records
              ]}}
          else
            _ -> {:halt, {:error, :invalid_process_snapshot}}
          end

        _ ->
          {:halt, {:error, :invalid_process_snapshot}}
      end
    end)
  end
end
