defmodule Hostctl.Plesk.ImporterTest do
  use ExUnit.Case, async: true

  alias Hostctl.Plesk.Importer

  test "domains_from_object_index_content parses subscription rows" do
    content = """
    subscription\talpha.test\tguid-1\tadmin\tadmin\talpha
    customer\tjohn\tguid-2\tadmin\tadmin\tJohn Doe
    subscription\tbeta.test\tguid-3\tadmin\tadmin\tbeta
    """

    assert Importer.domains_from_object_index_content(content) == ["alpha.test", "beta.test"]
  end

  test "subscriptions_from_object_index_content parses owner and system user" do
    content = """
    subscription\talpha.test\tguid-1\tadmin\tadmin\talpha_sys
    subscription\tbeta.test\tguid-2\tkristan\tcustomer\tbeta_sys
    """

    assert Importer.subscriptions_from_object_index_content(content) == [
             %{
               domain: "alpha.test",
               owner_login: "admin",
               owner_type: "admin",
               system_user: "alpha_sys"
             },
             %{
               domain: "beta.test",
               owner_login: "kristan",
               owner_type: "customer",
               system_user: "beta_sys"
             }
           ]
  end

  test "domains_from_xml_content parses domain-info entries" do
    content = """
    <migration-dump>
      <admin>
        <domains>
          <domain-info name="gamma.test" guid="1"/>
          <domain-info name="delta.test" guid="2"/>
        </domains>
      </admin>
    </migration-dump>
    """

    assert Importer.domains_from_xml_content(content) == ["delta.test", "gamma.test"]
  end

  test "backup_domain_names prefers object_index when present" do
    tmp_root =
      Path.join(System.tmp_dir!(), "hostctl-plesk-import-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join([tmp_root, ".discovered", "backup_info_001"]))

    object_index_path = Path.join([tmp_root, ".discovered", "backup_info_001", "object_index"])

    File.write!(object_index_path, "subscription\tone.test\tguid\nsubscription\ttwo.test\tguid\n")

    File.write!(
      Path.join(tmp_root, "backup_info_001.xml"),
      "<domain-info name=\"xml-only.test\"/>"
    )

    on_exit(fn -> File.rm_rf(tmp_root) end)

    assert {:ok, ["one.test", "two.test"]} = Importer.backup_domain_names(tmp_root)
  end

  test "backup_domain_names falls back to root backup_info xml" do
    tmp_root =
      Path.join(System.tmp_dir!(), "hostctl-plesk-import-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_root)

    File.write!(
      Path.join(tmp_root, "backup_info_123.xml"),
      "<migration-dump><domain-info name=\"xml-domain.test\"/></migration-dump>"
    )

    on_exit(fn -> File.rm_rf(tmp_root) end)

    assert {:ok, ["xml-domain.test"]} = Importer.backup_domain_names(tmp_root)
  end

  test "domain_names_from_api_response supports multiple common payload shapes" do
    assert Importer.domain_names_from_api_response([%{"name" => "a.test"}, %{"name" => "b.test"}]) ==
             ["a.test", "b.test"]

    assert Importer.domain_names_from_api_response(%{"data" => [%{"name" => "c.test"}]}) ==
             ["c.test"]

    assert Importer.domain_names_from_api_response(%{"domains" => [%{name: "d.test"}]}) ==
             ["d.test"]
  end
end
