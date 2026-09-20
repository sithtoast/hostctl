defmodule Hostctl.Portainer do
  @moduledoc "Admin-only management of the fixed Hostctl Portainer Standard Agent."
  alias Hostctl.Accounts.{Scope, User}
  alias Hostctl.Repo

  def changeset(attrs \\ %{}) do
    {%{}, %{version: :string, bind_address: :string, agent_secret: :string}}
    |> Ecto.Changeset.cast(attrs, [:version, :bind_address, :agent_secret], empty_values: [])
    |> Ecto.Changeset.validate_required([:version, :bind_address])
    |> Ecto.Changeset.validate_format(:version, ~r/\A2\.\d{1,3}\.\d{1,3}\z/,
      message: "enter the exact version of your Portainer server, such as 2.39.0"
    )
    |> Ecto.Changeset.validate_length(:agent_secret, max: 256)
    |> Ecto.Changeset.validate_format(:agent_secret, ~r/\A[^\r\n\x00]*\z/)
    |> Ecto.Changeset.validate_change(:bind_address, fn field, value ->
      case :inet.parse_ipv4strict_address(String.to_charlist(value)) do
        {:ok, _} -> []
        _ -> [{field, "enter an IPv4 address on this server"}]
      end
    end)
  end

  def status(%Scope{} = scope) do
    with :ok <- authorize(scope), do: adapter().call("portainer-status", %{})
  end

  def install(%Scope{} = scope, attrs) do
    with :ok <- authorize(scope),
         {:ok, params} <- Ecto.Changeset.apply_action(changeset(attrs), :insert) do
      adapter().call("portainer-install", Map.put_new(params, :agent_secret, ""))
    end
  end

  def remove(%Scope{} = scope) do
    with :ok <- authorize(scope), do: adapter().call("portainer-remove", %{})
  end

  defp authorize(%Scope{user: %User{id: id}}) do
    # Recheck persisted authority: an already-open page cannot retain a revoked role.
    case Repo.get(User, id) do
      %User{role: "admin"} -> :ok
      _ -> {:error, :forbidden}
    end
  end

  defp authorize(_), do: {:error, :forbidden}
  defp adapter, do: Application.get_env(:hostctl, :portainer_adapter, Hostctl.Portainer.System)
end
