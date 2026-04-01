defmodule Hostctl.Plesk.SSHProbeTest do
  use ExUnit.Case, async: true

  alias Hostctl.Plesk.SSHProbe

  test "parse_subscriptions_output parses subscription rows" do
    output = """
    SUB\ttoasted.network\tadmin\tcustomer\ttoasted.network_a5d2uy51xgc
    SUB\tnightgrease.net\tfrank\treseller\tnightgrease.net_diruri3oizr
    """

    assert {:ok, subscriptions} = SSHProbe.parse_subscriptions_output(output)

    assert subscriptions == [
             %{
               domain: "nightgrease.net",
               owner_login: "frank",
               owner_type: "reseller",
               system_user: "nightgrease.net_diruri3oizr",
               subdomains: []
             },
             %{
               domain: "toasted.network",
               owner_login: "admin",
               owner_type: "customer",
               system_user: "toasted.network_a5d2uy51xgc",
               subdomains: []
             }
           ]
  end

  test "parse_subscriptions_output ignores malformed lines" do
    output = """
    some random line
    SUB\t\t\t
    SUB\tsithtoast.com\tadmin\tsithtoast
    """

    assert {:ok, subscriptions} = SSHProbe.parse_subscriptions_output(output)

    assert subscriptions == [
             %{
               domain: "sithtoast.com",
               owner_login: "admin",
               owner_type: nil,
               system_user: "sithtoast",
               subdomains: []
             }
           ]
  end

  test "parse_subscriptions_output returns error when empty" do
    assert {:error, _reason} = SSHProbe.parse_subscriptions_output("")
    assert {:error, _reason} = SSHProbe.parse_subscriptions_output("\n\n")
  end

  test "parse_probe_output parses inventory rows and warnings" do
    output = """
    SUB\tnightgrease.net\tfrank\tnightgrease.net_diruri3oizr
    WEB\tnightgrease.net\tnightgrease.net_diruri3oizr\thttpdocs
    DNS\tnightgrease.net\t12
    DNSOFF\tapi.zer0.tv
    MAIL\tadmin\tnightgrease.net
    MAILDIR\tadmin\tnightgrease.net\t/var/qmail/mailnames/nightgrease.net/admin/Maildir
    DB\tnightgrease_prod\tnightgrease.net
    DBUSER\tnightgrease_user\tnightgrease_prod\tnightgrease.net
    CRON\tnightgrease.net\tnightgrease.net_diruri3oizr\t3
    FTP\tnightgrease_ftp\tnightgrease.net
    SSL\tnightgrease.net\tLetsEncrypt nightgrease.net
    SYS\tnightgrease.net_diruri3oizr\tnightgrease.net
    WARN\tdb_users_query_failed\trelation data_bases_users does not exist
    """

    assert {:ok, discovery} = SSHProbe.parse_probe_output(output)

    assert discovery.subscriptions == [
             %{
               domain: "nightgrease.net",
               owner_login: "frank",
               owner_type: nil,
               system_user: "nightgrease.net_diruri3oizr",
               subdomains: []
             }
           ]

    assert discovery.inventory["web_files"] == [
             %{
               document_root: "httpdocs",
               domain: "nightgrease.net",
               system_user: "nightgrease.net_diruri3oizr"
             }
           ]

    assert discovery.inventory["dns"] == [
             %{domain: "api.zer0.tv", enabled: false, record_count: 0},
             %{domain: "nightgrease.net", enabled: true, record_count: 12}
           ]

    assert discovery.inventory["mail_accounts"] == [
             %{address: "admin@nightgrease.net", domain: "nightgrease.net"}
           ]

    assert discovery.inventory["mail_content"] == [
             %{
               address: "admin@nightgrease.net",
               domain: "nightgrease.net",
               path: "/var/qmail/mailnames/nightgrease.net/admin/Maildir"
             }
           ]

    assert discovery.inventory["databases"] == [
             %{domain: "nightgrease.net", name: "nightgrease_prod"}
           ]

    assert discovery.inventory["db_users"] == [
             %{database: "nightgrease_prod", domain: "nightgrease.net", login: "nightgrease_user"}
           ]

    assert discovery.inventory["cron_jobs"] == [
             %{count: 3, domain: "nightgrease.net", system_user: "nightgrease.net_diruri3oizr"}
           ]

    assert discovery.inventory["ftp_accounts"] == [
             %{domain: "nightgrease.net", login: "nightgrease_ftp"}
           ]

    assert discovery.inventory["ssl_certificates"] == [
             %{domain: "nightgrease.net", name: "LetsEncrypt nightgrease.net"}
           ]

    assert discovery.inventory["system_users"] == [
             %{domain: "nightgrease.net", login: "nightgrease.net_diruri3oizr"}
           ]

    assert discovery.warnings == [
             "db_users_query_failed: relation data_bases_users does not exist"
           ]
  end

  test "parse_probe_output returns remote probe errors" do
    assert {:error, "SSH discovery failed: subscription_list_failed: must run as root"} =
             SSHProbe.parse_probe_output("ERR\tsubscription_list_failed\tmust run as root\n")
  end

  describe "merge_subdomains/1" do
    test "groups subdomains under their parent domain" do
      subscriptions = [
        %{domain: "example.com", owner_login: "admin", owner_type: "admin", system_user: "ex"},
        %{
          domain: "blog.example.com",
          owner_login: "admin",
          owner_type: "admin",
          system_user: "ex"
        },
        %{
          domain: "shop.example.com",
          owner_login: "admin",
          owner_type: "admin",
          system_user: "ex_shop"
        },
        %{
          domain: "otherdomain.org",
          owner_login: "frank",
          owner_type: "customer",
          system_user: "other"
        }
      ]

      result = SSHProbe.merge_subdomains(subscriptions)

      assert length(result) == 2

      example = Enum.find(result, &(&1.domain == "example.com"))
      assert length(example.subdomains) == 2
      assert Enum.find(example.subdomains, &(&1.name == "blog"))
      assert Enum.find(example.subdomains, &(&1.name == "shop"))
      assert Enum.find(example.subdomains, &(&1.name == "shop")).system_user == "ex_shop"

      other = Enum.find(result, &(&1.domain == "otherdomain.org"))
      assert other.subdomains == []
    end

    test "handles deeply nested subdomains by attaching to root" do
      subscriptions = [
        %{domain: "example.com", owner_login: "admin", owner_type: nil, system_user: "ex"},
        %{
          domain: "sub.example.com",
          owner_login: "admin",
          owner_type: nil,
          system_user: "ex"
        },
        %{
          domain: "deep.sub.example.com",
          owner_login: "admin",
          owner_type: nil,
          system_user: "ex"
        }
      ]

      result = SSHProbe.merge_subdomains(subscriptions)

      assert length(result) == 1
      assert hd(result).domain == "example.com"
      assert length(hd(result).subdomains) == 2

      names = Enum.map(hd(result).subdomains, & &1.name)
      assert "deep.sub" in names
      assert "sub" in names
    end

    test "keeps standalone domains when no parent exists" do
      subscriptions = [
        %{
          domain: "sub.example.com",
          owner_login: "admin",
          owner_type: nil,
          system_user: "ex"
        }
      ]

      result = SSHProbe.merge_subdomains(subscriptions)

      assert length(result) == 1
      assert hd(result).domain == "sub.example.com"
      assert hd(result).subdomains == []
    end

    test "returns empty list for empty input" do
      assert SSHProbe.merge_subdomains([]) == []
    end
  end
end
