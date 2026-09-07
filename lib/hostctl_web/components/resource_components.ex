defmodule HostctlWeb.ResourceComponents do
  use HostctlWeb, :html
  attr :domains, :list, required: true
  attr :selected_domain_id, :any, default: nil
  attr :id, :string, required: true
  attr :event, :string, default: "scope_domain"

  def domain_scope(assigns) do
    assigns =
      assign(
        assigns,
        :selected,
        Enum.find(assigns.domains, &(&1.id == assigns.selected_domain_id))
      )

    ~H"""
    <div id={@id} class="resource-toolbar">
      <.form
        :if={length(@domains) > 1}
        for={to_form(%{"domain_id" => @selected_domain_id || "all"})}
        id={"#{@id}-form"}
        phx-change={@event}
      >
        <.input
          type="select"
          name="domain_id"
          value={@selected_domain_id || "all"}
          label="Domain scope"
          options={[{"All domains", "all"} | Enum.map(@domains, &{&1.name, &1.id})]}
        />
      </.form>
      <p :if={length(@domains) <= 1} class="text-sm text-gray-500 dark:text-gray-400">
        {if @selected, do: @selected.name, else: "No domains available"}
      </p>
      <.link
        :if={@selected}
        navigate={~p"/domains/#{@selected.id}"}
        class="text-sm text-indigo-600 dark:text-indigo-400"
      >
        ← Domain overview
      </.link>
    </div>
    """
  end
end
