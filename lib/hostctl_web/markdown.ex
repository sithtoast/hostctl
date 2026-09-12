defmodule HostctlWeb.Markdown do
  @moduledoc "Renders remote release notes with HTML sanitization."

  def render(text) when is_binary(text) do
    text
    |> MDEx.to_html!(
      extension: [autolink: true, table: true, strikethrough: true],
      render: [unsafe: false],
      sanitize: MDEx.Document.default_sanitize_options(),
      syntax_highlight: nil
    )
    |> Phoenix.HTML.raw()
  end
end
