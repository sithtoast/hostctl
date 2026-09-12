#!/usr/bin/env python3
"""Private, atomic GoAccess snapshots. Runs as Hostctl, never as a tenant or root."""
import argparse
import fcntl
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import shutil
import stat
import sqlite3
import subprocess
import tempfile
import time
import uuid

HOST = re.compile(r"(?=.{1,253}\Z)[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\Z")
MAX_FILE = 1024 * 1024 * 1024
MAX_HISTORY = 4 * MAX_FILE


def regular(path):
    path = Path(path)
    for part in [path, *path.parents]:
        if part.is_symlink():
            raise ValueError("Symbolic links are not accepted in statistics paths")
    info = path.stat()
    if not stat.S_ISREG(info.st_mode):
        raise ValueError("Statistics inputs must be regular files")
    return info


def private_dir(path):
    path = Path(path)
    for part in [path, *path.parents]:
        if part.is_symlink():
            raise ValueError("Statistics directory cannot contain symbolic links")
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path, 0o700)
    return path


def read_manifest(base, kind):
    path = base / (kind + ".json")
    if not path.exists():
        return None
    regular(path)
    data = json.loads(path.read_text())
    if not re.fullmatch(r"g-[a-f0-9]{32}", data["generation"]):
        raise ValueError("Invalid statistics generation")
    return data


def run_goaccess(exe, files, work, restore=False, geoip=None):
    db = private_dir(work / "db")
    args = [exe, "--no-global-config", "--config-file=/dev/null", "--log-format=COMBINED", "--no-term-resolver",
            "--no-query-string", "--persist", "--db-path=" + str(db),
            "--output=" + str(work / "report.html"), "--output=" + str(work / "report.json")]
    if restore:
        args.append("--restore")
    if geoip:
        regular(geoip)
        args.append("--geoip-database=" + geoip)
    for path in files:
        args.extend(["--log-file", str(path)])
    # No stdin parsing: it loses newly appended requests sharing the last timestamp.
    def limits():
        resource.setrlimit(resource.RLIMIT_AS, (2 * MAX_FILE, 2 * MAX_FILE))

    with tempfile.TemporaryFile() as errors:
        result = subprocess.run(args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                stderr=errors, timeout=300, preexec_fn=limits, env={**os.environ, "LC_ALL": "C"})
        if result.returncode:
            raise ValueError("GoAccess could not parse these logs; check Combined log format and file permissions")
    report = json.loads((work / "report.json").read_text())
    return report.get("general", {})


def publish(base, kind, work, data):
    data.update(generation=work.name, updated_at=int(time.time()))
    tmp = base / (kind + ".json.tmp")
    tmp.write_text(json.dumps(data))
    os.replace(tmp, base / (kind + ".json"))
    # Keep the previous generation for requests that already read its manifest.
    keep = {m["generation"] for k in ["live", "history"] if (m := read_manifest(base, k))}
    generations = sorted(base.glob("g-*"), key=lambda p: p.stat().st_mtime, reverse=True)
    keep.update(p.name for p in generations[:3])
    for old in generations:
        if old.name not in keep and old.is_dir() and not old.is_symlink():
            shutil.rmtree(old)
    return data


def collect(base, log_root, hosts, exe, geoip):
    prior = read_manifest(base, "live")
    files = []
    for host in hosts:
        if not HOST.fullmatch(host) or ".." in host:
            raise ValueError("Invalid domain log name")
        # Ubuntu's rename/create rotation preserves inodes. Read rotated file first.
        for suffix in [".access.log.1", ".access.log"]:
            path = log_root / (host + suffix)
            if path.exists():
                info = regular(path)
                if info.st_size > MAX_FILE:
                    raise ValueError("Access log exceeds the 1 GiB collection limit")
                if info.st_size:
                    files.append(path)
    if sum(path.stat().st_size for path in files) > MAX_HISTORY:
        raise ValueError("Access logs exceed the 4 GiB collection limit")
    if not files:
        raise ValueError("No readable domain access logs yet. Send a request to the website and retry")
    work = private_dir(base / ("g-" + uuid.uuid4().hex))
    try:
        if prior:
            source = base / prior["generation"] / "db"
            shutil.copytree(source, work / "db")
        summary = run_goaccess(exe, files, work, bool(prior), geoip)
        return publish(base, "live", work, {"summary": summary, "hosts": hosts,
                       "geoip": bool(geoip), "started_at": prior.get("started_at") if prior else int(time.time())})
    except Exception:
        shutil.rmtree(work)
        raise


