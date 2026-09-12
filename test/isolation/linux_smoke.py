"""Destructive fixture setup, restricted to a disposable Docker container."""
import base64
import ftplib
import io
import json
import os
from pathlib import Path
import pwd
import socket
import subprocess
import time
import urllib.request
import urllib.error

assert Path("/.dockerenv").exists(), "Run only in the disposable isolation test container"
assert os.geteuid() == 0


def run(*args, **kwargs):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs).stdout.decode().strip()


def helper(action, data, success=True):
    encoded = base64.b64encode(json.dumps(data).encode()).decode()
    result = subprocess.run(["python3", "/runtime.py", action, encoded], capture_output=True, text=True)
    value = json.loads(result.stdout)
    if success:
        assert result.returncode == 0, value
        return value["ok"]
    assert result.returncode != 0, value
    return value


def wait_for(check):
    end = time.monotonic() + 10
    last_error = None
    while time.monotonic() < end:
        try:
            return check()
        except (OSError, ConnectionError, ftplib.Error) as error:
            last_error = error
            time.sleep(0.05)
    raise AssertionError(f"service did not become ready: {last_error}")


def get(host, path):
    request = urllib.request.Request("http://127.0.0.1:8080" + path, headers={"Host": host})
    return urllib.request.urlopen(request, timeout=3).read().decode()


run("useradd", "--system", "--user-group", "--shell", "/usr/sbin/nologin", "hostctl")
Path("/run/php").mkdir(exist_ok=True)
identities = []
for owner, domain in [(10001, "isolation-a.test"), (10002, "isolation-b.test")]:
    record = helper("enroll", {"owner_id": owner, "reload": False})
    payload = dict(record, owner_id=owner)
    assert helper("enroll", {"owner_id": owner, "reload": False}) == record
    helper("verify", payload)
    root = f"/var/www/{domain}/httpdocs"
    helper("webroot", dict(payload, domain=domain, path=root))
    helper("php", dict(payload, version="8.3", reload=False))
    helper("ftp-home", dict(payload, domain=domain, path=f"/var/www/{domain}"))
    helper("ftp-home", dict(payload, domain=domain, path=f"/var/www/{domain}/uploads"))
    assert os.stat(f"/var/www/{domain}/uploads").st_uid == payload["uid"]
    assert not Path(f"/var/www/{domain}/uploads/index.html").exists()
    helper("webroot", dict(payload, domain=domain, path=root))
    run("runuser", "-u", record["username"], "--", "sh", "-c",
        'printf "%s" "account-file" > "$1/read.txt"', "--", root)
    Path(root + "/identity.php").write_text("<?php echo posix_geteuid();")
    identities.append((payload, domain, root))

a, b = identities
for source, target in [(a, b), (b, a)]:
    for permission in ["-r", "-w"]:
        result = subprocess.run(["runuser", "-u", source[0]["username"], "--", "test", permission, target[2] + "/read.txt"])
        assert result.returncode != 0, "cross-account file access succeeded"

# Legacy PHP is www-data; it must not inherit the dedicated web reader's access.
assert subprocess.run(["runuser", "-u", "www-data", "--", "test", "-r", a[2] + "/read.txt"]).returncode != 0
run("runuser", "-u", a[0]["username"], "--", "ln", "-s", b[2] + "/read.txt", a[2] + "/leak.txt")
Path(a[2] + "/denial.php").write_text("<?php echo @file_get_contents('" + b[2] + "/read.txt') === false ? 'denied' : 'LEAK';")
Path(a[2] + "/sessions.php").write_text("<?php session_start(); $_SESSION['test'] = 1; echo session_save_path();")
for payload, _, root in identities:
    for path in Path(root).glob("*.php"):
        os.chown(path, payload["uid"], payload["gid"])

config = []
for payload, domain, root in identities:
    config.append(f"""server {{
listen 8080;
server_name {domain};
root {root};
disable_symlinks on;
location / {{ try_files $uri =404; }}
location ~ \\.php$ {{
try_files $uri =404;
include fastcgi_params;
fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
fastcgi_pass unix:/run/php/hostctl-{payload['username']}-8.3.sock;
}}
}}""")
Path("/var/www/html/legacy.php").write_text("<?php echo @file_get_contents('" + a[2] + "/read.txt') === false ? 'legacy-denied' : 'LEAK';")
run("ln", "-s", a[2] + "/read.txt", "/var/www/html/legacy-leak.txt")
os.lchown("/var/www/html/legacy-leak.txt", pwd.getpwnam("www-data").pw_uid, pwd.getpwnam("www-data").pw_gid)
config.append(r"""server {
listen 8080; server_name legacy.test; root /var/www/html;
location / { try_files $uri =404; }
location ~ \.php$ {
include fastcgi_params;
fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
fastcgi_pass unix:/run/php/php8.3-fpm.sock;
}
}""")
Path("/etc/nginx/conf.d/isolation.conf").write_text("\n".join(config))
run("nginx", "-t")

