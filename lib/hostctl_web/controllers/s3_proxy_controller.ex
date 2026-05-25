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
         true <- is_binary(backend.access_key_id) && backend.access_key_id != "" do
      object_key = Enum.join(path_parts, "/")

      full_key =
        if backend.path_prefix && backend.path_prefix != "" do
          "#{backend.path_prefix}/#{object_key}"
        else
          object_key
        end

      region = backend.region || "us-east-1"

      case S3Client.get_object(
             backend.endpoint_url,
             backend.bucket,
             full_key,
             backend.access_key_id,
             backend.secret_access_key,
             region
           ) do
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
  defp verify_proxy_token(conn, _opts) do
    expected = proxy_token()
    provided = get_req_header(conn, "x-s3-proxy-token") |> List.first()

    if expected && Plug.Crypto.secure_compare(expected, provided || "") do
      conn
    else
      conn
      |> put_status(403)
      |> text("Forbidden")
      |> halt()
    end
  end

  defp proxy_token do
    Application.get_env(:hostctl, :s3_proxy_token)
  end
end
