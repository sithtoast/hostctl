defmodule Hostctl.Backup.S3 do
  @moduledoc """
  S3-compatible object storage client using AWS Signature V4.

  Supports AWS S3, MinIO, Backblaze B2, Wasabi, and any S3-compatible service.
  Uses path-style URL addressing for maximum compatibility.

  Files smaller than 10 MB are uploaded in a single PUT request.
  Larger files use multipart upload (5 MB minimum part size, 10 MB chunks).
  """

  require Logger

  @multipart_threshold 10 * 1024 * 1024
  @part_size 10 * 1024 * 1024

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Uploads a local file to S3.
  Returns `{:ok, s3_key}` or `{:error, reason}`.
  """
  def upload(%{} = cfg, local_path, s3_key) do
    with {:ok, %File.Stat{size: size}} <- File.stat(local_path) do
      if size > @multipart_threshold do
        multipart_upload(cfg, local_path, s3_key)
      else
        single_upload(cfg, local_path, s3_key)
      end
    else
      {:error, reason} -> {:error, "Cannot access file: #{inspect(reason)}"}
    end
  end

  @doc """
  Lists all objects under the given prefix in an S3 bucket.
  Returns `{:ok, [%{key: key, last_modified: datetime_string}]}` or `{:error, reason}`.
  """
  def list_objects(%{} = cfg, prefix) do
    now = DateTime.utc_now()
    path = "/#{cfg.s3_bucket}"
    encoded_prefix = encode_value(prefix)
    query = "list-type=2&max-keys=1000&prefix=#{encoded_prefix}"
    host = endpoint_host(cfg.s3_endpoint)
    payload_hash = sha256_hex("")

    headers =
      sign(
        "GET",
        path,
        query,
        [
          {"host", host},
          {"x-amz-content-sha256", payload_hash},
          {"x-amz-date", fmt_datetime(now)}
        ],
        payload_hash,
        now,
        cfg
      )

    url = endpoint_url(cfg.s3_endpoint) <> path <> "?" <> query

    case Req.get(url, headers: headers) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, parse_list_response(body)}

      {:ok, %Req.Response{status: s, body: b}} ->
        {:error, "List objects failed: HTTP #{s}: #{body_text(b)}"}

      {:error, reason} ->
        {:error, "List objects request failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Deletes a single object from S3.
  Returns `:ok` or `{:error, reason}`.
  """
  def delete_object(%{} = cfg, s3_key) do
    now = DateTime.utc_now()
    path = object_path(cfg.s3_bucket, s3_key)
    host = endpoint_host(cfg.s3_endpoint)
    payload_hash = sha256_hex("")

    headers =
      sign(
        "DELETE",
        path,
        "",
        [
          {"host", host},
          {"x-amz-content-sha256", payload_hash},
          {"x-amz-date", fmt_datetime(now)}
        ],
        payload_hash,
        now,
        cfg
      )

    url = endpoint_url(cfg.s3_endpoint) <> path

    case Req.delete(url, headers: headers) do
      {:ok, %Req.Response{status: s}} when s in [200, 204] ->
        :ok

      {:ok, %Req.Response{status: s, body: b}} ->
        {:error, "Delete failed: HTTP #{s}: #{body_text(b)}"}

      {:error, reason} ->
        {:error, "Delete request failed: #{inspect(reason)}"}
    end
  end

  # ---------------------------------------------------------------------------
  # Single PUT upload
  # ---------------------------------------------------------------------------

  defp single_upload(%{} = cfg, local_path, s3_key) do
    with {:ok, body} <- File.read(local_path) do
      now = DateTime.utc_now()
      payload_hash = sha256_hex(body)
      path = object_path(cfg.s3_bucket, s3_key)
      host = endpoint_host(cfg.s3_endpoint)

      headers =
        sign(
          "PUT",
          path,
          "",
          [
            {"content-length", to_string(byte_size(body))},
            {"content-type", "application/octet-stream"},
            {"host", host},
            {"x-amz-content-sha256", payload_hash},
            {"x-amz-date", fmt_datetime(now)}
          ],
          payload_hash,
          now,
          cfg
        )

      url = endpoint_url(cfg.s3_endpoint) <> path

      case Req.put(url, headers: headers, body: body) do
        {:ok, %Req.Response{status: s}} when s in 200..299 ->
          {:ok, s3_key}

        {:ok, %Req.Response{status: s, body: b}} ->
          {:error, "S3 PUT failed #{s}: #{body_text(b)}"}

        {:error, reason} ->
          {:error, "S3 PUT request failed: #{inspect(reason)}"}
      end
    else
      {:error, reason} -> {:error, "Cannot read file: #{inspect(reason)}"}
    end
  end

  # ---------------------------------------------------------------------------
  # Multipart upload
  # ---------------------------------------------------------------------------

  defp multipart_upload(%{} = cfg, local_path, s3_key) do
    with {:ok, upload_id} <- initiate_multipart(cfg, s3_key),
         {:ok, parts} <- upload_all_parts(cfg, local_path, s3_key, upload_id),
         :ok <- complete_multipart(cfg, s3_key, upload_id, parts) do
      {:ok, s3_key}
    end
  end

  defp initiate_multipart(%{} = cfg, s3_key) do
    now = DateTime.utc_now()
    path = object_path(cfg.s3_bucket, s3_key)
    host = endpoint_host(cfg.s3_endpoint)
    payload_hash = sha256_hex("")

    headers =
      sign(
        "POST",
        path,
        "uploads=",
        [
          {"content-type", "application/octet-stream"},
          {"host", host},
          {"x-amz-content-sha256", payload_hash},
          {"x-amz-date", fmt_datetime(now)}
        ],
        payload_hash,
        now,
        cfg
      )

    url = endpoint_url(cfg.s3_endpoint) <> path <> "?uploads"

    case Req.post(url, headers: headers, body: "") do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, extract_upload_id(body)}

      {:ok, %Req.Response{status: s, body: b}} ->
        {:error, "Initiate multipart failed: HTTP #{s}: #{body_text(b)}"}

      {:error, reason} ->
        {:error, "Initiate multipart request failed: #{inspect(reason)}"}
    end
  end

  defp upload_all_parts(%{} = cfg, local_path, s3_key, upload_id) do
    result =
      local_path
      |> File.stream!([], @part_size)
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, []}, fn {chunk, part_num}, {:ok, acc} ->
        chunk_bin = IO.iodata_to_binary(chunk)

        case upload_single_part(cfg, s3_key, upload_id, part_num, chunk_bin) do
          {:ok, etag} -> {:cont, {:ok, [{part_num, etag} | acc]}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      {:ok, parts} -> {:ok, Enum.reverse(parts)}
      err -> err
    end
  end

  defp upload_single_part(%{} = cfg, s3_key, upload_id, part_number, body) do
    now = DateTime.utc_now()
    path = object_path(cfg.s3_bucket, s3_key)
    query = "partNumber=#{part_number}&uploadId=#{encode_value(upload_id)}"
    host = endpoint_host(cfg.s3_endpoint)
    payload_hash = sha256_hex(body)

    headers =
      sign(
        "PUT",
        path,
        query,
        [
          {"content-length", to_string(byte_size(body))},
          {"host", host},
          {"x-amz-content-sha256", payload_hash},
          {"x-amz-date", fmt_datetime(now)}
        ],
        payload_hash,
        now,
        cfg
      )

    url = endpoint_url(cfg.s3_endpoint) <> path <> "?" <> query

    case Req.put(url, headers: headers, body: body) do
      {:ok, %Req.Response{status: s, headers: resp_headers}} when s in 200..299 ->
        etag = get_response_header(resp_headers, "etag") || ""
        {:ok, String.trim(etag, "\"")}

      {:ok, %Req.Response{status: s, body: b}} ->
        {:error, "Part #{part_number} upload failed: HTTP #{s}: #{body_text(b)}"}

      {:error, reason} ->
        {:error, "Part #{part_number} request failed: #{inspect(reason)}"}
    end
  end

  defp complete_multipart(%{} = cfg, s3_key, upload_id, parts) do
    now = DateTime.utc_now()
    path = object_path(cfg.s3_bucket, s3_key)
    query = "uploadId=#{encode_value(upload_id)}"
    host = endpoint_host(cfg.s3_endpoint)
    xml_body = build_complete_xml(parts)
    payload_hash = sha256_hex(xml_body)

    headers =
      sign(
        "POST",
        path,
        query,
        [
          {"content-length", to_string(byte_size(xml_body))},
          {"content-type", "application/xml"},
          {"host", host},
          {"x-amz-content-sha256", payload_hash},
          {"x-amz-date", fmt_datetime(now)}
        ],
        payload_hash,
        now,
        cfg
      )

    url = endpoint_url(cfg.s3_endpoint) <> path <> "?" <> query

    case Req.post(url, headers: headers, body: xml_body) do
      {:ok, %Req.Response{status: s}} when s in 200..299 ->
        :ok

      {:ok, %Req.Response{status: s, body: b}} ->
        {:error, "Complete multipart failed: HTTP #{s}: #{body_text(b)}"}

      {:error, reason} ->
        {:error, "Complete multipart request failed: #{inspect(reason)}"}
    end
  end

  # ---------------------------------------------------------------------------
  # AWS Signature V4
  # ---------------------------------------------------------------------------

  # Builds and signs headers, returning the list of headers to send (excluding "host").
  defp sign(method, path, query_string, base_headers, payload_hash, now, cfg) do
    region = cfg.s3_region || "us-east-1"
    date = fmt_date(now)
    datetime = fmt_datetime(now)

    sorted = Enum.sort_by(base_headers, fn {k, _} -> k end)
    signed_headers_str = Enum.map_join(sorted, ";", fn {k, _} -> k end)
    canonical_headers_str = Enum.map_join(sorted, "", fn {k, v} -> "#{k}:#{v}\n" end)

    canonical_qs = canonical_query_string(query_string)

    canonical_request =
      [method, path, canonical_qs, canonical_headers_str, signed_headers_str, payload_hash]
      |> Enum.join("\n")

    scope = "#{date}/#{region}/s3/aws4_request"

    string_to_sign =
      ["AWS4-HMAC-SHA256", datetime, scope, sha256_hex(canonical_request)]
      |> Enum.join("\n")

    signing_key =
      ("AWS4" <> cfg.s3_secret_access_key)
      |> hmac(date)
      |> hmac(region)
      |> hmac("s3")
      |> hmac("aws4_request")

    signature = hmac_hex(signing_key, string_to_sign)

    auth =
      "AWS4-HMAC-SHA256 " <>
        "Credential=#{cfg.s3_access_key_id}/#{scope}, " <>
        "SignedHeaders=#{signed_headers_str}, " <>
        "Signature=#{signature}"

    sorted
    |> Enum.reject(fn {k, _} -> k == "host" end)
    |> Enum.concat([{"authorization", auth}])
  end

  defp canonical_query_string(""), do: ""
  defp canonical_query_string(nil), do: ""

  defp canonical_query_string(qs) do
    qs
    |> String.split("&", trim: true)
    |> Enum.map(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [k, v] -> {encode_value(URI.decode(k)), encode_value(URI.decode(v))}
        [k] -> {encode_value(URI.decode(k)), ""}
      end
    end)
    |> Enum.sort()
    |> Enum.map_join("&", fn {k, v} -> "#{k}=#{v}" end)
  end

  # ---------------------------------------------------------------------------
  # URL / path helpers
  # ---------------------------------------------------------------------------

  defp endpoint_url(nil), do: "https://s3.amazonaws.com"

  defp endpoint_url(ep) do
    ep = String.trim(ep)
    if String.starts_with?(ep, "http"), do: ep, else: "https://#{ep}"
  end

  defp endpoint_host(ep), do: URI.parse(endpoint_url(ep)).host

  defp object_path(bucket, key) do
    "/" <> encode_path_seg(bucket) <> "/" <> encode_s3_key(key)
  end

  defp encode_s3_key(key) do
    key |> String.split("/") |> Enum.map_join("/", &encode_path_seg/1)
  end

  # Encode a single path segment using RFC 3986 unreserved characters only.
  defp encode_path_seg(seg), do: URI.encode(seg, &URI.char_unreserved?/1)

  # Encode a query parameter value using RFC 3986 unreserved characters only.
  defp encode_value(str), do: URI.encode(to_string(str), &URI.char_unreserved?/1)

  # ---------------------------------------------------------------------------
  # Crypto helpers
  # ---------------------------------------------------------------------------

  defp sha256_hex(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)

  defp hmac_hex(key, data),
    do: :crypto.mac(:hmac, :sha256, key, data) |> Base.encode16(case: :lower)

  defp fmt_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y%m%dT%H%M%SZ")
  defp fmt_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y%m%d")

  # ---------------------------------------------------------------------------
  # Response helpers
  # ---------------------------------------------------------------------------

  defp extract_upload_id(body) when is_binary(body) do
    case Regex.run(~r/<UploadId>(.+?)<\/UploadId>/s, body) do
      [_, id] -> id
      _ -> raise "Could not extract UploadId from response: #{body}"
    end
  end

  defp extract_upload_id(body),
    do: raise("Unexpected response body for initiate_multipart: #{inspect(body)}")

  defp build_complete_xml(parts) do
    parts_xml =
      Enum.map_join(parts, "\n", fn {num, etag} ->
        ~s(<Part><PartNumber>#{num}</PartNumber><ETag>"#{etag}"</ETag></Part>)
      end)

    ~s(<?xml version="1.0" encoding="UTF-8"?><CompleteMultipartUpload>#{parts_xml}</CompleteMultipartUpload>)
  end

  defp get_response_header(headers, name) when is_map(headers) do
    headers |> Map.get(name) |> List.wrap() |> List.first()
  end

  defp get_response_header(headers, name) when is_list(headers) do
    case Enum.find(headers, fn {k, _} -> String.downcase(to_string(k)) == name end) do
      {_, v} -> v
      nil -> nil
    end
  end

  defp parse_list_response(body) when is_binary(body) do
    Regex.scan(
      ~r/<Contents>.*?<Key>(.*?)<\/Key>.*?<LastModified>(.*?)<\/LastModified>.*?<\/Contents>/s,
      body
    )
    |> Enum.map(fn [_, key, last_modified] -> %{key: key, last_modified: last_modified} end)
  end

  defp parse_list_response(_), do: []

  defp body_text(body) when is_binary(body), do: body
  defp body_text(body), do: inspect(body)
end
