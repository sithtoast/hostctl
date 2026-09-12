defmodule Hostctl.FtpIsolationSmoke do
  alias Hostctl.{Accounts, Hosting, Repo, FtpServer}
  alias Hostctl.Accounts.Scope
  alias Hostctl.Isolation.Runtime
  alias Hostctl.Hosting.FtpAccount

  def run(mode, directory) do
    path = Path.join(directory, "state.json")

    try do
      case mode do
        :prepare ->
          prepare(path, directory)

        :retry ->
          state = read(path)
          if state["prepared"], do: raise("Preparation already passed; reboot and verify instead")
          verify_records(state)
          probe(path, directory, "prepare")
          save(path, Map.put(state, "prepared", true))
          IO.puts("PASS: FTP preparation retry passed. Reboot, then run verify.")

        :verify ->
          state = read(path)

          unless state["prepared"],
            do: raise("Preparation did not finish; run cleanup before trying again")

          unless state["boot_id"] != boot_id(),
            do: raise("The server has not rebooted yet; fixtures are retained")

          IO.puts("PASS: server boot ID changed")
          verify_records(state)
          probe(path, directory, "verify")
          cleanup(path)
          IO.puts("PASS: FTP isolation and reboot persistence; test sites and FTP logins removed")

        :cleanup ->
          cleanup(path)
      end

      :ok
    rescue
      error ->
        detail =
          if match?(%RuntimeError{}, error),
            do: Exception.message(error),
            else: "Fixture operation failed"

        IO.puts("FAIL: " <> detail)

        IO.puts(
          "FAIL: FTP check could not finish. Private state and test fixtures retained at #{path}; run cleanup to remove them."
        )

        {:error, :ftp_check_failed}
    end
  end

  defp prepare(path, directory) do
    if File.exists?(path), do: raise("A previous test exists; verify or clean it up first")

    unless Application.get_env(:hostctl, :ftp_server, [])[:enabled],
      do: raise("FTP integration is disabled")

    tag = "hc-ftp-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

    state = %{
      "tag" => tag,
      "boot_id" => boot_id(),
      "prepared" => false,
      "token" => Base.encode16(:crypto.strong_rand_bytes(24)),
      "owners" =>
        Enum.map(["a", "b"], fn side ->
          label = tag <> "-" <> side

          %{
            "domain" => label <> ".test",
            "email" => label <> "@example.invalid",
            "login" => String.replace(label, "-", "_"),
            "password" => Base.encode64(:crypto.strong_rand_bytes(30))
          }
        end)
    }

    {:ok, file} = File.open(path, [:write, :exclusive])
    File.close(file)
    File.chmod!(path, 0o600)
    save(path, state)

    for attrs <- state["owners"] do
      IO.puts("Preparing test owner for " <> attrs["domain"])

      {:ok, user} =
        Accounts.create_panel_user(%{
          name: "FTP isolation " <> attrs["domain"],
          email: attrs["email"]
        })

      scope = Scope.for_user(user)
      {:ok, identity} = Runtime.prepare_import_owner(scope)
      IO.puts("PASS: test owner enrolled as " <> identity.username)

      {:ok, domain} =
        Hosting.create_domain(scope, %{
          name: attrs["domain"],
          apply_dns_template: false,
          ssl_enabled: false
        })

      IO.puts("Provisioning FTP login for " <> attrs["domain"])

      {:ok, _ftp} =
        Hosting.create_ftp_account(domain, %{
          username: attrs["login"],
          password: attrs["password"],
          home_dir: domain.document_root,
          mounts: []
        })

      updated =
        Map.merge(attrs, %{
          "user_id" => user.id,
          "uid" => identity.uid,
          "gid" => identity.gid,
          "username" => identity.username,
          "root" => domain.document_root,
          "php_version" => domain.php_version,
          "domain_id" => domain.id
        })

      current = read(path)

      save(path, %{
        current
        | "owners" =>
            Enum.map(current["owners"], &if(&1["login"] == attrs["login"], do: updated, else: &1))
      })
    end

    state = read(path)
    [a, b] = state["owners"]
    unless a["uid"] != b["uid"], do: raise("Owners share a Linux UID")

    for {owner, peer} <- [{a, b}, {b, a}] do
      config = Base.encode64(Jason.encode!(%{token: state["token"], root: owner["root"]}))

      php = """
      <?php
      $c=json_decode(base64_decode('#{config}'),true);
      if (($_SERVER['HTTP_X_HOSTCTL_TEST']??'')!==$c['token'] || !in_array($_SERVER['REMOTE_ADDR'],['127.0.0.1','::1'],true)) {http_response_code(404);exit;}
      header('Content-Type: application/json');
      echo json_encode(['uid'=>posix_geteuid(),'proof'=>file_get_contents($c['root'].'/boot-proof.txt')]);
      """

      code =
        "import os,sys,base64; fd=os.open(sys.argv[1],os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o640); os.write(fd,base64.b64decode(sys.argv[2])); os.close(fd); os.symlink(sys.argv[3],sys.argv[4])"

      command([
        "--uid=" <> owner["username"],
        "--gid=" <> owner["username"],
        "/usr/bin/python3",
        "-c",
        code,
        owner["root"] <> "/ftp-probe.php",
        Base.encode64(php),
        peer["root"] <> "/boot-proof.txt",
        owner["root"] <> "/peer-link.txt"
      ])
    end

    verify_records(state)
    probe(path, directory, "prepare")
    save(path, Map.put(state, "prepared", true))
    IO.puts("PASS: FTP checks passed. Fixtures retained for reboot verification.")
    IO.puts("Next: reboot the server, then run this wrapper with verify. Use cleanup to cancel.")
  end

  defp verify_records(state) do
    Enum.each(state["owners"], fn owner ->
      user = Accounts.get_user_by_email(owner["email"])
      domain = Hosting.get_domain_by_name(Scope.for_user(user), owner["domain"])
      {:ok, identity} = Runtime.identity(user.id)

      unless user.id == owner["user_id"] and domain.id == owner["domain_id"] and
               identity.uid == owner["uid"] and identity.gid == owner["gid"] and
               domain.php_version == owner["php_version"],
             do: raise("Fixture identity changed")
    end)

    IO.puts("PASS: retained panel owners, domains, PHP versions and numeric identities")
  end

  defp probe(path, directory, phase) do
    case System.cmd("python3", [Path.join(directory, "probe.py"), path, phase],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        IO.write(output)

      {output, _} ->
        IO.write(output)
        raise("FTP protocol checks failed")
    end
  end

  defp cleanup(path) do
    state = read(path)

    Enum.each(state["owners"], fn owner ->
      if user = Accounts.get_user_by_email(owner["email"]) do
        scope = Scope.for_user(user)
        ftp = Repo.get_by(FtpAccount, username: owner["login"])

        if ftp do
          unless ftp.user_id == user.id, do: raise("FTP owner mismatch; cleanup stopped")
          :ok = FtpServer.remove_account(ftp)
          {:ok, _} = Repo.delete(ftp)
        else
          # Also remove a partial OS login if DB creation rolled back.
          :ok = FtpServer.remove_account(%FtpAccount{username: owner["login"], user_id: user.id})
        end

        if domain = Hosting.get_domain_by_name(scope, owner["domain"]) do
          {:ok, _} = Hosting.delete_domain(scope, domain, purge_files: true)
        else
          candidate = %Hostctl.Hosting.Domain{
            id: -1,
            name: owner["domain"],
            user_id: user.id,
            document_root: "/var/www/#{owner["domain"]}/httpdocs"
          }

          :ok = Hostctl.WebServer.remove_domain(candidate, purge_files: true)
        end

        unless Hosting.list_domains(scope) == [] and
                 is_nil(Repo.get_by(FtpAccount, user_id: user.id)),
               do: raise("Owner has unexpected hosting resources; retained")

        {:ok, _} = Accounts.delete_user(user)
      end
    end)

    File.rm!(path)

    IO.puts(
      "PASS: test sites, files, FTP credentials and panel users cleaned up. Linux identities and pools remain reserved."
    )
  end

  defp read(path) do
    state = path |> File.read!() |> Jason.decode!()

    unless Regex.match?(~r/\Ahc-ftp-[0-9a-f]{12}\z/, state["tag"] || ""),
      do: raise("Invalid state")

    unless length(state["owners"]) == 2, do: raise("Invalid owners")

    Enum.zip(state["owners"], ["a", "b"])
    |> Enum.each(fn {owner, side} ->
      label = state["tag"] <> "-" <> side

      unless owner["domain"] == label <> ".test" and owner["email"] == label <> "@example.invalid" and
               owner["login"] == String.replace(label, "-", "_"),
             do: raise("Invalid fixture names")
    end)

    state
  end

  defp save(path, state) do
    temporary = path <> "." <> Base.encode16(:crypto.strong_rand_bytes(8))
    {:ok, file} = File.open(temporary, [:write, :exclusive])

    try do
      File.chmod!(temporary, 0o600)
      IO.binwrite(file, Jason.encode!(state))
      :ok = :file.sync(file)
      :ok = File.rename(temporary, path)
    after
      File.close(file)
      File.rm(temporary)
    end
  end

  defp boot_id, do: File.read!("/proc/sys/kernel/random/boot_id") |> String.trim()

  defp command(args) do
    case System.cmd(
           "sudo",
           ["-n", "systemd-run", "--pipe", "--wait", "--collect", "--quiet" | args],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      _ -> raise("Fixture file creation failed")
    end
  end
end

Hostctl.FtpIsolationSmoke.run(
  Keyword.fetch!(binding(), :mode),
  Keyword.fetch!(binding(), :directory)
)
