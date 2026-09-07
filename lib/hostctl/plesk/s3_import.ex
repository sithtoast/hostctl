defmodule Hostctl.Plesk.S3Import do
  @moduledoc "Validates and persists S3 destinations before scheduling import transfers."
  alias Hostctl.Hosting
  alias Hostctl.Hosting.DomainS3Backend
  alias Hostctl.S3Client

  @target_fields [
    :s3_import,
    :s3_endpoint,
    :s3_bucket,
    :s3_prefix,
    :s3_region,
    :s3_access_key,
    :s3_secret_key,
    :ftp_enabled,
    :directory_listing,
    :connection_name
  ]

  def encode_targets(targets) do
    Map.new(targets, fn {target, config} ->
      fields = Map.take(config, @target_fields)

      fields =
        case Map.get(fields, :s3_secret_key) do
          secret when is_binary(secret) and secret != "" ->
            {:ok, encrypted} = Hostctl.EncryptedField.dump(secret)
            Map.put(fields, :s3_secret_key, encrypted)

          _ ->
            fields
        end

      {target, Map.new(fields, fn {key, value} -> {to_string(key), value} end)}
    end)
  end

  def decode_targets(targets) do
    Map.new(targets, fn {target, config} ->
      fields =
        Enum.reduce(@target_fields, %{}, fn key, acc ->
          case Map.fetch(config, to_string(key)) do
            {:ok, value} -> Map.put(acc, key, value)
            :error -> acc
          end
        end)

      fields =
        case Map.get(fields, :s3_secret_key) do
          secret when is_binary(secret) ->
            {:ok, decrypted} = Hostctl.EncryptedField.load(secret)
            Map.put(fields, :s3_secret_key, decrypted)

          _ ->
            fields
        end

      {target, fields}
    end)
  end

  def prepare(nil, _domain), do: {:ok, nil}

  def prepare(targets, domain) when is_map(targets) do
    if Enum.all?(Map.keys(targets), &is_binary/1) do
      Enum.reduce_while(targets, {:ok, %{}}, fn {target, opts}, {:ok, acc} ->
        with true <- is_map(opts),
             {:ok, endpoint} <- S3Client.normalize_endpoint(Map.get(opts, :endpoint)),
             attrs <- attributes(Map.put(opts, :endpoint, endpoint), target, domain),
             cs <- DomainS3Backend.changeset(%DomainS3Backend{domain_id: 1}, attrs),
             cs <- Ecto.Changeset.validate_required(cs, [:access_key_id, :secret_access_key]),
             true <- cs.valid? do
          backend = Ecto.Changeset.apply_changes(cs)

          prepared =
            opts
            |> Map.put(:endpoint, endpoint)
            |> Map.put(:prefix, backend.path_prefix)
            |> Map.put(:exact_prefix, true)

          {:cont, {:ok, Map.put(acc, target, prepared)}}
        else
          _ ->
            {:halt,
             {:error,
              "Invalid S3 destination for #{if target == "", do: domain, else: target <> "." <> domain}. Check endpoint, bucket and credentials."}}
        end
      end)
    else
      # Compatibility with the original single-backend importer API.
      case S3Client.normalize_endpoint(Map.get(targets, :endpoint)) do
        {:ok, endpoint} -> {:ok, Map.put(targets, :endpoint, endpoint)}
        error -> error
      end
    end
  end

  def attributes(opts, target, domain) do
    prefix = Map.get(opts, :prefix, "") || ""
    directory = if target == "", do: "httpdocs", else: target <> "." <> domain

    prefix =
      if Map.get(opts, :exact_prefix, false),
        do: prefix,
        else: Enum.join(Enum.reject([String.trim(prefix, "/"), directory], &(&1 == "")), "/")

    %{
      endpoint_url: Map.get(opts, :endpoint),
      bucket: Map.get(opts, :bucket),
      path_prefix: prefix,
      region: Map.get(opts, :region, "us-east-1"),
      access_key_id: Map.get(opts, :access_key_id),
      secret_access_key: Map.get(opts, :secret_access_key),
      subdomain: target,
      url_path: "",
      ftp_mount_enabled: Map.get(opts, :ftp_mount_enabled, false),
      directory_listing: Map.get(opts, :directory_listing, false)
    }
  end

  def persist(_domain, nil), do: :ok

  def persist(domain, targets) do
    if Enum.all?(Map.keys(targets), &is_binary/1) do
      existing = Hosting.list_s3_backends(domain)

      Enum.reduce_while(targets, :ok, fn {target, opts}, :ok ->
        attrs = attributes(opts, target, domain.name)

        result =
          case Enum.find(existing, &(&1.subdomain == target and &1.url_path == "")) do
            nil -> Hosting.create_s3_backend(domain, attrs)
            backend -> Hosting.update_s3_backend(backend, attrs)
          end

        case result do
          {:ok, _} ->
            {:cont, :ok}

          {:error, _} ->
            {:halt,
             {:error,
              "Could not save S3 mapping for #{target}.#{domain.name}; no transfers started"}}
        end
      end)
    else
      :ok
    end
  end
end
