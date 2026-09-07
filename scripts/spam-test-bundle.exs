# Run with: mix run --no-start scripts/spam-test-bundle.exs
alias Hostctl.SpamProtection.{Setting, MailboxPolicy, Config}
alias Hostctl.Hosting.{EmailAccount, Domain}

a = %EmailAccount{username: "a", domain: %Domain{name: "example.com"}}
b = %EmailAccount{username: "b", domain: %Domain{name: "example.com"}}

policies = [
  %MailboxPolicy{
    email_account: a,
    junk_score: 4,
    allow_senders: "friend@example.org",
    block_senders: "bad@example.org"
  },
  %MailboxPolicy{email_account: b, junk_score: 8}
]

File.write!(
  "/tmp/hostctl-spam-bundle.json",
  Jason.encode!(Config.bundle(%Setting{enabled: true}, policies))
)
