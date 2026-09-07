defmodule Hostctl.EmailDelivery.Setting do
  use Ecto.Schema
  import Ecto.Changeset

  schema "email_delivery_settings" do
    field :hostname, :string
    field :ipv4, :string
    field :ipv6, :string
    field :spf_include, :string
    field :dkim_records, :string
    field :selector, :string
    field :public_key, :string
    field :signing_enabled, :boolean, default: false
    belongs_to :domain, Hostctl.Hosting.Domain
    timestamps(type: :utc_datetime)
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:hostname, :ipv4, :ipv6, :spf_include, :dkim_records])
    |> validate_change(:hostname, &hostname_error/2)
    |> validate_change(:spf_include, &hostname_error/2)
    |> validate_change(:ipv4, fn field, value -> ip_error(field, value, 4) end)
    |> validate_change(:ipv6, fn field, value -> ip_error(field, value, 8) end)
    |> validate_length(:dkim_records, max: 12_000)
    |> validate_change(:dkim_records, fn field, value ->
      case Hostctl.EmailDelivery.Plan.parse_dkim(value, setting.domain.name) do
        {:ok, _} -> []
        {:error, reason} -> [{field, reason}]
      end
    end)
  end

  def hostname?(value) when is_binary(value) do
    byte_size(value) <= 253 and String.contains?(value, ".") and
      Enum.all?(String.split(value, "."), fn label ->
        Regex.match?(~r/\A[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\z/, label)
      end)
  end

  def hostname?(_), do: false

  defp hostname_error(field, value),
    do: if(hostname?(value), do: [], else: [{field, "enter a fully qualified hostname"}])

  defp ip_error(field, value, size) do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, ip} when tuple_size(ip) == size -> []
      _ -> [{field, "enter a valid IP address"}]
    end
  end
end