# Exercise the exact per-login guest identity settings supported by vsftpd.
Path("/etc/vsftpd-test-users").mkdir()
password = "FixturePassword123!"
password_hash = run("openssl", "passwd", "-6", "-stdin", input=password.encode())
entries = []
for payload, domain, root in identities:
    login = "ftp" + str(payload["owner_id"])
    entries.extend([login, password_hash])
    Path("/etc/vsftpd-test-users/" + login).write_text(f"""local_root=/var/www/{domain}
write_enable=YES
virtual_use_local_privs=YES
guest_username={payload['username']}
local_umask=027
file_open_mode=0660
chmod_enable=NO
""")
Path("/etc/vsftpd-test.txt").write_text("\n".join(entries) + "\n")
run("db_load", "-T", "-t", "hash", "-f", "/etc/vsftpd-test.txt", "/etc/vsftpd-test.db")
Path("/etc/pam.d/hostctl-isolation-test").write_text("auth required pam_userdb.so db=/etc/vsftpd-test crypt=crypt\naccount required pam_userdb.so db=/etc/vsftpd-test\n")
Path("/var/run/vsftpd/empty").mkdir(parents=True, exist_ok=True)
Path("/etc/vsftpd-isolation-test.conf").write_text("""listen=YES
listen_ipv6=NO
listen_address=127.0.0.1
listen_port=2121
anonymous_enable=NO
local_enable=YES
write_enable=YES
guest_enable=YES
guest_username=www-data
user_config_dir=/etc/vsftpd-test-users
pam_service_name=hostctl-isolation-test
chroot_local_user=YES
allow_writeable_chroot=YES
secure_chroot_dir=/var/run/vsftpd/empty
seccomp_sandbox=NO
""")

processes = [subprocess.Popen(["php-fpm8.3", "--nodaemonize"], stdout=subprocess.DEVNULL),
             subprocess.Popen(["nginx", "-g", "daemon off;"], stdout=subprocess.DEVNULL),
             subprocess.Popen(["vsftpd", "/etc/vsftpd-isolation-test.conf"], stdout=subprocess.DEVNULL)]
