defmodule Hostctl.IsolationTestAdapter do
  @moduledoc false
  def call(operation, payload) do
    send(self(), {:isolation_helper, operation, payload})

    if Process.get(:isolation_fail) == operation do
      {:error, :test_helper_failure}
    else
      case operation do
        "enroll" ->
          {:ok,
           %{
             "username" => payload.username,
             "uid" => 100_000 + payload.owner_id,
             "gid" => 100_000 + payload.owner_id
           }}

        "verify" ->
          {:ok, %{"username" => payload.username, "uid" => payload.uid, "gid" => payload.gid}}

        action when action in ["webroot", "ftp-home", "import-tree"] ->
          {:ok, %{"path" => payload.path}}

        "php" ->
          {:ok, %{"socket" => "/run/php/hostctl-#{payload.username}-#{payload.version}.sock"}}
      end
    end
  end
end
