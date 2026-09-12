defmodule HostctlWeb.StatisticsController do
  use HostctlWeb, :controller

  def show(conn, %{"id" => id, "kind" => kind} = params) do
    case Hostctl.Statistics.read_report(conn.assigns.current_scope, id, kind, params["archive"]) do
      {:ok, body, type} ->
        # A report opened directly has the same isolation as the embedded view.
        sandbox = if type == :goaccess, do: "sandbox allow-scripts", else: "sandbox"
        # GoAccess compiles its bundled templates with Function. Keep that permission
        # inside an opaque-origin sandbox; imported Plesk HTML never runs scripts.
        scripts = if type == :goaccess, do: "'unsafe-inline' 'unsafe-eval'", else: "'none'"

        conn =
          conn
          |> put_resp_header(
            "content-security-policy",
            "default-src 'none'; script-src #{scripts}; style-src 'unsafe-inline'; img-src data:; font-src data:; frame-ancestors 'self'; form-action 'none'; base-uri 'none'; " <>
              sandbox
          )
          |> put_resp_header("cache-control", "private, no-store")
          |> put_resp_header("referrer-policy", "no-referrer")
          |> put_resp_header("x-content-type-options", "nosniff")

        case type do
          :archive_text ->
            conn |> put_resp_content_type("text/plain") |> send_resp(200, body)

          :archive_html ->
            safe = MDEx.safe_html(body, escape: [content: false])
            conn |> put_resp_content_type("text/html") |> send_resp(200, safe)

          :goaccess ->
            conn |> put_resp_content_type("text/html") |> send_resp(200, body)
        end

      {:error, :not_found} ->
        send_resp(conn, 404, "Report not found")
    end
  end
end
