defmodule Hostctl.EncryptedField do
  @moduledoc """
  Custom Ecto type that transparently encrypts string values before writing to
  the database and decrypts them on read.

  Uses `Plug.Crypto.encrypt/4` (AES-256-GCM) keyed from the Phoenix endpoint's
  `secret_key_base`.  If the `secret_key_base` is rotated, existing encrypted
  values will no longer be decryptable — store a stable, separately-configured
  encryption key in production if key rotation is a concern.

  Values that fail decryption are returned as-is so that unencrypted legacy
  rows continue to load without error.
  """

  @behaviour Ecto.Type

  @salt "hostctl_s3_credential_v1"

  def type, do: :string

  def cast(nil), do: {:ok, nil}
  def cast(value) when is_binary(value), do: {:ok, value}
  def cast(_), do: :error

  def load(nil), do: {:ok, nil}

  def load(value) when is_binary(value) do
    key_base = secret_key_base()

    case Plug.Crypto.decrypt(key_base, @salt, value, max_age: :infinity) do
      {:ok, plaintext} -> {:ok, plaintext}
      # Not encrypted (legacy plain value) — return as-is
      _ -> {:ok, value}
    end
  end

  def dump(nil), do: {:ok, nil}

  def dump(value) when is_binary(value) do
    key_base = secret_key_base()
    {:ok, Plug.Crypto.encrypt(key_base, @salt, value)}
  end

  def dump(_), do: :error

  def equal?(a, b), do: a == b
  def embed_as(_), do: :self

  defp secret_key_base do
    Application.fetch_env!(:hostctl, HostctlWeb.Endpoint)[:secret_key_base]
  end
end
