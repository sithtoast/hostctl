defmodule Hostctl.PrivilegedTest do
  use ExUnit.Case, async: true

  defp server(reply) do
    path = String.to_charlist(Path.join(System.tmp_dir!(), "hc-#{Ecto.UUID.generate()}.sock"))
    start_supervised!({Hostctl.TestPrivilegedServer, path: path, owner: self(), reply: reply})
    on_exit(fn -> File.rm(List.to_string(path)) end)
    List.to_string(path)
  end

  test "uses structured local requests and verifies response correlation" do
    path =
      server(fn req ->
        Map.merge(req, %{"ok" => %{"uid" => 123}, "operation_id" => Ecto.UUID.generate()})
      end)

    assert {:ok, %{"uid" => 123}} =
             Hostctl.Privileged.call("verify", %{owner_id: 1}, socket: path)

    assert_receive {:broker_request,
                    %{"version" => 1, "operation" => "verify", "payload" => %{"owner_id" => 1}}}
  end

  test "rejects mismatched response id" do
    path = server(fn req -> Map.merge(req, %{"id" => Ecto.UUID.generate(), "ok" => %{}}) end)

    assert {:error, :invalid_broker_response} =
             Hostctl.Privileged.call("verify", %{}, socket: path)
  end

  test "unavailable broker does not execute a fallback" do
    assert {:error, :broker_unavailable} =
             Hostctl.Privileged.call("enroll", %{}, socket: "/missing/hostctl.sock")
  end

  test "rejects oversized requests before connecting" do
    assert {:error, :broker_request_too_large} =
             Hostctl.Privileged.call("verify", %{path: String.duplicate("x", 65_536)})
  end
end
