# Loaded by scripts/isolation-smoke through the running release's RPC endpoint.
defmodule Hostctl.IsolationSmoke do
  alias Hostctl.{Accounts, Hosting}
  alias Hostctl.Accounts.Scope
  alias Hostctl.Isolation.Runtime

  def run do
    :global.trans({__MODULE__, self()}, fn -> run_locked() end)
  end

  defp run_locked do
    tag = "hc-check-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    Process.put(:isolation_smoke_owners, [])
    Process.put(:isolation_smoke_domains, [])

    result =
      try do
        unless Application.get_env(:hostctl, :web_server, [])[:enabled],
          do: raise("Web server integration must be enabled")

        a = create_owner(tag <> "-a")
        b = create_owner(tag <> "-b")
        check(a.identity.uid != b.identity.uid, "Distinct Linux UIDs")
        token = Base.encode16(:crypto.strong_rand_bytes(24))

        for {source, peer} <- [{a, b}, {b, a}] do
          write_as_owner(source, "proof.txt", tag)
          write_as_owner(source, "probe.php", probe(source, peer, token))
        end

        for {source, peer} <- [{a, b}, {b, a}] do
          response = request(source, "/proof.txt", token)

          check(
            response.status == 200 and response.body == tag,
            "#{source.name}: Nginx static read"
          )

          response = request(source, "/probe.php", token)
          check(response.status == 200, "#{source.name}: PHP HTTP response")
          data = Jason.decode!(response.body)
          check(data["uid"] == source.identity.uid, "#{source.name}: PHP executes as its owner")

          check(
            data["own_read"] and data["own_write"],
            "#{source.name}: own files readable and writable"
          )

          check(
            data["peer_read_denied"] and data["peer_write_denied"] and data["peer_create_denied"] and
              data["peer_list_denied"],
            "#{source.name}: cross-owner read/write/list denied"
          )

          check(
            data["session_ok"] and
              data["session_path"] ==
                "/var/lib/hostctl-accounts/#{source.identity.username}/sessions",
            "#{source.name}: private PHP sessions"
          )

          check(data["link_created"], "#{source.name}: symlink probe created")
          link = request(source, "/peer-link.txt", token)
          check(link.status in [403, 404], "#{source.name}: Nginx rejects cross-owner symlinks")
          denied_as("www-data", source.root <> "/proof.txt", 4)

          denied_as(
            peer.identity.username,
            Runtime.php_socket(source.identity, source.domain.php_version),
            2
          )
        end

        {:ok, "PHP, file isolation, private sessions, Nginx reads and symlink protections passed"}
      rescue
        error -> {:error, Exception.message(error)}
      after
        Process.put(:isolation_smoke_cleanup, cleanup())
      end

    case {result, Process.get(:isolation_smoke_cleanup)} do
      {{:ok, message}, []} ->
        IO.puts("PASS: " <> message)

        IO.puts(
          "Test domains, files and panel users removed. Locked Linux identities and pool definitions remain reserved by Hostctl."
        )

        :ok

      {outcome, errors} ->
        IO.puts("FAIL: #{inspect(outcome)}; cleanup errors: #{inspect(errors)}")
        {:error, :isolation_smoke_failed}
    end
  end

  defp create_owner(label) do
    {:ok, user} =
      Accounts.create_panel_user(%{
        name: "Isolation check " <> label,
        email: label <> "@example.invalid"
      })

    Process.put(:isolation_smoke_owners, [user | Process.get(:isolation_smoke_owners)])
    scope = Scope.for_user(user)
    {:ok, identity} = Runtime.prepare_import_owner(scope)
    name = label <> ".test"
    # Track before provisioning so partial filesystem creation can be cleaned up.
    candidate = %Hostctl.Hosting.Domain{
      id: -1,
      user_id: user.id,
      name: name,
      document_root: "/var/www/#{name}/httpdocs"
    }

    Process.put(:isolation_smoke_domains, [
      {scope, candidate} | Process.get(:isolation_smoke_domains)
    ])

    {:ok, domain} =
      Hosting.create_domain(scope, %{name: name, apply_dns_template: false, ssl_enabled: false})

    %{name: name, domain: domain, identity: identity, root: domain.document_root}
  end

  defp write_as_owner(owner, name, content) do
    code =
      "import os,sys,base64; f=os.open(sys.argv[1],os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o640); os.write(f,base64.b64decode(sys.argv[2])); os.close(f)"

    command([
      "--uid=" <> owner.identity.username,
      "--gid=" <> owner.identity.username,
      "/usr/bin/python3",
      "-c",
      code,
      owner.root <> "/" <> name,
      Base.encode64(content)
    ])
  end

  defp probe(source, peer, token) do
    # Paths and token are generated here, never taken from external input.
    config = Base.encode64(Jason.encode!(%{own: source.root, peer: peer.root, token: token}))

    """
    <?php
    $c = json_decode(base64_decode('#{config}'), true);
    if (($_SERVER['HTTP_X_HOSTCTL_TEST'] ?? '') !== $c['token'] ||
        !in_array($_SERVER['REMOTE_ADDR'], ['127.0.0.1', '::1'], true)) {
      http_response_code(404); exit;
    }
    session_start(); $_SESSION['probe'] = 'ok';
    $r = [
      'uid' => posix_geteuid(),
      'own_read' => @file_get_contents($c['own'].'/proof.txt') !== false,
      'own_write' => @file_put_contents($c['own'].'/written.txt', 'ok') === 2,
      'peer_read_denied' => @file_get_contents($c['peer'].'/proof.txt') === false,
      'peer_write_denied' => @file_put_contents($c['peer'].'/proof.txt', 'FAIL') === false,
      'peer_create_denied' => @file_put_contents($c['peer'].'/cross-write.txt', 'FAIL') === false,
      'peer_list_denied' => @scandir($c['peer']) === false,
      'session_ok' => session_status() === PHP_SESSION_ACTIVE,
      'session_path' => session_save_path(),
      'link_created' => @symlink($c['peer'].'/proof.txt', $c['own'].'/peer-link.txt')
    ];
    session_write_close();
    header('Content-Type: application/json'); echo json_encode($r);
    """
  end

  defp request(owner, path, token) do
    Req.get!("http://127.0.0.1" <> path,
      headers: [{"host", owner.name}, {"x-hostctl-test", token}],
      redirect: false,
      retry: false,
      decode_body: false,
      receive_timeout: 15_000
    )
  end

  defp denied_as(user, path, mode) do
    # Require a successful probe process; a systemd startup error is a failure,
    # never evidence that file access was denied.
    code =
      "import os,sys,json; print(json.dumps({'user':__import__('pwd').getpwuid(os.geteuid()).pw_name,'allowed':os.access(sys.argv[1],int(sys.argv[2]))}))"

    output = command(["--uid=" <> user, "/usr/bin/python3", "-c", code, path, to_string(mode)])
    data = Jason.decode!(String.trim(output))
    check(data["user"] == user and data["allowed"] == false, "#{user}: denied access to #{path}")
  end

  defp command(args) do
    case System.cmd(
           "sudo",
           ["-n", "systemd-run", "--pipe", "--wait", "--collect", "--quiet" | args],
           stderr_to_stdout: true
         ) do
      {output, 0} -> output
      {_output, status} -> raise("Probe command failed with exit #{status}")
    end
  end

  defp check(true, label), do: IO.puts("PASS: " <> label)
  defp check(_, label), do: raise("Check failed: " <> label)

  defp cleanup do
    errors =
      Enum.reduce(Process.get(:isolation_smoke_domains), [], fn {scope, candidate}, errors ->
        try do
          domain = Hosting.get_domain_by_name(scope, candidate.name)

          result =
            if domain,
              do: Hosting.delete_domain(scope, domain, purge_files: true),
              else: Hostctl.WebServer.remove_domain(candidate, purge_files: true)

          case result do
            {:ok, _} -> errors
            :ok -> errors
            _ -> ["Could not clean #{candidate.name}" | errors]
          end
        rescue
          _ -> ["Could not clean #{candidate.name}" | errors]
        end
      end)

    Enum.reduce(Process.get(:isolation_smoke_owners), errors, fn user, errors ->
      # Preserve the panel owner if domain cleanup needs operator attention.
      if Hosting.list_domains(Scope.for_user(user)) == [] do
        case Accounts.delete_user(user) do
          {:ok, _} -> errors
          _ -> ["Could not remove test user #{user.id}" | errors]
        end
      else
        ["Test user #{user.id} retained for cleanup" | errors]
      end
    end)
  end
end

Hostctl.IsolationSmoke.run()
