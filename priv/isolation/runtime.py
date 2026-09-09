#!/usr/bin/env python3
"""Root-side Hostctl isolation operations. No recursive ownership conversion.

Input: one operation and a base64 JSON document. Output: one JSON result.
Only new, explicitly enrolled accounts and canonical domain paths are supported.
State is root-owned; a recorded random marker prevents adopting unrelated users.
"""
import base64
import fcntl
import grp
import json
import os
import pwd
import re
import secrets
import shutil
import stat
import subprocess
import sys
import tempfile

STATE = "/var/lib/hostctl-isolation"
HOMES = "/var/lib/hostctl-accounts"
WEB = "hostctl-web"
VERSIONS = {"7.4", "8.0", "8.1", "8.2", "8.3", "8.4"}
DIRECTORY = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(args, **options):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **options)
    require(result.returncode == 0, "command failed: " + args[0])
    return result.stdout.decode().strip()


def atomic(path, content, mode=0o600):
    directory = os.path.dirname(path)
    fd, temporary = tempfile.mkstemp(prefix=".hostctl-", dir=directory)
    try:
        with os.fdopen(fd, "w") as output:
            os.fchmod(output.fileno(), mode)
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def trusted_directory(path, mode=0o700):
    # Walk with no-follow directory descriptors, including every ancestor.
    fd = os.open("/", DIRECTORY)
    try:
        for component in path.strip("/").split("/"):
            try:
                os.mkdir(component, mode, dir_fd=fd)
            except FileExistsError:
                pass
            new_fd = os.open(component, DIRECTORY, dir_fd=fd)
            os.close(fd)
            fd = new_fd
            info = os.fstat(fd)
            require(info.st_uid == 0, "untrusted directory owner")
        require(os.fstat(fd).st_mode & 0o022 == 0, "writable state directory")
    finally:
        os.close(fd)


def load(name):
    path = f"{STATE}/{name}.json"
    if not os.path.exists(path):
        return None
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd) as source:
        info = os.fstat(source.fileno())
        require(info.st_uid == 0 and info.st_mode & 0o077 == 0, "untrusted identity record")
        return json.load(source)


def save(name, record):
    atomic(f"{STATE}/{name}.json", json.dumps(record))


def lookup(name):
    try:
        return pwd.getpwnam(name)
    except KeyError:
        return None


def verify(name, record, gateway=False):
    require(record is not None, "identity is not enrolled")
    user = lookup(name)
    require(user is not None, "recorded Linux user is missing")
    require(user.pw_uid > 0 and user.pw_gid > 0, "root identity forbidden")
    require(user.pw_gecos == record["marker"], "Linux identity collision")
    require(user.pw_dir == record["home"] and user.pw_shell == "/usr/sbin/nologin", "login policy changed")
    require(grp.getgrgid(user.pw_gid).gr_name == name, "private group changed")
    allowed = {user.pw_gid}
    if gateway:
        allowed.add(grp.getgrnam("www-data").gr_gid)
    require(set(os.getgrouplist(name, user.pw_gid)) <= allowed, "unexpected supplementary group")
    password = run(["getent", "shadow", name]).split(":")[1]
    require(password.startswith(("!", "*")), "password login is not locked")
    if "uid" in record:
        require((user.pw_uid, user.pw_gid) == (record["uid"], record["gid"]), "numeric identity changed")
    return user


def enroll(name, gateway=False):
    record = load(name)
    if record is None:
        require(lookup(name) is None, "Linux username already exists")
        try:
            grp.getgrnam(name)
        except KeyError:
            pass
        else:
            raise ValueError("Linux group already exists")
        record = {"marker": "hostctl-" + secrets.token_hex(24), "home": f"{HOMES}/{name}", "domains": []}
        save(name, record)
    if lookup(name) is None:
        # useradd selects a free UID. Retained users are never automatically deleted.
        run(["useradd", "--system", "--user-group", "--no-create-home", "--home-dir", record["home"],
             "--shell", "/usr/sbin/nologin", "--comment", record["marker"], "--password", "!", name])
    user = verify(name, record, gateway)
    record.update(uid=user.pw_uid, gid=user.pw_gid)
    save(name, record)
    return record


