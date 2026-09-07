defmodule Hostctl.VMConfigTest do
  use ExUnit.Case, async: false

  @env %{
    "HOSTCTL_VM_DEV" => "1",
    "DATABASE_URL" => "ecto://vm:password@localhost/hostctl_vm",
    "SECRET_KEY_BASE" => String.duplicate("v", 64),
    "PHX_HOST" => "panel.example.test",
    "S3_PROXY_TOKEN" => "vm-proxy-token"
  }

  setup do
    original = Map.new(@env, fn {key, _} -> {key, System.get_env(key)} end)
    System.put_env(@env)

    on_exit(fn ->
      Enum.each(original, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  test "VM mode enables integrations and shares production SSL policy" do
    dev = read_config("config/config.exs", :dev)
    prod = read_config("config/config.exs", :prod)

    for integration <- [:web_server, :ftp_server, :database_server, :postgres_server] do
      assert dev[:hostctl][integration][:enabled]
    end

    assert dev[:hostctl][HostctlWeb.Endpoint][:code_reloader]

    assert dev[:hostctl][HostctlWeb.Endpoint][:force_ssl] ==
             prod[:hostctl][HostctlWeb.Endpoint][:force_ssl]

    refute dev[:hostctl][Hostctl.Backup.Runner][:enabled]
  end

  test "VM runtime preserves installed identity and isolates ACME staging" do
    dev = read_config("config/runtime.exs", :dev)
    prod = read_config("config/runtime.exs", :prod)

    assert dev[:hostctl][Hostctl.Repo][:url] == @env["DATABASE_URL"]
    assert dev[:hostctl][HostctlWeb.Endpoint][:secret_key_base] == @env["SECRET_KEY_BASE"]
    assert dev[:hostctl][:s3_proxy_token] == @env["S3_PROXY_TOKEN"]
    assert dev[:hostctl][HostctlWeb.Endpoint][:http][:ip] == {127, 0, 0, 1}
    assert dev[:hostctl][:certbot][:acme_server] =~ "acme-staging"
    assert dev[:hostctl][:certbot][:letsencrypt_dir] == "/var/lib/hostctl/letsencrypt-staging"
    refute get_in(prod, [:hostctl, :certbot, :acme_server])
  end

  test "VM mode does not enable integrations in tests or ordinary development" do
    test_config = read_config("config/config.exs", :test)
    System.delete_env("HOSTCTL_VM_DEV")
    dev = read_config("config/config.exs", :dev)

    refute test_config[:hostctl][:web_server][:enabled]
    refute dev[:hostctl][:web_server][:enabled]
    refute dev[:hostctl][HostctlWeb.Endpoint][:force_ssl]
  end

  test "VM runtime refuses to use the ordinary development S3 token" do
    System.delete_env("S3_PROXY_TOKEN")

    assert_raise RuntimeError, ~r/S3_PROXY_TOKEN is required/, fn ->
      read_config("config/runtime.exs", :dev)
    end
  end

  defp read_config(path, env), do: Config.Reader.read!(path, env: env, target: :host)
end
