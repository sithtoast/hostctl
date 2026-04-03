defmodule HostctlWeb.Plugs.WebmailProxy do
  @moduledoc """
  Reverse proxy plug that forwards `/roundcube`, `/snappymail`, `/phpmyadmin`,
  and `/adminer` requests to the local Apache instance on port 8080, so these
  tools are accessible on the main port without exposing 8080 externally.
  """

  @behaviour Plug

  import Plug.Conn

  @proxy_prefixes ["roundcube", "snappymail", "phpmyadmin", "adminer"]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: [prefix | _]} = conn, _opts) when prefix in @proxy_prefixes do
    proxy_request(conn)
  end

  def call(conn, _opts), do: conn

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