try:
    for payload, domain, root in identities:
        assert wait_for(lambda: get(domain, "/identity.php")) == str(payload["uid"])
        assert get(domain, "/read.txt") == "account-file"
        ftp = ftplib.FTP()
        wait_for(lambda: ftp.connect("127.0.0.1", 2121, timeout=3))
        ftp.login("ftp" + str(payload["owner_id"]), password)
        ftp.cwd("httpdocs")
        ftp.storbinary("STOR uploaded.txt", io.BytesIO(b"ftp-upload"))
        ftp.rename("uploaded.txt", "renamed.txt")
        assert os.stat(root + "/renamed.txt").st_uid == payload["uid"]
        assert get(domain, "/renamed.txt") == "ftp-upload"
        ftp.delete("renamed.txt")
        ftp.quit()
    assert get(a[1], "/denial.php") == "denied"
    assert get("legacy.test", "/legacy.php") == "legacy-denied"
    try:
        get("legacy.test", "/legacy-leak.txt")
        raise AssertionError("legacy Nginx vhost served an isolated account symlink")
    except urllib.error.HTTPError as error:
        assert error.code in (403, 404)
    assert get(a[1], "/sessions.php") == f"/var/lib/hostctl-accounts/{a[0]['username']}/sessions"
    try:
        get(a[1], "/leak.txt")
        raise AssertionError("Nginx served a cross-account symlink")
    except urllib.error.HTTPError as error:
        assert error.code in (403, 404)
    for payload, _, _ in identities:
        private_socket = f"/run/php/hostctl-{payload['username']}-8.3.sock"
        assert subprocess.run(["runuser", "-u", "www-data", "--", "test", "-w", private_socket]).returncode != 0
    # Imported files inherit the tenant identity and remain readable by Nginx.
    stage = Path("/tmp/hostctl-import-smoke")
    stage.mkdir(mode=0o700)
    (stage / "assets").mkdir()
    (stage / "assets" / "imported.txt").write_text("isolated-import")
    destination = dict(a[0], domain=a[1], path=a[2], source=str(stage))
    helper("import-tree", destination)
    imported = a[2] + "/assets/imported.txt"
    assert os.stat(imported).st_uid == a[0]["uid"]
    assert get(a[1], "/assets/imported.txt") == "isolated-import"
    for forbidden in [b[0]["username"], "www-data"]:
        assert subprocess.run(["runuser", "-u", forbidden, "--", "cat", imported], capture_output=True).returncode != 0
    # Reimports replace files without following destination links.
    os.unlink(imported)
    os.symlink("/etc/passwd", imported)
    helper("import-tree", destination)
    assert not os.path.islink(imported)
    assert Path(imported).read_text() == "isolated-import"
    (stage / "source-link").symlink_to("/etc/passwd")
    helper("import-tree", destination, success=False)
    (stage / "source-link").unlink()
    helper("import-tree", dict(destination, **b[0]), success=False)
    print("PASS: isolated import ownership, Nginx reads, cross-account denial, reimport, source-link rejection")
    # Exercise the same FTP protocol probe shipped for live-server checks.
    import importlib.util
    spec = importlib.util.spec_from_file_location("ftp_probe", "/ftp-isolation-probe.py")
    ftp_probe = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ftp_probe)
    ftp_probe.FTP_PORT = 2121
    ftp_probe.HTTP_PORT = 8080
    probe_state = {"tag": "fixture", "token": "fixture-token", "owners": []}
    for payload, domain, root in identities:
        login = "ftp" + str(payload["owner_id"])
        conf = Path("/etc/vsftpd-test-users/" + login)
        conf.write_text(conf.read_text().replace("local_root=/var/www/" + domain, "local_root=" + root))
        probe_state["owners"].append({"domain": domain, "root": root, "uid": payload["uid"],
                                      "login": login, "password": password})
        php_probe = Path(root + "/ftp-probe.php")
        php_probe.write_text("<?php echo json_encode(['uid'=>posix_geteuid(),'proof'=>file_get_contents(__DIR__.'/boot-proof.txt')]);")
        os.chown(php_probe, payload["uid"], payload["gid"])
    for source, peer in [(a, b), (b, a)]:
        link = source[2] + "/peer-link.txt"
        os.symlink(peer[2] + "/boot-proof.txt", link)
        os.lchown(link, source[0]["uid"], source[0]["gid"])
    ftp_probe.run(probe_state, "prepare")
    ftp_probe.run(probe_state, "verify")
    # Verification must detect lost persisted content, not recreate it.
    os.unlink(a[2] + "/boot-proof.txt")
    try:
        ftp_probe.run(probe_state, "verify")
        raise AssertionError("verification recreated a missing reboot marker")
    except ftplib.error_perm as error:
        assert str(error).startswith("550")
    print("PASS: live FTP probe preparation, retained-marker verification and missing-marker failure")
    # Invalid or already-owned paths and colliding OS accounts fail closed.
    helper("webroot", dict(a[0], domain=a[1], path=a[2] + "/../escape"), success=False)
    helper("webroot", dict(b[0], domain=a[1], path=a[2]), success=False)
    helper("legacy-chown", {"path": a[2]}, success=False)
    Path("/var/www/legacy-owned").mkdir()
    Path("/var/www/legacy-owned/file.txt").write_text("legacy")
    helper("legacy-chown", {"path": "/var/www/legacy-owned"})
    assert os.stat("/var/www/legacy-owned/file.txt").st_uid == pwd.getpwnam("www-data").pw_uid
    # Fresh legacy provisioning must not rely on hostctl writing www-data directories.
    legacy_root = "/var/www/fresh-legacy.test/httpdocs"
    helper("legacy-chown", {"path": legacy_root, "index": True})
    index = Path(legacy_root) / "index.html"
    assert index.stat().st_uid == pwd.getpwnam("www-data").pw_uid
    assert "Site coming soon" in index.read_text()
    index.write_text("existing website")
    helper("legacy-chown", {"path": legacy_root, "index": True})
    assert index.read_text() == "existing website"
    helper("legacy-chown", {"path": a[2], "index": True}, success=False)
    run("useradd", "--system", "hc_99999")
    helper("enroll", {"owner_id": 99999, "reload": False}, success=False)
    print("PASS: distinct PHP UIDs, FTP upload ownership, static reads, sessions, cross-account and legacy denial, symlink denial, retry safety, collision rejection")
finally:
    for process in processes:
        process.terminate()
    for process in processes:
        process.wait(timeout=5)
