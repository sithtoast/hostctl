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
               system_user: "nightgrease.net_diruri3oizr"
             },
             %{
               domain: "toasted.network",
               owner_login: "admin",
               owner_type: "customer",
               system_user: "toasted.network_a5d2uy51xgc"
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
               system_user: "sithtoast"
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
               system_user: "nightgrease.net_diruri3oizr"
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
             %{domain: "nightgrease.net", record_count: 12}
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
end
