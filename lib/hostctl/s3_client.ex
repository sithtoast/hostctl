defmodule Hostctl.S3Client do
  @moduledoc """
  Minimal S3-compatible client supporting `PutObject` operations with AWS
  Signature Version 4.

  Used by the Plesk importer to upload web files directly to an S3-compatible
  bucket (Wasabi, MinIO, Backblaze B2, etc.) as an alternative to rsyncing
  them to local disk.

  No extra dependencies are required — signing uses `:crypto` (Erlang stdlib).
  """

  require Logger

  @doc """
  Uploads a local file to an S3-compatible bucket.

  ## Parameters

  - `endpoint` — base URL, e.g. `"https://s3.wasabisys.com"` (no trailing slash)
  - `bucket` — bucket name
  - `key` — object key (path within the bucket), e.g. `"path/to/file.html"`
  - `local_path` — absolute path to the file on disk
  - `access_key_id` — AWS/S3 access key ID
  - `secret_access_key` — AWS/S3 secret access key
  - `region` — region string, e.g. `"us-east-1"` (default `"us-east-1"`)

  Returns `:ok` or `{:error, reason}`.
  """
  def put_object(
        endpoint,
        bucket,
        key,
        local_path,
        access_key_id,
        secret_access_key,
        region \\ "us-east-1"
      ) do
    with {:ok, %File.Stat{size: file_size}} <- File.stat(local_path) do
      content_type = mime_type(local_path)
      body_hash = stream_file_sha256(local_path)
      body_stream = File.stream!(local_path, 64 * 1024)

      put_object_body(
        key,
        bucket,
        body_stream,
        file_size,
        body_hash,
        content_type,
        access_key_id,
        secret_access_key,
        region,
        endpoint
      )
    end
  end

  @doc """
  Uploads all files under `local_dir` to the bucket under `key_prefix`.

  Returns `{:ok, count}` where `count` is the number of files uploaded,
  or `{:error, [reason]}` listing per-file failures.
  """
  def upload_directory(
        endpoint,
        bucket,
        key_prefix,
        local_dir,
        access_key_id,
        secret_access_key,
        region \\ "us-east-1",
        progress_callback \\ nil
      ) do
    files =
      local_dir
      |> list_files_recursive()
      |> Enum.sort()

    total = length(files)

    results =
      files
      |> Stream.with_index(1)
      |> Task.async_stream(
        fn {file_path, index} ->
          relative = Path.relative_to(file_path, local_dir)
          key = if key_prefix && key_prefix != "", do: "#{key_prefix}/#{relative}", else: relative

          result =
            case put_object(
                   endpoint,
                   bucket,
                   key,
                   file_path,
                   access_key_id,
                   secret_access_key,
                   region
                 ) do
              :ok ->
                Logger.debug("[S3Client] Uploaded #{key}")
                :ok

              {:error, reason} ->
                Logger.warning("[S3Client] Failed to upload #{key}: #{inspect(reason)}")
                {:error, "#{relative}: #{inspect(reason)}"}
            end

          if progress_callback, do: progress_callback.(index, total, relative, result)
          result
        end,
        timeout: :infinity,
        max_concurrency: 8
      )
      |> Enum.map(fn {:ok, result} -> result end)

    errors = for {:error, r} <- results, do: r
    ok_count = Enum.count(results, &(&1 == :ok))

    if errors == [] do
      {:ok, ok_count}
    else
      {:error, errors}
    end
  end

  # ---------------------------------------------------------------------------
  # Proxy request — used by S3ProxyController to fetch an object with auth
  # ---------------------------------------------------------------------------

  @doc """
  Fetches a single S3 object and returns `{:ok, status, headers, body}` or
  `{:error, reason}`.
  """
  def get_object(endpoint, bucket, key, access_key_id, secret_access_key, region \\ "us-east-1") do
    url = "#{endpoint}/#{bucket}/#{key}"
    now = DateTime.utc_now()
    amzdate = amz_datetime(now)
    datestamp = amz_date(now)
    host = uri_host(endpoint)

    headers_to_sign = [
      {"host", host},
      {"x-amz-date", amzdate}
    ]

    canonical_headers = canonical_headers_string(headers_to_sign)
    signed_headers = signed_headers_string(headers_to_sign)

    body_hash = hex_sha256("")

    canonical_request =
      Enum.join(
        ["GET", "/#{bucket}/#{key}", "", canonical_headers, signed_headers, body_hash],
        "\n"
      )

    auth_header =
      build_auth_header(
        canonical_request,
        amzdate,
        datestamp,
        signed_headers,
        access_key_id,
        secret_access_key,
        region,
        "s3"
      )

    request_headers =
      [
        {"x-amz-date", amzdate},
        {"x-amz-content-sha256", body_hash},
        {"authorization", auth_header}
      ]

    case Req.get(url: url, headers: request_headers, raw: true, retry: false) do
      {:ok, %Req.Response{status: status, headers: resp_headers, body: body}} ->
        {:ok, status, resp_headers, body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Directory listing — list objects at a prefix
  # ---------------------------------------------------------------------------

  @doc """
  Lists objects in an S3 bucket at the given prefix using the ListObjectsV2 API
  with a `/` delimiter for directory-style grouping.

  When `access_key_id` is nil or `""`, the request is made without signing
  (suitable for public buckets).

  Returns `{:ok, %{dirs: [String.t()], files: [map()]}}` or `{:error, reason}`.
  Each file map has keys: `:key`, `:name`, `:size`, `:last_modified`.
  """
  def list_objects_v2(
        endpoint,
        bucket,
        prefix,
        access_key_id,
        secret_access_key,
        region \\ "us-east-1"
      ) do
    encoded_prefix = s3_encode(prefix)
    # Query params must be sorted lexicographically
    canonical_query =
      "delimiter=%2F&list-type=2&max-keys=1000&prefix=#{encoded_prefix}"

    url = "#{endpoint}/#{bucket}?#{canonical_query}"

    if is_binary(access_key_id) && access_key_id != "" do
      now = DateTime.utc_now()
      amzdate = amz_datetime(now)
      datestamp = amz_date(now)
      host = uri_host(endpoint)

      headers_to_sign = [
        {"host", host},
        {"x-amz-date", amzdate}
      ]

      canonical_headers = canonical_headers_string(headers_to_sign)
      signed_headers = signed_headers_string(headers_to_sign)
      body_hash = hex_sha256("")

      canonical_request =
        Enum.join(
          ["GET", "/#{bucket}", canonical_query, canonical_headers, signed_headers, body_hash],
          "\n"
        )

      auth_header =
        build_auth_header(
          canonical_request,
          amzdate,
          datestamp,
          signed_headers,
          access_key_id,
          secret_access_key,
          region,
          "s3"
        )

      request_headers = [
        {"x-amz-date", amzdate},
        {"x-amz-content-sha256", body_hash},
        {"authorization", auth_header}
      ]

      do_list_objects(url, request_headers, prefix)
    else
      do_list_objects(url, [], prefix)
    end
  end

  defp do_list_objects(url, headers, prefix) do
    case Req.get(url: url, headers: headers, retry: false) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        xml = if is_binary(body), do: body, else: IO.iodata_to_binary(body)
        {:ok, parse_list_xml(xml, prefix)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp parse_list_xml(xml, prefix) do
    dirs =
      Regex.scan(~r|<Prefix>(.*?)</Prefix>|s, xml, capture: :all_but_first)
      |> Enum.map(fn [p] -> String.trim(p) end)
      # Filter out the listing prefix itself (it appears as a CommonPrefix in some implementations)
      |> Enum.reject(&(&1 == prefix))

    files =
      Regex.scan(~r|<Contents>(.*?)</Contents>|s, xml, capture: :all_but_first)
      |> Enum.flat_map(fn [block] ->
        key = Regex.run(~r|<Key>(.*?)</Key>|, block, capture: :all_but_first)
        size = Regex.run(~r|<Size>(.*?)</Size>|, block, capture: :all_but_first)

        modified =
          Regex.run(~r|<LastModified>(.*?)</LastModified>|, block, capture: :all_but_first)

        case {key, size} do
          {[k], [s]} ->
            # Skip "directory" placeholder keys (exact prefix match or trailing slash)
            if k == prefix or String.ends_with?(k, "/") do
              []
            else
              name = Path.basename(k)
              mod = if modified, do: List.first(modified), else: ""
              [%{key: k, name: name, size: String.to_integer(s), last_modified: mod}]
            end

          _ ->
            []
        end
      end)

    %{dirs: dirs, files: files}
  end

  @doc """
  Fetches a single S3 object from a public bucket without signing.
  Returns `{:ok, status, headers, body}` or `{:error, reason}`.
  """
  def get_object_public(endpoint, bucket, key) do
    url = "#{endpoint}/#{bucket}/#{key}"

    case Req.get(url: url, raw: true, retry: false) do
      {:ok, %Req.Response{status: status, headers: resp_headers, body: body}} ->
        {:ok, status, resp_headers, body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp put_object_body(
         key,
         bucket,
         body,
         file_size,
         body_hash,
         content_type,
         access_key_id,
         secret_access_key,
         region,
         endpoint
       ) do
    now = DateTime.utc_now()
    amzdate = amz_datetime(now)
    datestamp = amz_date(now)
    host = uri_host(endpoint)
    encoded_key = encode_s3_key(key)

    headers_to_sign = [
      {"content-type", content_type},
      {"host", host},
      {"x-amz-content-sha256", body_hash},
      {"x-amz-date", amzdate}
    ]

    canonical_headers = canonical_headers_string(headers_to_sign)
    signed_headers = signed_headers_string(headers_to_sign)

    canonical_request =
      Enum.join(
        ["PUT", "/#{bucket}/#{encoded_key}", "", canonical_headers, signed_headers, body_hash],
        "\n"
      )

    auth_header =
      build_auth_header(
        canonical_request,
        amzdate,
        datestamp,
        signed_headers,
        access_key_id,
        secret_access_key,
        region,
        "s3"
      )

    request_headers =
      [
        {"content-length", to_string(file_size)},
        {"content-type", content_type},
        {"x-amz-date", amzdate},
        {"x-amz-content-sha256", body_hash},
        {"authorization", auth_header}
      ]

    encoded_url = "#{endpoint}/#{bucket}/#{encoded_key}"

    case Req.put(
           url: encoded_url,
           headers: request_headers,
           body: body,
           retry: false,
           receive_timeout: 300_000
         ) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status, body: resp_body}} ->
        {:error, "HTTP #{status}: #{inspect(resp_body)}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp build_auth_header(
         canonical_request,
         amzdate,
         datestamp,
         signed_headers,
         access_key_id,
         secret_access_key,
         region,
         service
       ) do
    credential_scope = "#{datestamp}/#{region}/#{service}/aws4_request"

    string_to_sign =
      Enum.join(
        ["AWS4-HMAC-SHA256", amzdate, credential_scope, hex_sha256(canonical_request)],
        "\n"
      )

    signing_key = derive_signing_key(secret_access_key, datestamp, region, service)
    signature = hex_hmac_sha256(signing_key, string_to_sign)

    "AWS4-HMAC-SHA256 Credential=#{access_key_id}/#{credential_scope}, SignedHeaders=#{signed_headers}, Signature=#{signature}"
  end

  defp derive_signing_key(secret_access_key, datestamp, region, service) do
    ("AWS4" <> secret_access_key)
    |> hmac_sha256(datestamp)
    |> hmac_sha256(region)
    |> hmac_sha256(service)
    |> hmac_sha256("aws4_request")
  end

  defp hmac_sha256(key, data) when is_binary(key) and is_binary(data) do
    :crypto.mac(:hmac, :sha256, key, data)
  end

  defp hex_hmac_sha256(key, data) do
    key |> hmac_sha256(data) |> Base.encode16(case: :lower)
  end

  defp hex_sha256(data) do
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end

  defp canonical_headers_string(headers) do
    headers
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map(fn {k, v} -> "#{k}:#{String.trim(v)}\n" end)
    |> Enum.join()
  end

  defp signed_headers_string(headers) do
    headers
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map(fn {k, _} -> k end)
    |> Enum.join(";")
  end

  defp amz_datetime(%DateTime{} = dt) do
    dt
    |> DateTime.to_naive()
    |> NaiveDateTime.to_iso8601(:basic)
    |> String.replace(~r/\.\d+$/, "")
    |> Kernel.<>("Z")
  end

  defp amz_date(%DateTime{} = dt) do
    dt |> DateTime.to_date() |> Date.to_iso8601(:basic)
  end

  defp uri_host(endpoint) do
    endpoint |> URI.parse() |> Map.get(:host, endpoint)
  end

  defp mime_type(path) do
    case Path.extname(path) |> String.downcase() do
      ".html" -> "text/html"
      ".htm" -> "text/html"
      ".css" -> "text/css"
      ".js" -> "application/javascript"
      ".json" -> "application/json"
      ".xml" -> "application/xml"
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".gif" -> "image/gif"
      ".svg" -> "image/svg+xml"
      ".ico" -> "image/x-icon"
      ".webp" -> "image/webp"
      ".woff" -> "font/woff"
      ".woff2" -> "font/woff2"
      ".ttf" -> "font/ttf"
      ".pdf" -> "application/pdf"
      ".zip" -> "application/zip"
      ".txt" -> "text/plain"
      _ -> "application/octet-stream"
    end
  end

  @doc """
  Lists all object keys under a given prefix in an S3 bucket (for resume detection).
  Returns `{:ok, [key_string, ...]}` or `{:error, reason}`.
  """
  def list_all_keys(
        endpoint,
        bucket,
        prefix,
        access_key_id,
        secret_access_key,
        region \\ "us-east-1"
      ) do
    list_all_keys_recursive(
      endpoint,
      bucket,
      prefix,
      access_key_id,
      secret_access_key,
      region,
      nil,
      []
    )
  end

  defp list_all_keys_recursive(
         endpoint,
         bucket,
         prefix,
         access_key_id,
         secret_access_key,
         region,
         continuation_token,
         acc
       ) do
    query_params = [
      {"list-type", "2"},
      {"prefix", prefix || ""}
    ]

    query_params =
      if continuation_token,
        do: query_params ++ [{"continuation-token", continuation_token}],
        else: query_params

    query_string = URI.encode_query(query_params)
    url = "#{endpoint}/#{bucket}?#{query_string}"
    amzdate = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    datestamp = amzdate |> String.slice(0..7)
    body_hash = hex_sha256("")

    canonical_headers =
      "host:#{URI.parse(endpoint).host}\nx-amz-content-sha256:#{body_hash}\nx-amz-date:#{amzdate}\n"

    signed_headers = "host;x-amz-content-sha256;x-amz-date"

    canonical_request =
      Enum.join(
        ["GET", "/#{bucket}", query_string, canonical_headers, signed_headers, body_hash],
        "\n"
      )

    auth_header =
      build_auth_header(
        canonical_request,
        amzdate,
        datestamp,
        signed_headers,
        access_key_id,
        secret_access_key,
        region,
        "s3"
      )

    request_headers = [
      {"x-amz-date", amzdate},
      {"x-amz-content-sha256", body_hash},
      {"authorization", auth_header}
    ]

    case Req.get(url: url, headers: request_headers, retry: false) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        xml = if is_binary(body), do: body, else: IO.iodata_to_binary(body)

        # Extract all Key values
        keys =
          Regex.scan(~r|<Key>(.*?)</Key>|s, xml, capture: :all_but_first)
          |> Enum.map(fn [k] -> String.trim(k) end)

        # Check for continuation token
        next_token =
          case Regex.run(~r|<NextContinuationToken>(.*?)</NextContinuationToken>|s, xml,
                 capture: :all_but_first
               ) do
            [token] -> String.trim(token)
            nil -> nil
          end

        acc = acc ++ keys

        if next_token do
          list_all_keys_recursive(
            endpoint,
            bucket,
            prefix,
            access_key_id,
            secret_access_key,
            region,
            next_token,
            acc
          )
        else
          {:ok, acc}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Streams a file in chunks to compute its SHA-256 hash without loading
  # the whole file into memory.
  defp stream_file_sha256(path) do
    path
    |> File.stream!(64 * 1024)
    |> Enum.reduce(:crypto.hash_init(:sha256), fn chunk, acc ->
      :crypto.hash_update(acc, chunk)
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp s3_encode(value) do
    URI.encode(to_string(value), &URI.char_unreserved?/1)
  end

  # Percent-encodes each path segment of an S3 key individually, preserving
  # the "/" separators. Required so that keys with spaces, parentheses, or
  # other special characters produce valid HTTP request targets.
  defp encode_s3_key(key) do
    key
    |> String.split("/")
    |> Enum.map(fn seg -> URI.encode(seg, &URI.char_unreserved?/1) end)
    |> Enum.join("/")
  end

  defp list_files_recursive(dir) do
    dir
    |> File.ls!()
    |> Enum.flat_map(fn entry ->
      full = Path.join(dir, entry)

      if File.dir?(full) do
        list_files_recursive(full)
      else
        [full]
      end
    end)
  rescue
    _ -> []
  end
end
