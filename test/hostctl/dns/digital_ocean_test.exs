defmodule Hostctl.DNS.DigitalOceanTest do
  use Hostctl.DataCase
  alias Hostctl.DNS.{DigitalOcean, Zones}
  alias Hostctl.{Hosting, Settings}
  alias Hostctl.Hosting.{Domain, DnsZone, DnsRecord}
  import Hostctl.AccountsFixtures

  setup do
    previous = Application.get_env(:hostctl, :digitalocean_request_options)
    Application.put_env(:hostctl, :digitalocean_request_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:hostctl, :digitalocean_request_options, previous),
        else: Application.delete_env(:hostctl, :digitalocean_request_options)
    end)

    state = start_supervised!({Agent, fn -> %{records: [], requests: [], status: 200} end})

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = if raw == "", do: nil, else: Jason.decode!(raw)

      {status, response} =
        Agent.get_and_update(state, fn st ->
          st = %{
            st
            | requests:
                st.requests ++
                  [
                    {conn.method, conn.request_path, body,
                     Plug.Conn.get_req_header(conn, "authorization")}
                  ]
          }

          cond do
            st.status != 200 ->
              {{st.status, %{"message" => "sensitive-provider-detail"}}, st}

            conn.request_path == "/v2/domains" ->
              {{200, %{"domains" => []}}, st}

            conn.request_path == "/v2/domains/example.com" ->
              {{200, %{"domain" => %{"name" => "example.com"}}}, st}

            conn.method == "GET" ->
              {{200, %{"domain_records" => st.records}}, st}

            conn.method == "POST" ->
              record = Map.put(body, "id", 100 + length(st.records))
              {{201, %{"domain_record" => record}}, %{st | records: st.records ++ [record]}}

            conn.method == "PATCH" ->
              id = String.to_integer(List.last(conn.path_info))

              records =
                Enum.map(st.records, fn r -> if r["id"] == id, do: Map.merge(r, body), else: r end)

              {{200, %{"domain_record" => Enum.find(records, &(&1["id"] == id))}},
               %{st | records: records}}

            conn.method == "DELETE" ->
              id = String.to_integer(List.last(conn.path_info))
              {{204, nil}, %{st | records: Enum.reject(st.records, &(&1["id"] == id))}}
          end
        end)

      if status == 204,
        do: Plug.Conn.send_resp(conn, 204, ""),
        else: conn |> Plug.Conn.put_status(status) |> Req.Test.json(response)
    end)

    {:ok, _} =
      Settings.save_dns_provider_setting(%{
        provider: "digitalocean",
        digitalocean_api_token: "panel-token"
      })

    user = user_fixture()
    domain = Repo.insert!(%Domain{name: "example.com", user_id: user.id})
    zone = Repo.insert!(%DnsZone{domain_id: domain.id, digitalocean_zone_name: domain.name})
    %{state: state, scope: Hostctl.Accounts.Scope.for_user(user), zone: zone, domain: domain}
  end

  test "read-only token test, lookup and link never write", ctx do
    assert {:ok, :readable} = DigitalOcean.verify_token("test")
    assert {:ok, _} = Zones.link(ctx.scope, ctx.zone.id)
    assert writes(ctx.state) == []
  end

  test "SRV, MX, TXT and CAA conversion and CRUD", ctx do
    records = [
      %{
        type: "SRV",
        name: "_imaps._tcp.example.com.",
        value: "0 993 MAIL.EXAMPLE.COM.",
        priority: 10
      },
      %{type: "MX", name: "@", value: "mail.example.com.", priority: 20},
      %{type: "TXT", name: "@", value: "CaseSensitive=Yes", priority: nil},
      %{type: "CAA", name: "@", value: "0 issue \"letsencrypt.org\"", priority: nil}
    ]

    for record <- records do
      assert {:ok, id} = DigitalOcean.create_record("token", "example.com", record)
      assert :ok = DigitalOcean.update_record("token", "example.com", id, record)
      assert :ok = DigitalOcean.delete_record("token", "example.com", id)
    end

    [{_, _, srv, _} | _] = writes(ctx.state)

    assert Map.take(srv, ~w(name data priority weight port)) == %{
             "name" => "_imaps._tcp",
             "data" => "mail.example.com",
             "priority" => 10,
             "weight" => 0,
             "port" => 993
           }

    assert Enum.all?(requests(ctx.state), &(elem(&1, 3) == ["Bearer token"]))
  end

  test "invalid values, out-of-zone names and authoritative NS writes are rejected before HTTP",
       ctx do
    for record <- [
          %{type: "SRV", name: "_imaps._tcp", value: "0 70000 target", priority: 0},
          %{type: "A", name: "elsewhere.net.", value: "192.0.2.1"},
          %{type: "A", name: "@", value: "192.0.2.1", ttl: 1},
          %{type: "NS", name: "@", value: "ns1.example.net"},
          %{type: "CAA", name: "@", value: "0 issue ;"},
          %{type: "MX", name: "@", value: "mail.example.com", priority: nil}
        ] do
      assert {:error, _} = DigitalOcean.create_record("token", "example.com", record)
    end

    assert requests(ctx.state) == []
  end

  test "pagination stays on the fixed API origin despite untrusted next URL" do
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(parent, {conn.host, conn.query_params})

      body =
        if conn.query_params["page"] == "1",
          do: %{
            "domain_records" => [rr(1, "A", "@", "192.0.2.1")],
            "links" => %{"pages" => %{"next" => "https://untrusted.invalid/steal"}}
          },
          else: %{"domain_records" => [rr(2, "A", "@", "192.0.2.2")]}

      Req.Test.json(conn, body)
    end)

    assert {:ok, [%{"id" => 1}, %{"id" => 2}]} = DigitalOcean.list_records("token", "example.com")
    assert_receive {"api.digitalocean.com", %{"page" => "1", "per_page" => "200"}}
    assert_receive {"api.digitalocean.com", %{"page" => "2"}}
  end

  test "malformed record pages fail instead of appearing empty", ctx do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"domain_records" => [%{"id" => 1}]})
    end)

    assert {:error, _} = Zones.sync(ctx.scope, ctx.zone.id)
  end

  test "API failures remain errors and never disclose provider response details", ctx do
    for status <- [401, 403, 404, 422, 429, 500] do
      Agent.update(ctx.state, &%{&1 | status: status})
      assert {:error, message} = DigitalOcean.verify_token("secret")
      assert is_binary(message)
      refute message =~ "sensitive-provider-detail"
    end

    assert writes(ctx.state) == []
  end

  test "synchronization preserves multiple values and adopts exact values without writes", ctx do
    remote = [
      rr(1, "MX", "@", "mail.example.com", 10),
      rr(2, "MX", "@", "mail.example.com", 20),
      rr(3, "TXT", "@", "CaseSensitive"),
      rr(4, "NS", "@", "ns1.digitalocean.com"),
      Map.merge(rr(5, "SRV", "_imaps._tcp", "mail.example.com", 0), %{
        "weight" => 0,
        "port" => 993
      })
    ]

    seed(ctx.state, remote)

    for remote <- remote do
      normalized = DigitalOcean.normalize(remote, "example.com")
      {value, priority} = Hostctl.DNS.Record.local_value(normalized)
      local(ctx.zone, remote["type"], normalized["name"], value, priority: priority)
    end

    local(ctx.zone, "TXT", "@", "casesensitive")
    local(ctx.zone, "TXT", "@", "casesensitive")
    assert {:ok, %{synced: 7, failed: 0}} = Zones.sync(ctx.scope, ctx.zone.id)
    assert [{"POST", _, %{"data" => "casesensitive"}, _}] = writes(ctx.state)
    assert Enum.take(Agent.get(ctx.state, & &1.records), 5) == remote
    assert {:ok, %{synced: 7, failed: 0}} = Zones.sync(ctx.scope, ctx.zone.id)
    assert length(writes(ctx.state)) == 1
  end

  test "shared and repurposed IDs cannot replace remote values", ctx do
    seed(ctx.state, [rr(1, "A", "@", "192.0.2.1"), rr(2, "A", "other", "192.0.2.2")])
    local(ctx.zone, "A", "@", "192.0.2.3", digitalocean_record_id: "1")
    local(ctx.zone, "A", "@", "192.0.2.4", digitalocean_record_id: "1")
    local(ctx.zone, "A", "@", "192.0.2.5", digitalocean_record_id: "2")
    assert {:ok, %{synced: 0, failed: 3}} = Zones.sync(ctx.scope, ctx.zone.id)
    assert writes(ctx.state) == []
  end

  test "a linked update preserves a value another local row needs", ctx do
    seed(ctx.state, [rr(1, "A", "@", "192.0.2.1")])
    local(ctx.zone, "A", "@", "192.0.2.2", digitalocean_record_id: "1")
    local(ctx.zone, "A", "@", "192.0.2.1")
    assert {:ok, %{synced: 1, failed: 1}} = Zones.sync(ctx.scope, ctx.zone.id)
    assert writes(ctx.state) == []
  end

  test "explicit TTL edits update the linked provider record", ctx do
    assert {:ok, record} =
             Hosting.create_dns_record(ctx.zone, %{
               type: "A",
               name: "@",
               value: "192.0.2.1",
               ttl: 600
             })

    assert {:ok, _} = Hosting.update_dns_record(record, %{ttl: 1200})
    assert List.last(writes(ctx.state)) |> elem(2) |> Map.fetch!("ttl") == 1200
  end

  test "CAA quoted values adopt idempotently and retain case", ctx do
    seed(ctx.state, [
      Map.merge(rr(1, "CAA", "@", "letsencrypt.org"), %{"flags" => 0, "tag" => "issue"})
    ])

    local(ctx.zone, "CAA", "@", "0 issue \"letsencrypt.org\"")
    assert {:ok, %{synced: 1, failed: 0}} = Zones.sync(ctx.scope, ctx.zone.id)
    assert writes(ctx.state) == []
  end

  test "linked CRUD syncs and failed remote saves preserve local data", ctx do
    assert {:ok, record} =
             Hosting.create_dns_record(ctx.zone, %{type: "A", name: "@", value: "192.0.2.1"})

    assert record.digitalocean_record_id
    assert {:ok, updated} = Hosting.update_dns_record(record, %{value: "192.0.2.2"})
    Agent.update(ctx.state, &%{&1 | status: 403})
    assert {:error, %Ecto.Changeset{}} = Hosting.update_dns_record(updated, %{value: "192.0.2.3"})
    assert Repo.get!(DnsRecord, record.id).value == "192.0.2.2"
    assert {:error, _} = Hosting.delete_dns_record(updated)
    assert Repo.get!(DnsRecord, record.id)
    Agent.update(ctx.state, &%{&1 | status: 200})
    assert {:ok, _} = Hosting.delete_dns_record(updated)
    refute Repo.get(DnsRecord, record.id)
  end

  test "import retains SRV fields, multiple MX priorities, and remote IDs idempotently", ctx do
    seed(ctx.state, [
      rr(1, "MX", "@", "mail.example.com", 10),
      rr(2, "MX", "@", "mail.example.com", 20),
      Map.merge(rr(3, "SRV", "_imaps._tcp", "mail.example.com", 5), %{
        "weight" => 10,
        "port" => 993
      })
    ])

    assert {:ok, %{imported: 3}} = Zones.import_records(ctx.scope, ctx.zone.id)
    assert {:ok, %{skipped: 3}} = Zones.import_records(ctx.scope, ctx.zone.id)

    assert %{value: "10 993 mail.example.com", priority: 5} =
             Repo.get_by!(DnsRecord, digitalocean_record_id: "3")

    assert writes(ctx.state) == []
  end

  test "provider preferences, encrypted overrides, blank preservation and clearing do not write DNS",
       ctx do
    local(ctx.zone, "A", "@", "192.0.2.1", digitalocean_record_id: "1")

    assert {:ok, zone} =
             Zones.save_provider(ctx.scope, ctx.zone.id, %{
               provider: "digitalocean",
               digitalocean_api_token: "domain-token"
             })

    assert zone.digitalocean_zone_name == nil
    assert Settings.dns_setting_for_zone(zone).digitalocean_api_token == "domain-token"
    assert Repo.one(from r in DnsRecord, select: r.digitalocean_record_id) == nil
    assert {:ok, zone} = Zones.save_provider(ctx.scope, zone.id, %{digitalocean_api_token: ""})
    assert zone.digitalocean_api_token == "domain-token"

    [[stored]] =
      Repo.query!("SELECT digitalocean_api_token FROM dns_zones WHERE id = $1", [zone.id]).rows

    refute stored == "domain-token"
    assert {:ok, "domain-token"} = Hostctl.EncryptedField.load(stored)
    refute inspect(zone) =~ "domain-token"

    assert {:ok, zone} =
             Zones.save_provider(ctx.scope, zone.id, %{clear_digitalocean_token: true})

    assert Settings.dns_setting_for_zone(zone).digitalocean_api_token == "panel-token"
    assert {:ok, zone} = Zones.save_provider(ctx.scope, zone.id, %{provider: "local"})
    assert Settings.dns_setting_for_zone(zone).provider == "local"
    assert {:error, _} = Zones.link(ctx.scope, zone.id)
    assert writes(ctx.state) == []
  end

  test "panel rotation retires shared-token links, but preserves domain-token links", ctx do
    local(ctx.zone, "A", "@", "192.0.2.1", digitalocean_record_id: "1")
    {:ok, setting} = Settings.save_dns_provider_setting(%{digitalocean_api_token: "rotated"})
    refute Repo.get!(DnsZone, ctx.zone.id).digitalocean_zone_name
    refute Repo.one(from r in DnsRecord, select: r.digitalocean_record_id)

    [[stored]] =
      Repo.query!("SELECT digitalocean_api_token FROM dns_provider_settings WHERE id = $1", [
        setting.id
      ]).rows

    refute stored == "rotated"
    {:ok, _} = Zones.save_provider(ctx.scope, ctx.zone.id, %{digitalocean_api_token: "own"})
    {:ok, _} = Zones.link(ctx.scope, ctx.zone.id)
    {:ok, _} = Settings.save_dns_provider_setting(%{digitalocean_api_token: "again"})
    assert Repo.get!(DnsZone, ctx.zone.id).digitalocean_zone_name == "example.com"
  end

  test "foreign owners and users without domains cannot change preferences or access remote zone",
       ctx do
    foreign = Hostctl.Accounts.Scope.for_user(user_fixture())

    for fun <- [
          fn -> Zones.save_provider(foreign, ctx.zone.id, %{provider: "local"}) end,
          fn -> Zones.link(foreign, ctx.zone.id) end,
          fn -> Zones.list(foreign, ctx.zone.id) end,
          fn -> Zones.sync(foreign, ctx.zone.id) end,
          fn -> Zones.import_records(foreign, ctx.zone.id) end,
          fn -> Zones.unlink(foreign, ctx.zone.id) end
        ] do
      assert_raise Ecto.NoResultsError, fun
    end

    assert requests(ctx.state) == []
  end

  test "linked Cloudflare and DigitalOcean zones stay pinned when default changes", ctx do
    cf = %{ctx.zone | digitalocean_zone_name: nil, cloudflare_zone_id: "cf"}
    {:ok, _} = Settings.save_dns_provider_setting(%{provider: "local"})
    assert Settings.dns_setting_for_zone(cf).provider == "cloudflare"
    assert Settings.dns_setting_for_zone(ctx.zone).provider == "digitalocean"
    refute Settings.cloudflare_enabled_for_domain?(ctx.domain)
  end

  defp rr(id, type, name, data, priority \\ nil),
    do: %{
      "id" => id,
      "type" => type,
      "name" => name,
      "data" => data,
      "priority" => priority,
      "ttl" => 600
    }

  defp local(zone, type, name, value, attrs \\ []),
    do:
      Repo.insert!(
        struct(
          DnsRecord,
          Keyword.merge(
            [dns_zone_id: zone.id, type: type, name: name, value: value, ttl: 3600],
            attrs
          )
        )
      )

  defp seed(state, records), do: Agent.update(state, &%{&1 | records: records})
  defp requests(state), do: Agent.get(state, & &1.requests)
  defp writes(state), do: Enum.reject(requests(state), &(elem(&1, 0) == "GET"))
end
