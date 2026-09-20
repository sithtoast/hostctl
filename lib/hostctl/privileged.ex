defmodule Hostctl.Privileged do
  @moduledoc "Bounded, versioned local broker client. Never falls back to sudo."

  @max_message 65_536

  def call(operation, payload, opts \\ []) do
    id = Keyword.get_lazy(opts, :request_id, &Ecto.UUID.generate/0)
    path = Keyword.get(opts, :socket, "/run/hostctl-privd/control.sock")
    timeout = Keyword.get(opts, :timeout, 120_000)
    request = Jason.encode!(%{version: 1, id: id, operation: operation, payload: payload}) <> "\n"

    if byte_size(request) > @max_message do
      {:error, :broker_request_too_large}
    else
      with {:ok, socket} <-
             :gen_tcp.connect(
               {:local, String.to_charlist(path)},
               0,
               [:binary, active: false, packet: :line, packet_size: @max_message],
               timeout
             ) do
        try do
          with :ok <- :gen_tcp.send(socket, request),
               {:ok, response} <- :gen_tcp.recv(socket, 0, timeout),
               {:ok, %{"version" => 1, "id" => ^id} = result} <- Jason.decode(response) do
            case result do
              %{"ok" => value, "operation_id" => operation_id} when is_binary(operation_id) ->
                {:ok, value}

              %{"error" => code} when is_binary(code) ->
                {:error, {:broker_rejected, code}}

              _ ->
                {:error, :invalid_broker_response}
            end
          else
            {:error, reason} when reason in [:timeout, :closed] ->
              {:error, :broker_outcome_unknown}

            _ ->
              {:error, :invalid_broker_response}
          end
        after
          :gen_tcp.close(socket)
        end
      else
        {:error, _} -> {:error, :broker_unavailable}
      end
    end
  end
end
