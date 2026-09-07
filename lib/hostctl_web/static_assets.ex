defmodule HostctlWeb.StaticAssets do
  @moduledoc "Content-versioned development assets; production keeps Phoenix's digest URLs."

  def path(path, code_reloading? \\ HostctlWeb.Endpoint.config(:code_reloader)) do
    static_path = Phoenix.VerifiedRoutes.static_path(HostctlWeb.Endpoint, path)

    if code_reloading? do
      file =
        Application.app_dir(:hostctl, "priv/static") |> Path.join(String.trim_leading(path, "/"))

      case File.read(file) do
        {:ok, contents} ->
          revision = :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)

          static_path <>
            if(String.contains?(static_path, "?"), do: "&", else: "?") <> "v=" <> revision

        {:error, _} ->
          static_path
      end
    else
      static_path
    end
  end
end