def gateway(reload_services):
    record = enroll(WEB, gateway=True)
    run(["usermod", "--append", "--groups", "www-data", WEB])
    path = "/etc/nginx/nginx.conf"
    with open(path) as source:
        original = source.read()
    users = re.findall(r"(?m)^\s*user\s+([^;]+);", original)
    require(len(users) == 1 and users[0].strip() in ("www-data", WEB), "unsupported Nginx worker identity")
    updated = re.sub(r"(?m)^\s*user\s+[^;]+;", f"user {WEB};", original)
    expanded = run(["nginx", "-T"])
    require(not re.search(r"(?m)^\s*disable_symlinks\s+off\s*;", expanded), "Nginx symlink policy override requires review")
    policy = "# Hostctl account boundary policy"
    if policy not in updated:
        if not os.path.exists(f"{STATE}/nginx-before-isolation.conf"):
            atomic(f"{STATE}/nginx-before-isolation.conf", original)
        require(len(re.findall(r"(?m)^\s*http\s*\{", updated)) == 1, "unsupported Nginx http configuration")
        updated = re.sub(r"(?m)^(\s*http\s*\{)", r"\1\n    " + policy + "\n    disable_symlinks if_not_owner;", updated)
    atomic(path, updated, 0o644)
    try:
        run(["nginx", "-t"])
        if reload_services:
            run(["systemctl", "reload", "nginx"])
    except Exception:
        atomic(path, original, 0o644)
        raise
    return record


def identity(data):
    owner = data["owner_id"]
    require(type(owner) is int and 0 < owner <= 9223372036854775807, "invalid owner")
    name = f"hc_{owner}"
    require(data.get("username", name) == name, "owner/name mismatch")
    return name


def checked_identity(data):
    name = identity(data)
    record = load(name)
    user = verify(name, record)
    require((data["uid"], data["gid"]) == (user.pw_uid, user.pw_gid), "database identity mismatch")
    verify(WEB, load(WEB), gateway=True)
    with open("/etc/nginx/nginx.conf") as source:
        nginx_config = source.read()
    require(re.search(r"(?m)^\s*user\s+hostctl-web\s*;", nginx_config) is not None and
            "# Hostctl account boundary policy" in nginx_config, "Nginx isolation policy changed")
    return name, record, user


def acl(fd, spec):
    run(["setfacl", "-m", spec, f"/proc/self/fd/{fd}"], pass_fds=(fd,))


def webroot(data):
    name, record, user = checked_identity(data)
    domain = data["domain"]
    require(re.fullmatch(r"[a-z0-9][a-z0-9.-]*\.[a-z]{2,}", domain) is not None, "invalid domain")
    root = f"/var/www/{domain}"
    path = data["path"]
    require(isinstance(path, str) and path.startswith(root + "/"), "noncanonical webroot")
    parts = path[len(root) + 1:].split("/")
    require(all(re.fullmatch(r"[A-Za-z0-9_.-]+", part) and part not in (".", "..") for part in parts), "invalid path")
    require(shutil.which("setfacl") is not None, "install the acl package")
    parent = os.open("/var/www", DIRECTORY)
    try:
        if domain not in record["domains"]:
            require(not os.path.lexists(root), "existing webroot requires migration")
            # Persist the claim before creating anything, allowing crash recovery.
            record["domains"].append(domain)
            save(name, record)
        try:
            os.mkdir(domain, 0o750, dir_fd=parent)
        except FileExistsError:
            pass
        fd = os.open(domain, DIRECTORY, dir_fd=parent)
    finally:
        os.close(parent)
    try:
        info = os.fstat(fd)
        require(info.st_uid == 0 and info.st_gid in (0, user.pw_gid), "untrusted domain boundary")
        os.fchown(fd, 0, user.pw_gid)
        os.fchmod(fd, 0o750)
        acl(fd, f"u:{WEB}:--x,u:hostctl:r-x")
        # The domain boundary is root-owned and cannot be renamed by the tenant.
        marker = os.open(".hostctl-owner", os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600, dir_fd=fd)
        try:
            require(os.fstat(marker).st_uid == 0, "untrusted ownership marker")
            os.ftruncate(marker, 0)
            os.write(marker, name.encode())
        finally:
            os.close(marker)
        for component in parts:
            created = False
            try:
                os.mkdir(component, 0o750, dir_fd=fd)
                created = True
            except FileExistsError:
                pass
            next_fd = os.open(component, DIRECTORY, dir_fd=fd)
            os.close(fd)
            fd = next_fd
            if created:
                os.fchown(fd, user.pw_uid, user.pw_gid)
                acl(fd, f"u:{WEB}:r-x,u:hostctl:rwx,d:u::rwx,d:u:{WEB}:r-x,d:u:hostctl:rwx,d:g::---,d:m::rwx,d:o::---")
            else:
                require(os.fstat(fd).st_uid == user.pw_uid, "webroot ownership changed")
        if data.get("index", True) and "index.php" not in os.listdir(fd) and "index.html" not in os.listdir(fd):
            try:
                index = os.open("index.html", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o640, dir_fd=fd)
            except FileExistsError:
                pass
            else:
                try:
                    os.fchown(index, user.pw_uid, user.pw_gid)
                    os.write(index, b"<!doctype html><html lang=en><meta charset=utf-8><title>Website ready</title><h1>Website ready</h1><p>Upload your website to this directory.</p></html>\n")
                finally:
                    os.close(index)
    finally:
        os.close(fd)
    return {"path": path}


