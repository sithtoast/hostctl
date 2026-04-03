defmodule HostctlWeb.Plugs.WebmailProxy do
  @moduledoc """
  Reverse proxy plug that forwards `/roundcube`, `/snappymail`, `/phpmyadmin`,
  and `/adminer` requests to the local Apache instance on port 8080, so these
  tools are accessible on the main port without exposing 8080 externally.

  `/phpmyadmin` and `/adminer` are restricted to admin users. The session cookie
  is verified inline since this plug runs before `Plug.Session` in the endpoint.
  """

  @behaviour Plug

  import Plug.Conn

  alias Hostctl.Accounts

  @proxy_prefixes ["roundcube", "snappymail", "phpmyadmin", "adminer"]
  @admin_only_prefixes ["phpmyadmin", "adminer"]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: [prefix | _]} = conn, _opts) when prefix in @proxy_prefixes do
    if prefix in @admin_only_prefixes do
      case get_current_user(conn) do
        %{role: "admin"} -> proxy_request(conn)
        _ -> reject_unauthorized(conn)
      end
    else
      proxy_request(conn)
    end
  end

  def call(conn, _opts), do: conn

  # Read the session cookie manually (this plug runs before Plug.Session)
  # and verify the user token to check admin status.
  defp get_current_user(conn) do
    conn = fetch_cookies(conn)
    cookie = conn.cookies["_hostctl_key"]

    with cookie when is_binary(cookie) <- cookie,
         secret_key_base = HostctlWeb.Endpoint.config(:secret_key_base),
         signing_key =
           Plug.Crypto.KeyGenerator.generate(secret_key_base, "jhfCBqbP",
             iterations: 1000,
             length: 32,
             digest: :sha256,
             cache: Plug.Keys
           ),
         {:ok, binary} <- Plug.Crypto.MessageVerifier.verify(cookie, signing_key),
         session_data <- Plug.Crypto.non_executable_binary_to_term(binary),
         %{"user_token" => token} <- session_data,
         {user, _inserted_at} <- Accounts.get_user_by_session_token(token) do
      user
    else
      _ -> nil
    end
  end

  defp reject_unauthorized(conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(403, "Forbidden — admin access required")
    |> halt()
  end

  defp proxy_request(conn) do
    # Read the full request body for POST/PUT
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    url = "http://127.0.0.1:8080#{conn.request_path}"
    url = if conn.query_string != "", do: url <> "?" <> conn.query_string, else: url

    headers =
      conn.req_headers
      |> Enum.reject(fn {k, _} -> k in ["host", "transfer-encoding"] end)

    req_opts = [
      method: method_atom(conn.method),
      url: url,
      headers: headers,
      body: body,
      redirect: false,
      decode_body: false,
      connect_options: [timeout: 15_000],
      receive_timeout: 30_000,
      retry: false
    ]

    case Req.request(req_opts) do
      {:ok, response} ->
        resp_headers =
          response.headers
          |> Enum.flat_map(fn {k, vs} -> Enum.map(List.wrap(vs), &{k, &1}) end)
          |> Enum.reject(fn {k, _} ->
            k in ["transfer-encoding", "connection", "keep-alive", "content-length"]
          end)
          |> Enum.map(fn
            {"location", location} ->
              {"location", rewrite_location(location, conn)}

            other ->
              other
          end)

        conn
        |> prepend_resp_headers(resp_headers)
        |> send_resp(response.status, response.body)
        |> halt()

      {:error, _reason} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(502, "Webmail service unavailable")
        |> halt()
    end
  end

  # Strip the backend host/port from absolute Location headers so redirects
  # go through the proxy instead of leaking http://127.0.0.1:8080/...
  defp rewrite_location(location, conn) do
    case URI.parse(location) do
      %URI{host: "127.0.0.1", port: 8080, path: path, query: query} ->
        base = Atom.to_string(conn.scheme) <> "://" <> conn.host
        base = if conn.port not in [80, 443], do: base <> ":#{conn.port}", else: base
        uri = base <> (path || "/")
        if query, do: uri <> "?" <> query, else: uri

      _ ->
        location
    end
  end

  defp method_atom("GET"), do: :get
  defp method_atom("POST"), do: :post
  defp method_atom("PUT"), do: :put
  defp method_atom("DELETE"), do: :delete
  defp method_atom("PATCH"), do: :patch
  defp method_atom("HEAD"), do: :head
  defp method_atom("OPTIONS"), do: :options
  defp method_atom(_), do: :get
end