def check_history_overlap(files, work):
    """Refuse ambiguous cross-file repeats; preserve duplicate requests within a file.

    Use a bounded on-disk index rather than holding request fingerprints in RAM.
    A repeat could be a legitimate request at a rotation boundary or overlapping
    Plesk snapshots; neither can be distinguished safely from Combined logs alone.
    """
    index = work / "overlap.sqlite"
    started, rows = time.monotonic(), 0
    try:
        with sqlite3.connect(index) as db:
            db.execute("PRAGMA journal_mode=OFF")
            db.execute("PRAGMA cache_size=-4096")
            db.execute("CREATE TABLE requests (hash BLOB PRIMARY KEY, file INTEGER) WITHOUT ROWID")
            for number, path in enumerate(files):
                with path.open("rb") as source:
                    while line := source.readline(1024 * 1024 + 1):
                        rows += 1
                        if len(line) > 1024 * 1024 or rows > 2_000_000 or time.monotonic() - started > 300:
                            return "History files were preserved, but overlap checking exceeded its analysis limit. Import a smaller set of logs to rebuild the report."
                        fingerprint = hashlib.sha256(line.rstrip(b"\r\n")).digest()
                        previous = db.execute("SELECT file FROM requests WHERE hash=?", (fingerprint,)).fetchone()
                        if previous and previous[0] != number:
                            return "History files were preserved, but retained logs contain overlapping requests. Import a non-overlapping set to rebuild reliable totals."
                        if not previous:
                            db.execute("INSERT INTO requests VALUES (?, ?)", (fingerprint, number))
        return None
    finally:
        index.unlink(missing_ok=True)


def history(base, source, exe, geoip):
    if source.is_symlink() or not source.is_dir():
        raise ValueError("History source must be an extracted directory")
    work = private_dir(base / ("g-" + uuid.uuid4().hex))
    archived = private_dir(work / "archive")
    raw = private_dir(work / "logs")
    reports, logs, total, seen = [], [], 0, set()
    try:
        entries = sorted(source.rglob("*"))
        if len(entries) > 20000:
            raise ValueError("Too many history files")
        for path in entries:
            if path.is_symlink():
                raise ValueError("Symbolic links are not accepted in imported history")
            if path.is_dir():
                continue
            info = regular(path)
            if info.st_size > MAX_FILE:
                raise ValueError("History file exceeds the 1 GiB import limit")
            relative = path.relative_to(source).as_posix()
            name = path.name.lower()
            if name.endswith((".html", ".htm")) or (name.startswith("awstats") and name.endswith(".txt")):
                if info.st_size > 8 * 1024 * 1024:
                    raise ValueError("Historical report exceeds 8 MiB")
                key = hashlib.sha256(relative.encode()).hexdigest()
                shutil.copyfile(path, archived / key)
                reports.append({"id": key, "name": relative, "html": name.endswith((".html", ".htm"))})
                total += info.st_size
            elif re.fullmatch(r"(?:proxy_)?access(?:_ssl)?_log(?:[.\-_].*)?", name):
                target = raw / (hashlib.sha256(relative.encode()).hexdigest() + ".log")
                digest, size = hashlib.sha256(), 0
                opener = gzip.open if name.endswith(".gz") else open
                with opener(path, "rb") as inp, target.open("wb") as out:
                    while chunk := inp.read(1024 * 1024):
                        size += len(chunk)
                        total += len(chunk)
                        if size > MAX_FILE or total > MAX_HISTORY:
                            raise ValueError("Decompressed history exceeds the import limit")
                        digest.update(chunk)
                        out.write(chunk)
                # Byte-identical rotated copies are only parsed once.
                if digest.hexdigest() not in seen:
                    seen.add(digest.hexdigest())
                    logs.append((name, target))
                else:
                    target.unlink()
            if total > MAX_HISTORY:
                raise ValueError("History exceeds the 4 GiB import limit")
        # Nginx proxy logs cover static and proxied requests; don't count Apache's
        # view of those same proxied requests again. Choose independently per scheme.
        selected = []
        for ssl in [False, True]:
            group = [(name, path) for name, path in logs if ("_ssl_log" in name) == ssl]
            proxy = [(name, path) for name, path in group if name.startswith("proxy_")]
            selected.extend(path for _, path in (proxy or group))
        summary, warning = None, None
        if selected:
            try:
                warning = check_history_overlap(selected, work)
                if warning is None:
                    summary = run_goaccess(exe, selected, work, False, geoip)
            except (ValueError, OSError, subprocess.TimeoutExpired):
                warning = "History files were preserved, but a GoAccess report could not be rebuilt. Check log format and GoAccess availability."
        if not reports and not selected:
            raise ValueError("No AWStats reports or supported Plesk access logs found")
        return publish(base, "history", work, {"summary": summary, "reports": reports,
                       "log_files": len(selected), "geoip": bool(geoip), "warning": warning})
    except Exception:
        shutil.rmtree(work)
        raise


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["collect", "history"])
    parser.add_argument("--root", required=True)
    parser.add_argument("--domain-id", required=True, type=int)
    parser.add_argument("--log-root", default="/var/log/nginx")
    parser.add_argument("--host", action="append", default=[])
    parser.add_argument("--source")
    parser.add_argument("--goaccess", default="goaccess")
    parser.add_argument("--geoip")
    args = parser.parse_args()
    if args.domain_id <= 0:
        raise ValueError("Invalid domain ID")
    os.umask(0o077)
    base = private_dir(Path(args.root) / str(args.domain_id))
    lock_path = base / "lock"
    if lock_path.is_symlink():
        raise ValueError("Invalid statistics lock")
    with lock_path.open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError("Statistics are already being updated; retry shortly") from None
        if args.action == "collect":
            result = collect(base, Path(args.log_root), args.host, args.goaccess, args.geoip)
        else:
            result = history(base, Path(args.source), args.goaccess, args.geoip)
        print(json.dumps(result))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(json.dumps({"error": str(error)}))
        raise SystemExit(1)
