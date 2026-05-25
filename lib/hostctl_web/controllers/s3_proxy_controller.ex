defmodule HostctlWeb.S3ProxyController do
  @moduledoc """
  Transparent HTTP proxy for domains hosted on private S3-compatible storage.

  When a domain's S3 backend has credentials configured, Nginx forwards
  requests to this controller (at `/_s3_proxy/:backend_id/*path`) rather than
  directly to S3. The controller authenticates with S3 using the stored
  credentials and streams the response back to the client, stripping any
  S3-specific headers so the origin remains transparent.

  Using the backend database ID in the URL allows Nginx to strip any url_path
  prefix (via the proxy_pass URI rewrite) while the controller still resolves
  the correct backend. The S3 object key is built from the backend's
  `path_prefix` combined with the remaining request path.

  The endpoint requires a shared internal secret (`X-S3-Proxy-Token`) to
  prevent abuse — only requests originating from the local Nginx proxy are
  accepted.
  """

  use HostctlWeb, :controller

  alias Hostctl.Repo
  alias Hostctl.S3Client
  alias Hostctl.Hosting.DomainS3Backend

  # Headers that should not be forwarded from the S3 response to the client.
  @strip_response_headers ~w(
    x-amz-id-2
    x-amz-request-id
    x-amz-meta-server-side-encryption
    x-amz-server-side-encryption
    x-amz-bucket-region
    x-amz-delete-marker
    x-amz-version-id
    set-cookie
    server
  )

  plug :verify_proxy_token

  def show(conn, %{"backend_id" => raw_id, "path" => path_parts}) do
    with {id, ""} <- Integer.parse(raw_id),
         %DomainS3Backend{} = backend <- Repo.get(DomainS3Backend, id),
         true <- backend.enabled,
         true <- has_credentials?(backend) || backend.directory_listing do
      if is_directory_request?(conn, path_parts) do
        serve_directory_listing(conn, backend, path_parts)
      else
        serve_object(conn, backend, path_parts)
      end
    else
      _ ->
        conn
        |> put_status(404)
        |> text("Not found")
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp has_credentials?(%DomainS3Backend{access_key_id: key}) do
    is_binary(key) && key != ""
  end

  # A directory request is either an empty path or the original request path
  # ends with "/". We check conn.request_path rather than relying on a trailing
  # "" in path_parts because Phoenix/Plug normalizes path_info by stripping
  # trailing empty segments (so "cool-beans/" arrives as ["cool-beans"]).
  defp is_directory_request?(_conn, []), do: true
  defp is_directory_request?(conn, _parts), do: String.ends_with?(conn.request_path, "/")

  # Reconstructs the original client-facing path from the backend config and path parts.
  # For subdomain backends (url_path nil/empty), the root is "/".
  # For url-path backends, the root is "/{url_path}/".
  # path_parts for a directory request may end with "" (e.g. ["cool-beans", ""]) —
  # that trailing empty segment is stripped for display.
  defp client_display_path(backend, path_parts) do
    parts = Enum.reject(path_parts, &(&1 == ""))

    base =
      if is_binary(backend.url_path) && backend.url_path != "" do
        "/" <> String.trim(backend.url_path, "/") <> "/"
      else
        "/"
      end

    if parts == [] do
      base
    else
      base <> Enum.join(parts, "/") <> "/"
    end
  end

  defp build_full_key(backend, path_parts) do
    object_key = Enum.join(path_parts, "/")

    if backend.path_prefix && backend.path_prefix != "" do
      "#{backend.path_prefix}/#{object_key}"
    else
      object_key
    end
  end

  defp serve_object(conn, backend, path_parts) do
    full_key = build_full_key(backend, path_parts)
    region = backend.region || "us-east-1"

    result =
      if has_credentials?(backend) do
        S3Client.get_object(
          backend.endpoint_url,
          backend.bucket,
          full_key,
          backend.access_key_id,
          backend.secret_access_key,
          region
        )
      else
        S3Client.get_object_public(backend.endpoint_url, backend.bucket, full_key)
      end

    case result do
      {:ok, status, s3_headers, body} ->
        filtered_headers =
          s3_headers
          |> Enum.reject(fn {k, _} ->
            String.downcase(to_string(k)) in @strip_response_headers
          end)

        conn =
          Enum.reduce(filtered_headers, conn, fn {key, value}, c ->
            put_resp_header(c, String.downcase(to_string(key)), to_string(value))
          end)

        conn
        |> put_status(status)
        |> send_resp(status, body)

      {:error, _reason} ->
        conn
        |> put_status(502)
        |> text("Bad gateway")
    end
  end

  defp serve_directory_listing(conn, backend, path_parts) do
    # Build the S3 prefix for listing — always ends with "/" (or "" for root)
    prefix =
      case build_full_key(backend, path_parts) do
        "" -> ""
        p -> if String.ends_with?(p, "/"), do: p, else: p <> "/"
      end

    region = backend.region || "us-east-1"

    case S3Client.list_objects_v2(
           backend.endpoint_url,
           backend.bucket,
           prefix,
           backend.access_key_id,
           backend.secret_access_key,
           region
         ) do
      {:ok, %{dirs: dirs, files: files}} ->
        display_path = client_display_path(backend, path_parts)
        html = render_directory_listing(display_path, prefix, dirs, files)

        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, html)

      {:error, _reason} ->
        conn
        |> put_status(502)
        |> text("Bad gateway")
    end
  end

  defp render_directory_listing(display_path, prefix, dirs, files) do
    breadcrumb_html = build_breadcrumb(display_path)

    parent_link =
      if prefix != "" do
        parent = display_path |> String.trim_trailing("/") |> Path.dirname()
        parent = if parent == ".", do: "/", else: parent

        """
        <tr>
          <td class="icon">&#128193;</td>
          <td class="name"><a href="#{parent}/">..</a></td>
          <td class="size">—</td>
          <td class="date">—</td>
        </tr>
        """
      else
        ""
      end

    dir_rows =
      dirs
      |> Enum.map(fn dir_prefix ->
        # dir_prefix is the full S3 prefix; we want just the directory name
        name = dir_prefix |> String.trim_trailing("/") |> Path.basename()
        href = Path.join(String.trim_trailing(display_path, "/"), name) <> "/"

        """
        <tr>
          <td class="icon">&#128193;</td>
          <td class="name"><a href="#{href}">#{name}/</a></td>
          <td class="size">—</td>
          <td class="date">—</td>
        </tr>
        """
      end)
      |> Enum.join("\n")

    file_rows =
      files
      |> Enum.map(fn %{name: name, size: size, last_modified: modified} ->
        href = Path.join(String.trim_trailing(display_path, "/"), name)
        size_str = format_size(size)
        date_str = format_date(modified)

        """
        <tr>
          <td class="icon">&#128196;</td>
          <td class="name"><a href="#{href}">#{name}</a></td>
          <td class="size">#{size_str}</td>
          <td class="date">#{date_str}</td>
        </tr>
        """
      end)
      |> Enum.join("\n")

    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>Index of #{display_path}</title>
      <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
               max-width: 900px; margin: 2rem auto; padding: 0 1rem;
               color: #1a1a1a; background: #fafafa; }
        h1 { font-size: 1.25rem; font-weight: 600; margin-bottom: 0.25rem; }
        nav.breadcrumb { font-size: 0.9rem; color: #555; margin-bottom: 1.5rem; }
        nav.breadcrumb a { color: #0066cc; text-decoration: none; }
        nav.breadcrumb a:hover { text-decoration: underline; }
        table { width: 100%; border-collapse: collapse; }
        th { text-align: left; padding: 0.5rem 0.75rem; border-bottom: 2px solid #ddd;
             font-size: 0.8rem; text-transform: uppercase; color: #666; }
        td { padding: 0.4rem 0.75rem; border-bottom: 1px solid #eee; font-size: 0.9rem; }
        td.icon { width: 2rem; }
        td.name a { color: #0066cc; text-decoration: none; }
        td.name a:hover { text-decoration: underline; }
        td.size { width: 8rem; text-align: right; color: #555; }
        td.date { width: 16rem; color: #555; }
        tr:hover td { background: #f0f0f0; }
      </style>
    </head>
    <body>
      <h1>Index of #{display_path}</h1>
      #{breadcrumb_html}
      <table>
        <thead>
          <tr>
            <th></th>
            <th>Name</th>
            <th style="text-align:right">Size</th>
            <th>Last Modified</th>
          </tr>
        </thead>
        <tbody>
          #{parent_link}#{dir_rows}
          #{file_rows}
        </tbody>
      </table>
    </body>
    </html>
    """
  end

  defp build_breadcrumb("/"), do: ~s(<nav class="breadcrumb">/ </nav>)

  defp build_breadcrumb(path) do
    parts = path |> String.trim_trailing("/") |> String.split("/", trim: true)

    links =
      parts
      |> Enum.with_index()
      |> Enum.map(fn {part, idx} ->
        href = "/" <> (parts |> Enum.take(idx + 1) |> Enum.join("/"))
        ~s(<a href="#{href}">#{part}</a>)
      end)

    content = (["<a href=\"/\">/</a>"] ++ links) |> Enum.join(" / ")
    ~s(<nav class="breadcrumb">#{content}</nav>)
  end

  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"

  defp format_size(bytes) when bytes < 1_073_741_824,
    do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp format_size(bytes), do: "#{Float.round(bytes / 1_073_741_824, 1)} GB"

  defp format_date(""), do: "—"

  defp format_date(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} ->
        "#{dt.year}-#{pad2(dt.month)}-#{pad2(dt.day)} #{pad2(dt.hour)}:#{pad2(dt.minute)} UTC"

      _ ->
        iso
    end
  end

  defp pad2(n), do: String.pad_leading(to_string(n), 2, "0")

  defp verify_proxy_token(conn, _opts) do
    expected = proxy_token()

    # When no token is configured, the endpoint is trusted via network isolation alone.
    # When a token is configured, it must match exactly.
    if is_nil(expected) || expected == "" do
      conn
    else
      provided = get_req_header(conn, "x-s3-proxy-token") |> List.first()

      if Plug.Crypto.secure_compare(expected, provided || "") do
        conn
      else
        conn
        |> put_status(403)
        |> text("Forbidden")
        |> halt()
      end
    end
  end

  defp proxy_token do
    Application.get_env(:hostctl, :s3_proxy_token)
  end
end
