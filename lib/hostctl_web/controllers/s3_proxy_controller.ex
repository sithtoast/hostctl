defmodule HostctlWeb.S3ProxyController do
  @moduledoc """
  Transparent HTTP proxy for domains hosted on private S3-compatible storage.

  When a domain's S3 backend has credentials configured, Nginx forwards
  requests to this controller (at `/_s3_proxy/:domain/*path`) rather than
  directly to S3. The controller authenticates with S3 using the stored
  credentials and streams the response back to the client, stripping any
  S3-specific headers so the origin remains transparent.

  This allows serving from private buckets (e.g. Wasabi, MinIO) without
  requiring the `ngx_http_aws_auth` Nginx module.

  The endpoint requires a shared internal secret (`X-S3-Proxy-Token`) to
  prevent abuse — only requests originating from the local Nginx proxy are
  accepted.
  """

  use HostctlWeb, :controller

  alias Hostctl.S3Client

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

  def show(conn, %{"domain" => domain_name, "path" => path_parts}) do
    object_key = Enum.join(path_parts, "/")

    case get_s3_backend_for_domain(domain_name) do
      nil ->
        conn
        |> put_status(404)
        |> text("Not found")

      backend ->
        full_key =
          if backend.path_prefix && backend.path_prefix != "" do
            "#{backend.path_prefix}/#{object_key}"
          else
            object_key
          end

        region = Map.get(backend, :region, "us-east-1") || "us-east-1"

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
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp get_s3_backend_for_domain(domain_name) do
    import Ecto.Query

    alias Hostctl.Repo
    alias Hostctl.Hosting.{Domain, DomainS3Backend}

    domain =
      Repo.one(
        from d in Domain,
          where: d.name == ^domain_name,
          limit: 1
      )

    case domain do
      nil ->
        nil

      domain ->
        backend = Repo.get_by(DomainS3Backend, domain_id: domain.id)

        if backend && backend.enabled &&
             is_binary(backend.access_key_id) && backend.access_key_id != "" &&
             is_binary(backend.secret_access_key) && backend.secret_access_key != "" do
          backend
        else
          nil
        end
    end
  end

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
