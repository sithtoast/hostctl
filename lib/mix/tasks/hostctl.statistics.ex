defmodule Mix.Tasks.Hostctl.Statistics do
  use Mix.Task
  @shortdoc "Collect domain traffic or import an extracted Plesk statistics directory"
  @moduledoc """
  mix hostctl.statistics collect DOMAIN_ID
  mix hostctl.statistics history DOMAIN_ID SOURCE_DIRECTORY

  Uses the configured repository and private statistics directory. It does not
  start the web application. History replaces the domain's previous imported
  snapshot; current Hostctl traffic is preserved separately.
  """
  def run(["collect", id]), do: Hostctl.Statistics.CLI.run("collect", id, nil)
  def run(["history", id, source]), do: Hostctl.Statistics.CLI.run("history", id, source)

  def run(_),
    do:
      Mix.raise(
        "Usage: mix hostctl.statistics collect DOMAIN_ID | history DOMAIN_ID SOURCE_DIRECTORY"
      )
end
