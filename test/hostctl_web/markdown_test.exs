defmodule HostctlWeb.MarkdownTest do
  use ExUnit.Case, async: true

  defp document(markdown) do
    markdown
    |> HostctlWeb.Markdown.render()
    |> Phoenix.HTML.safe_to_string()
    |> LazyHTML.from_fragment()
  end

  test "preserves release note headings, lists, code, and links" do
    doc = document("# Release\n\n- **Fixed** `assets.deploy`\n\nhttps://example.com/changes")

    assert LazyHTML.text(LazyHTML.query(doc, "h1")) == "Release"
    assert LazyHTML.text(LazyHTML.query(doc, "li strong")) == "Fixed"
    assert LazyHTML.text(LazyHTML.query(doc, "li code")) == "assets.deploy"

    assert LazyHTML.attribute(LazyHTML.query(doc, "a"), "href") ==
             ["https://example.com/changes"]
  end

  test "remote release notes cannot introduce executable HTML or dangerous URLs" do
    doc =
      document("""
      <script>alert(1)</script>

      <img src=x onerror=alert(1)>

      [click](javascript:alert%281%29)

      ![image](data:text/html;base64,PHNjcmlwdD4=)

      text
      {: onclick="alert(1)"}
      """)

    assert LazyHTML.query(doc, "script, iframe, object, [onclick], [onerror]")
           |> LazyHTML.to_tree() == []

    for attr <- ["href", "src"], value <- LazyHTML.attribute(LazyHTML.query(doc, "*"), attr) do
      refute value =~ ~r/^(javascript|data):/i
    end
  end
end
