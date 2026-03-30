defmodule Hostctl.Metrics.CollectorTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Hostctl.Metrics.Collector

  describe "parse_nginx_log_mb/3" do
    test "returns 0 for a missing log file" do
      path = Path.join(System.tmp_dir!(), "missing-#{System.unique_integer([:positive])}.log")

      assert Collector.parse_nginx_log_mb(path, 2026, 3) == 0
    end

    test "returns 0 and logs a warning for an unreadable log file" do
      path = temp_log_path()
      File.write!(path, nginx_line(~D[2026-03-30], 1_048_576))
      File.chmod!(path, 0o000)

      on_exit(fn ->
        File.chmod(path, 0o644)
        File.rm_rf(Path.dirname(path))
      end)

      log =
        capture_log(fn ->
          assert Collector.parse_nginx_log_mb(path, 2026, 3) == 0
        end)

      assert log =~ "Bandwidth collection skipped for #{path}: permission denied"
    end

    test "sums only matching month entries and converts bytes to megabytes" do
      path = temp_log_path()

      contents = [
        nginx_line(~D[2026-03-01], 524_288),
        nginx_line(~D[2026-03-15], 1_572_864),
        nginx_line(~D[2026-02-28], 9_999_999),
        "malformed line"
      ]

      File.write!(path, Enum.join(contents, "\n") <> "\n")

      on_exit(fn -> File.rm_rf(Path.dirname(path)) end)

      assert Collector.parse_nginx_log_mb(path, 2026, 3) == 2
    end
  end

  defp temp_log_path do
    dir = Path.join(System.tmp_dir!(), "hostctl-collector-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Path.join(dir, "access.log")
  end

  defp nginx_line(date, bytes_sent) do
    month = Calendar.strftime(date, "%b")
    day = String.pad_leading(Integer.to_string(date.day), 2, "0")

    ~s(127.0.0.1 - - [#{day}/#{month}/#{date.year}:07:22:56 +0000] "GET / HTTP/1.1" 200 #{bytes_sent} "-" "Mozilla/5.0")
  end
end
