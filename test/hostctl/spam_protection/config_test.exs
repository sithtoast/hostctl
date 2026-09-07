defmodule Hostctl.SpamProtection.ConfigTest do
  use ExUnit.Case, async: true
  alias Hostctl.SpamProtection.{Config, Setting, MailboxPolicy}
  alias Hostctl.Hosting.{EmailAccount, Domain}

  test "disabled policy contains no live configuration" do
    assert %{enabled: false, files: files} = Config.bundle(%Setting{}, [])
    assert files == %{}
  end

  test "mailbox overrides are evaluated before server defaults" do
    account = %EmailAccount{username: "a", domain: %Domain{name: "example.com"}}

    policy = %MailboxPolicy{
      email_account: account,
      junk_score: 4,
      block_senders: "bad@example.com"
    }

    script = Config.delivery_sieve(%Setting{junk_score: 8}, [policy])
    [_, override, default] = String.split(script, "if header :contains")
    assert override =~ ~s("****")
    assert default =~ ~s("********")
    assert script =~ ~s(envelope :is "to" "a@example.com")
    assert script =~ ~s(fileinto :create "Junk")
    refute script =~ "discard;"
    refute script =~ "reject "
  end

  test "learning toggle controls both automatic learning and mailbox hooks" do
    enabled = Config.bundle(%Setting{enabled: true, learning: true}, [])
    disabled = Config.bundle(%Setting{enabled: true, learning: false}, [])
    refute enabled.digest == disabled.digest

    assert enabled.files["/etc/dovecot/conf.d/99-hostctl-spam.conf"] =~
             "imapsieve_mailbox2_from = Junk"

    refute disabled.files["/etc/dovecot/conf.d/99-hostctl-spam.conf"] =~ "imapsieve_mailbox2_from"
    assert disabled.files["/etc/rspamd/override.d/classifier-bayes.conf"] =~ "autolearn = false"

    assert enabled.files["/etc/dovecot/hostctl-spam/learn-ham.sieve"] =~
             ~s(environment :is "imap.mailbox" "INBOX")
  end

  test "configuration replaces foreign score headers and does not enable score rejection" do
    bundle = Config.bundle(%Setting{enabled: true}, [])
    assert bundle.files["/etc/rspamd/override.d/milter_headers.conf"] =~ "remove = 0;"
    assert bundle.files["/etc/rspamd/override.d/actions.conf"] =~ "reject = null;"

    assert bundle.files["/etc/rspamd/override.d/worker-controller.inc"] =~
             "hostctl-controller.sock mode=0600 owner=vmail"

    assert bundle.files["/etc/dovecot/conf.d/99-hostctl-spam.conf"] =~
             "mail_plugins = $mail_plugins sieve"
  end
end
