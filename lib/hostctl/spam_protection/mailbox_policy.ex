defmodule Hostctl.SpamProtection.MailboxPolicy do
  use Ecto.Schema
  import Ecto.Changeset

  schema "spam_mailbox_policies" do
    belongs_to :email_account, Hostctl.Hosting.EmailAccount
    field :junk_score, :integer
    field :allow_senders, :string, default: ""
    field :block_senders, :string, default: ""
    timestamps(type: :utc_datetime)
  end

  def changeset(policy, attrs) do
    attrs =
      Map.new(attrs, fn {key, value} ->
        {key, if(key in [:junk_score, "junk_score"] and value == "", do: nil, else: value)}
      end)

    policy
    |> cast(attrs, [:junk_score, :allow_senders, :block_senders], empty_values: [])
    |> validate_number(:junk_score, greater_than_or_equal_to: 1, less_than_or_equal_to: 20)
    |> validate_senders(:allow_senders)
    |> validate_senders(:block_senders)
    |> unique_constraint(:email_account_id)
    |> foreign_key_constraint(:email_account_id)
    |> validate_overlap()
  end

  def senders(value), do: String.split(value || "", ~r/[\s,]+/, trim: true)

  defp validate_senders(changeset, field) do
    entries =
      changeset |> get_field(field) |> senders() |> Enum.map(&String.downcase/1) |> Enum.uniq()

    cond do
      length(entries) > 100 ->
        add_error(changeset, field, "use at most 100 senders")

      Enum.any?(
        entries,
        &(not Regex.match?(
            ~r/\A[a-z0-9.!\#$%&'+\/?^_`{|}~=-]+@[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\.[a-z]{2,63}\z/i,
            &1
          ))
      ) ->
        add_error(
          changeset,
          field,
          "enter full email addresses, separated by newlines; wildcards are not supported"
        )

      true ->
        put_change(changeset, field, Enum.join(entries, "\n"))
    end
  end

  defp validate_overlap(changeset) do
    allow = senders(get_field(changeset, :allow_senders))
    block = senders(get_field(changeset, :block_senders))

    if Enum.any?(allow, &(&1 in block)),
      do: add_error(changeset, :block_senders, "cannot also appear in allowed senders"),
      else: changeset
  end
end
