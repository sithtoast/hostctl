# Run with: mix run --no-start scripts/dkim-test-bundle.exs
setting = %Hostctl.EmailDelivery.Setting{
  domain: %Hostctl.Hosting.Domain{name: "example.com"}, selector: "hc0123456789abcdef"
}
File.write!("/tmp/hostctl-dkim-bundle.json", Jason.encode!(Hostctl.SpamProtection.Config.bundle(%Hostctl.SpamProtection.Setting{enabled: true}, [], [setting])))
