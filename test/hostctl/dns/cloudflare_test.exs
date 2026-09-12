defmodule Hostctl.DNS.CloudflareTest do
  use Hostctl.DataCase

  alias Hostctl.DNS.Cloudflare
  alias Hostctl.Hosting
  alias Hostctl.Hosting.{Domain, DnsZone, DnsRecord}
  import Hostctl.AccountsFixtures

  setup do
    previous = Application.get_env(:hostctl, :cloudflare_request_options)
    Application.put_env(:hostctl, :cloudflare_request_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:hostctl, :cloudflare_request_options, previous),
        else: Application.delete_env(:hostctl, :cloudflare_request_options)
    end)

    state = start_supervised!({Agent, fn -> %{records: [], requests: [], error: nil} end})

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = if raw == "", do: nil, else: Jason.decode!(raw)

      result =
        Agent.get_and_update(state, fn state ->
          state = %{state | requests: state.requests ++ [{conn.method, conn.request_path, body}]}

          cond do
            state.error ->
              {%{"success" => false, "errors" => [%{"message" => state.error}]}, state}

            conn.request_path == "/client/v4/zones" ->
              {%{"success" => true, "result" => [%{"id" => "zone"}]}, state}

            conn.method == "GET" ->
              {%{"success" => true, "result" => state.records}, state}

            conn.method == "POST" ->
              record = Map.put(body, "id", "new-#{length(state.records)}")

              {%{"success" => true, "result" => record},
               %{state | records: state.records ++ [record]}}

            conn.method == "PATCH" ->
              id = List.last(conn.path_info)
              old = Enum.find(state.records, &(&1["id"] == id))
              record = Map.merge(old, body)
              records = Enum.map(state.records, fn r -> if r["id"] == id, do: record, else: r end)
              {%{"success" => true, "result" => record}, %{state | records: records}}

            true ->
              flunk("Unexpected Cloudflare mutation: #{conn.method}")
          end
        end)

      Req.Test.json(conn, result)
    end)

    {:ok, _} =
      Hostctl.Settings.save_dns_provider_setting(%{
        provider: "cloudflare",
        cloudflare_api_token: "test-token"
      })

    user = user_fixture()
    domain = Repo.insert!(%Domain{name: "example.com", user_id: user.id})
    zone = Repo.insert!(%DnsZone{domain_id: domain.id, cloudflare_zone_id: "zone"})
    %{state: state, zone: zone}
  end

  test "Plesk mail SRV create and update send all four structured fields", %{state: state} do
    for {service, port} <- [{"imaps", 993}, {"pop3s", 995}, {"smtps", 465}] do
      record = %{
        type: "SRV",
        name: "_#{service}._tcp.example.com",
        value: "0 #{port} mail.example.com.",
        priority: 0,
        ttl: 3600
      }

      assert {:ok, id} = Cloudflare.create_record("test", "zone", record)
      assert :ok = Cloudflare.update_record("test", "zone", id, record)
    end

    for {method, _, body} <- requests(state) do
      assert method in ["POST", "PATCH"]

      assert %{"priority" => 0, "weight" => 0, "target" => "mail.example.com", "port" => port} =
               body["data"]

      assert port in [993, 995, 465]
      refute Map.has_key?(body, "content")
      refute Map.has_key?(body, "priority")
      refute Map.has_key?(body, "proxied")
    end
  end

  test "invalid SRV values fail before any request", %{state: state} do
    for {value, priority} <- [
          {"mail.example.com", 0},
          {"0 993 mail.example.com", nil},
          {"-1 993 mail.example.com", 0},
          {"0 65536 mail.example.com", 0},
          {"0 993 target extra", 0}
        ] do
      record = %{type: "SRV", name: "_imaps._tcp.example.com", value: value, priority: priority}
      assert {:error, _} = Cloudflare.create_record("test", "zone", record)
      assert {:error, _} = Cloudflare.update_record("test", "zone", "id", record)
    end

    assert requests(state) == []
  end

  test "apex NS members match their full value and repair old shared IDs without writes", %{
    state: state,
    zone: zone
  } do
    remote = [
      rr("ns1", "NS", "example.com", "ns1.example.net"),
      rr("ns2", "NS", "example.com", "ns2.example.net")
    ]

    seed(state, remote)
    first = local(zone, "NS", "@", "NS1.Example.NET.", cloudflare_record_id: "ns1")
    second = local(zone, "NS", "EXAMPLE.COM.", "ns2.example.net.", cloudflare_record_id: "ns1")
    assert {:ok, %{synced: 2, failed: 0}} = Hosting.sync_zone_to_cloudflare(zone)
    assert Repo.get!(DnsRecord, first.id).cloudflare_record_id == "ns1"
    assert Repo.get!(DnsRecord, second.id).cloudflare_record_id == "ns2"
    assert Agent.get(state, & &1.records) == remote
    assert writes(state) == []
  end

  test "linking preserves multi-value sets and adds only missing values", %{
    state: state,
    zone: zone
  } do
    remote = for type <- ~w(A AAAA NS MX TXT SRV CAA), do: sample(type, "existing")
    seed(state, remote)

    for record <- remote do
      {value, priority} = Hostctl.DNS.Record.local_value(record)
      local(zone, record["type"], record["name"], value, priority: priority)
    end

    local(zone, "A", "@", "192.0.2.20")
    local(zone, "A", "@", "192.0.2.20")
    assert {:ok, _} = Hosting.link_zone_to_cloudflare(zone)
    assert [{"POST", _, %{"content" => "192.0.2.20", "name" => "example.com"}}] = writes(state)
    assert Enum.take(Agent.get(state, & &1.records), length(remote)) == remote
    assert {:ok, %{synced: 9, failed: 0}} = Hosting.sync_zone_to_cloudflare(zone)
    assert length(writes(state)) == 1
  end

  test "new members do not replace records with the same name and type", %{
    state: state,
    zone: zone
  } do
    remote = [
      rr("mx", "MX", "example.com", "mail.example.com", 10),
      rr("txt", "TXT", "example.com", "CaseSensitive"),
      sample("SRV", "srv")
    ]

    seed(state, remote)
    local(zone, "MX", "@", "mail.example.com", priority: 20)
    local(zone, "TXT", "@", "casesensitive")
    local(zone, "SRV", "_imaps._tcp", "5 993 mail.example.com", priority: 0)
    assert {:ok, %{synced: 3, failed: 0}} = Hosting.sync_zone_to_cloudflare(zone)
    assert Enum.all?(writes(state), &(elem(&1, 0) == "POST"))
    assert length(writes(state)) == 3
    assert Enum.take(Agent.get(state, & &1.records), 3) == remote
  end

  test "linked change patches only its ID and retains Cloudflare attributes", %{
    state: state,
    zone: zone
  } do
    remote =
      Map.merge(rr("owned", "A", "example.com", "192.0.2.1"), %{
        "proxied" => true,
        "ttl" => 1,
        "comment" => "keep",
        "tags" => ["owner:external"]
      })

    seed(state, [remote, rr("peer", "A", "example.com", "192.0.2.2")])
    local(zone, "A", "@", "192.0.2.3", cloudflare_record_id: "owned")
    assert {:ok, %{synced: 1, failed: 0}} = Hosting.sync_zone_to_cloudflare(zone)
    assert [{"PATCH", "/client/v4/zones/zone/dns_records/owned", body}] = writes(state)
    assert body["ttl"] == 1
    refute Map.has_key?(body, "proxied")
    [updated, peer] = Agent.get(state, & &1.records)

    assert Map.take(updated, ["proxied", "comment", "tags"]) ==
             Map.take(remote, ["proxied", "comment", "tags"])

    assert peer["content"] == "192.0.2.2"
  end

  test "ambiguous and repurposed IDs fail without remote mutations", %{state: state, zone: zone} do
    seed(state, [
      rr("shared", "A", "example.com", "192.0.2.1"),
      rr("moved", "A", "other.example.com", "192.0.2.2")
    ])

    local(zone, "A", "@", "192.0.2.3", cloudflare_record_id: "shared")
    local(zone, "A", "@", "192.0.2.4", cloudflare_record_id: "shared")
    local(zone, "A", "@", "192.0.2.5", cloudflare_record_id: "moved")
    assert {:ok, %{synced: 0, failed: 3}} = Hosting.sync_zone_to_cloudflare(zone)
    assert writes(state) == []
  end

  test "a linked update cannot consume a value needed by an unlinked local row", %{
    state: state,
    zone: zone
  } do
    seed(state, [rr("owned", "A", "example.com", "192.0.2.1")])
    local(zone, "A", "@", "192.0.2.2", cloudflare_record_id: "owned")
    preserved = local(zone, "A", "@", "192.0.2.1")
    assert {:ok, %{synced: 1, failed: 1}} = Hosting.sync_zone_to_cloudflare(zone)
    assert Repo.get!(DnsRecord, preserved.id).cloudflare_record_id == "owned"
    assert writes(state) == []
  end

  test "canonical IPv6 and SRV hostnames adopt without changing remote TTL", %{
    state: state,
    zone: zone
  } do
    seed(state, [rr("v6", "AAAA", "example.com", "2001:db8::1"), sample("SRV", "srv")])
    local(zone, "AAAA", "@", "2001:0DB8:0:0:0:0:0:1")
    local(zone, "SRV", "_IMAPS._TCP.EXAMPLE.COM.", "00\t0993 MAIL.EXAMPLE.COM.", priority: 0)
    assert {:ok, %{synced: 2, failed: 0}} = Hosting.sync_zone_to_cloudflare(zone)
    assert writes(state) == []
  end

  test "stale missing ID creates a member without replacing a peer", %{state: state, zone: zone} do
    seed(state, [rr("peer", "NS", "example.com", "ns1.example.net")])
    local(zone, "NS", "@", "ns2.example.net", cloudflare_record_id: "deleted")
    assert {:ok, %{synced: 1, failed: 0}} = Hosting.sync_zone_to_cloudflare(zone)
    assert [{"POST", _, _}] = writes(state)
  end

  test "SRV permits the upper numeric boundary and unavailable-service root target", %{
    state: state
  } do
    assert {:ok, _} =
             Cloudflare.create_record("test", "zone", %{
               type: "SRV",
               name: "_imaps._tcp.example.com",
               priority: 65535,
               value: "65535 65535 ."
             })

    assert [
             {"POST", _,
              %{
                "data" => %{
                  "priority" => 65535,
                  "weight" => 65535,
                  "port" => 65535,
                  "target" => "."
                }
              }}
           ] = writes(state)
  end

  test "absolute DNS names are not silently rewritten into another name" do
    assert Hostctl.DNS.Record.fqdn("external.example.net.", "example.com") ==
             "external.example.net"
  end

  test "API failure is propagated without follow-up writes", %{state: state, zone: zone} do
    Agent.update(state, &%{&1 | error: "denied"})
    local(zone, "A", "@", "192.0.2.1")
    assert {:error, "denied"} = Hosting.sync_zone_to_cloudflare(zone)
    assert writes(state) == []
  end

  test "SRV imports use structured data and MX priority preserves distinct members", %{zone: zone} do
    srv = sample("SRV", "srv") |> Map.put("content", "ambiguous legacy content")

    mx = [
      rr("mx10", "MX", "example.com", "mail.example.com", 10),
      rr("mx20", "MX", "example.com", "mail.example.com", 20)
    ]

    assert {:ok, %{imported: 3}} = Hosting.import_cloudflare_zone_records(zone, [srv | mx])
    assert {:ok, %{skipped: 3}} = Hosting.import_cloudflare_zone_records(zone, [srv | mx])
    imported = Repo.get_by!(DnsRecord, cloudflare_record_id: "srv")
    assert {imported.value, imported.priority} == {"0 993 mail.example.com", 0}
  end

  defp local(zone, type, name, value, attrs \\ []) do
    Repo.insert!(
      struct(
        DnsRecord,
        Keyword.merge(
          [dns_zone_id: zone.id, type: type, name: name, value: value, ttl: 3600],
          attrs
        )
      )
    )
  end

  defp rr(id, type, name, content, priority \\ nil),
    do: %{
      "id" => id,
      "type" => type,
      "name" => name,
      "content" => content,
      "priority" => priority,
      "ttl" => 600
    }

  defp seed(state, records), do: Agent.update(state, &%{&1 | records: records})
  defp requests(state), do: Agent.get(state, & &1.requests)
  defp writes(state), do: Enum.reject(requests(state), &(elem(&1, 0) == "GET"))

  defp sample("SRV", id),
    do:
      rr(id, "SRV", "_imaps._tcp.example.com", "0 993 mail.example.com", 0)
      |> Map.put("data", %{
        "priority" => 0,
        "weight" => 0,
        "port" => 993,
        "target" => "mail.example.com"
      })

  defp sample(type, id) do
    value =
      %{
        "A" => "192.0.2.1",
        "AAAA" => "2001:db8::1",
        "NS" => "ns1.example.net",
        "MX" => "mail.example.com",
        "TXT" => "verification=keep",
        "CAA" => "0 issue letsencrypt.org"
      }[type]

    name = if type == "NS", do: "delegated.example.com", else: "example.com"
    rr(type <> id, type, name, value, if(type == "MX", do: 10))
  end
end