def ftp_home(data):
    name, record, user = checked_identity(data)
    domain = data["domain"]
    root = f"/var/www/{domain}"
    if data["path"] != root:
        return webroot(dict(data, index=False))
    require(domain in record["domains"], "FTP domain has not been provisioned")
    fd = os.open(root, DIRECTORY)
    try:
        info = os.fstat(fd)
        require((info.st_uid, info.st_gid) == (0, user.pw_gid), "FTP boundary ownership changed")
        marker = os.open(".hostctl-owner", os.O_RDONLY | os.O_NOFOLLOW, dir_fd=fd)
        try:
            require(os.read(marker, 64).decode() == name, "FTP boundary identity changed")
        finally:
            os.close(marker)
    finally:
        os.close(fd)
    return {"path": root}


def php(data):
    name, record, user = checked_identity(data)
    version = data["version"]
    require(version in VERSIONS, "unsupported PHP version")
    executable = shutil.which(f"php-fpm{version}")
    require(executable is not None, "requested PHP-FPM is not installed")
    trusted_directory(HOMES, 0o711)
    trusted_directory(record["home"], 0o711)
    home_fd = os.open(record["home"], DIRECTORY)
    try:
        for part in ("tmp", "sessions"):
            try:
                os.mkdir(part, 0o700, dir_fd=home_fd)
            except FileExistsError:
                pass
            fd = os.open(part, DIRECTORY, dir_fd=home_fd)
            try:
                require(os.fstat(fd).st_uid in (0, user.pw_uid), "private directory ownership changed")
                os.fchown(fd, user.pw_uid, user.pw_gid)
                os.fchmod(fd, 0o700)
            finally:
                os.close(fd)
    finally:
        os.close(home_fd)
    socket = f"/run/php/hostctl-{name}-{version}.sock"
    content = f"""; Managed by Hostctl isolation
[{name}]
user = {name}
group = {name}
listen = {socket}
listen.owner = {WEB}
listen.group = {WEB}
listen.mode = 0600
pm = ondemand
pm.max_children = 5
pm.process_idle_timeout = 10s
pm.max_requests = 500
clear_env = yes
chdir = {record['home']}
env[TMPDIR] = {record['home']}/tmp
php_admin_value[upload_tmp_dir] = {record['home']}/tmp
php_admin_value[sys_temp_dir] = {record['home']}/tmp
php_admin_value[session.save_path] = {record['home']}/sessions
security.limit_extensions = .php
"""
    path = f"/etc/php/{version}/fpm/pool.d/hostctl-{name}.conf"
    previous = None
    if os.path.exists(path):
        with open(path) as source:
            previous = source.read()
        require(previous.startswith("; Managed by Hostctl isolation\n"), "unmanaged PHP pool collision")
    atomic(path, content, 0o644)
    try:
        run([executable, "-t"])
        if data.get("reload", True):
            run(["systemctl", "reload", f"php{version}-fpm"])
    except Exception:
        if previous is None:
            os.unlink(path)
        else:
            atomic(path, previous, 0o644)
        raise
    return {"socket": socket}


def legacy_chown(data):
    """Maintain legacy ownership without traversing links or isolated boundaries."""
    path = data["path"]
    require(isinstance(path, str) and path.startswith("/var/www/"), "unsupported legacy root")
    parts = path[len("/var/www/"):].split("/")
    require(all(re.fullmatch(r"[A-Za-z0-9_.-]+", part) and part not in (".", "..") for part in parts), "invalid legacy path")
    legacy = pwd.getpwnam("www-data")
    allowed = {0, legacy.pw_uid, pwd.getpwnam("hostctl").pw_uid}

    def check(fd):
        require(os.fstat(fd).st_uid in allowed, "foreign file owner")
        require(".hostctl-owner" not in os.listdir(fd), "isolated domain boundary")

    def walk(fd):
        info = os.fstat(fd)
        require(info.st_uid in allowed, "foreign file owner")
        if stat.S_ISDIR(info.st_mode):
            check(fd)
            for entry in os.listdir(fd):
                child = os.open(entry, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
                try:
                    require(os.fstat(child).st_dev == info.st_dev, "mounted directory requires review")
                    walk(child)
                finally:
                    os.close(child)
        else:
            require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1, "linked or special file requires review")
        os.fchown(fd, legacy.pw_uid, legacy.pw_gid)

    fd = os.open("/var/www", DIRECTORY)
    try:
        for part in parts:
            check(fd)
            try:
                os.mkdir(part, 0o755, dir_fd=fd)
            except FileExistsError:
                pass
            child = os.open(part, DIRECTORY, dir_fd=fd)
            os.close(fd)
            fd = child
        walk(fd)
    finally:
        os.close(fd)
    return {"path": path}


