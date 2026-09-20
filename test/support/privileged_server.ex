defmodule Hostctl.TestPrivilegedServer do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def init(opts) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :line, ifaddr: {:local, opts[:path]}])

    {:ok, {listener, opts}, {:continue, :serve}}
  end

  def handle_continue(:serve, {listener, opts} = state) do
    {:ok, socket} = :gen_tcp.accept(listener)
    {:ok, line} = :gen_tcp.recv(socket, 0, 1000)
    request = Jason.decode!(line)
    send(opts[:owner], {:broker_request, request})
    response = opts[:reply].(request)
    :ok = :gen_tcp.send(socket, Jason.encode!(response) <> "\n")
    :gen_tcp.close(socket)
    {:noreply, state}
  end

  def terminate(_, {listener, _opts}), do: :gen_tcp.close(listener)
end