def open_directory(path):
    require(path.startswith("/") and all(p not in ("", ".", "..") for p in path.split("/")[1:]), "invalid directory")
    fd = os.open("/", DIRECTORY)
    try:
        for part in path.split("/")[1:]:
            child = os.open(part, DIRECTORY, dir_fd=fd)
            os.close(fd)
            fd = child
        return fd
    except BaseException:
        os.close(fd)
        raise


def import_tree(data):
    _, _, user = checked_identity(data)
    webroot(dict(data, index=False))
    source = data["source"]
    require(re.fullmatch(r"/(?:tmp|var/tmp)/hostctl-import-[A-Za-z0-9_-]+", source), "invalid staging directory")
    src = open_directory(source)
    dst = open_directory(data["path"])
    try:
        copy_import_directory(src, dst, user)
    finally:
        os.close(src)
        os.close(dst)
    return {"path": data["path"]}


def copy_import_directory(src, dst, user):
    require(os.fstat(dst).st_uid == user.pw_uid, "destination ownership changed")
    for name in os.listdir(src):
        info = os.stat(name, dir_fd=src, follow_symlinks=False)
        if stat.S_ISDIR(info.st_mode):
            child_src = os.open(name, DIRECTORY, dir_fd=src)
            try:
                try:
                    os.mkdir(name, 0o750, dir_fd=dst)
                    created = True
                except FileExistsError:
                    created = False
                child_dst = os.open(name, DIRECTORY, dir_fd=dst)
                try:
                    if created:
                        os.fchown(child_dst, user.pw_uid, user.pw_gid)
                        acl(child_dst, f"u:{WEB}:r-x,u:hostctl:rwx,d:u::rwx,d:u:{WEB}:r-x,d:u:hostctl:rwx,d:g::---,d:m::rwx,d:o::---")
                    copy_import_directory(child_src, child_dst, user)
                finally:
                    os.close(child_dst)
            finally:
                os.close(child_src)
        else:
            require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1, "import contains a link or special file")
            reader = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=src)
            temp = ".hostctl-import-" + secrets.token_hex(16)
            try:
                current = os.fstat(reader)
                require(stat.S_ISREG(current.st_mode) and current.st_nlink == 1, "source changed")
                writer = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o640, dir_fd=dst)
                try:
                    os.fchown(writer, user.pw_uid, user.pw_gid)
                    acl(writer, f"u:{WEB}:r--,u:hostctl:rw-,m::rw-,o::---")
                    with os.fdopen(os.dup(reader), "rb") as source_file, os.fdopen(os.dup(writer), "wb") as target_file:
                        shutil.copyfileobj(source_file, target_file)
                finally:
                    os.close(writer)
                # Replaces the directory entry, never follows an existing link.
                os.rename(temp, name, src_dir_fd=dst, dst_dir_fd=dst)
            finally:
                os.close(reader)
                try:
                    os.unlink(temp, dir_fd=dst)
                except FileNotFoundError:
                    pass


def main(operation, data):
    require(os.geteuid() == 0 and sys.platform == "linux", "Linux root privileges required")
    trusted_directory(STATE)
    lock = os.open(f"{STATE}/lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if operation == "enroll":
            require(shutil.which("setfacl") is not None, "install the acl package")
            name = identity(data)
            record = enroll(name)
            gateway(data.get("reload", True))
            return {"username": name, "uid": record["uid"], "gid": record["gid"]}
        if operation == "verify":
            name, _, user = checked_identity(data)
            return {"username": name, "uid": user.pw_uid, "gid": user.pw_gid}
        if operation == "webroot":
            return webroot(data)
        if operation == "ftp-home":
            return ftp_home(data)
        if operation == "php":
            return php(data)
        if operation == "import-tree":
            return import_tree(data)
        if operation == "legacy-chown":
            return legacy_chown(data)
        raise ValueError("unknown operation")
    finally:
        os.close(lock)


if __name__ == "__main__":
    try:
        require(len(sys.argv) == 3, "operation and payload required")
        payload = json.loads(base64.b64decode(sys.argv[2], validate=True))
        print(json.dumps({"ok": main(sys.argv[1], payload)}))
    except Exception as error:
        print(json.dumps({"error": str(error)}))
        sys.exit(1)
