#!/usr/bin/env python3
"""Hostctl's root-side spam setup. No mailbox contents or credentials are logged.

Configuration failures restore the previous files and Postfix parameters. Package
installation is intentionally not rolled back. Only Hostctl-owned files and the
five recorded Postfix parameters are restored on disable.
"""
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time

STATE = Path('/var/lib/hostctl/spam-protection')
SIEVE = Path('/etc/dovecot/hostctl-spam')
DOVECOT = Path('/etc/dovecot/conf.d/99-hostctl-spam.conf')
RSPAMD_NAMES = (
    'worker-proxy.inc', 'worker-normal.inc', 'worker-controller.inc',
    'redis.conf', 'actions.conf', 'greylist.conf', 'force_actions.conf',
    'classifier-bayes.conf', 'milter_headers.conf', 'dkim_signing.conf',
)
FILE_PATHS = [Path('/etc/rspamd/override.d') / name for name in RSPAMD_NAMES] + [
    Path('/etc/systemd/system/rspamd.service.d/hostctl.conf'),
    Path('/etc/hostctl-spam-redis.conf'),
    Path('/etc/systemd/system/hostctl-spam-redis.service'),
    DOVECOT, SIEVE / 'delivery.sieve', SIEVE / 'learn-spam.sieve',
    SIEVE / 'learn-ham.sieve', SIEVE / 'bin/learn-spam', SIEVE / 'bin/learn-ham',
]
COMPILED = [p.with_suffix('.svbin') for p in FILE_PATHS if p.suffix == '.sieve']
PARAMETERS = {
    'smtpd_milters': 'inet:127.0.0.1:11332',
    'non_smtpd_milters': 'inet:127.0.0.1:11332',
    'milter_default_action': 'accept',
    'milter_protocol': '6',
    'virtual_transport': 'lmtp:unix:private/hostctl-lmtp',
}
SERVICES = ('rspamd', 'hostctl-spam-redis', 'dovecot', 'postfix')
PACKAGES = ('rspamd', 'redis-server', 'dovecot-lmtpd', 'dovecot-sieve', 'dovecot-managesieved')


def run(*args, timeout=45, check=True):
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    if check and result.returncode:
        # Do not include configuration contents from command stdout/stderr.
        raise RuntimeError(f'{args[0]} {args[1] if len(args) > 1 else ""} failed (exit {result.returncode}); inspect its server logs')
    return result


def atomic_write(path, content, mode=0o644, uid=0, gid=0):
    path = Path(path)
    if path.is_symlink():
        raise RuntimeError(f'Refusing symlink at {path}')
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='.hostctl-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as out:
            out.write(content)
            out.flush()
            os.fsync(out.fileno())
        os.chmod(name, mode)
        os.chown(name, uid, gid)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def write_json(path, data):
    atomic_write(path, json.dumps(data, sort_keys=True).encode(), 0o600)


def read_json(path):
    return json.loads(path.read_text()) if path.exists() else None


def snapshot(paths):
    result = {}
    for path in paths:
        if path.is_symlink():
            raise RuntimeError(f'Refusing symlink at {path}')
        if path.exists():
            stat = path.stat()
            result[str(path)] = {
                'content': base64.b64encode(path.read_bytes()).decode(),
                'mode': stat.st_mode & 0o777, 'uid': stat.st_uid, 'gid': stat.st_gid,
            }
        else:
            result[str(path)] = None
    return result


def restore_files(files):
    for name, saved in files.items():
        path = Path(name)
        if saved is None:
            path.unlink(missing_ok=True)
        else:
            atomic_write(path, base64.b64decode(saved['content']), saved['mode'], saved['uid'], saved['gid'])


def postfix_values():
    explicit = {}
    for line in run('postconf', '-n').stdout.splitlines():
        key, sep, value = line.partition(' = ')
        if sep and key in PARAMETERS:
            explicit[key] = value
    return {key: explicit.get(key) for key in PARAMETERS}


def set_postfix(values):
    for key, value in values.items():
        if value is None:
            run('postconf', '-X', key)
        else:
            run('postconf', '-e', f'{key}={value}')


def service_active(service):
    return run('systemctl', 'is-active', '--quiet', service, check=False).returncode == 0


def fingerprint(path):
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None


def ensure_no_drift(manifest):
    if manifest and manifest['enabled']:
        for path, digest in manifest['hashes'].items():
            if fingerprint(Path(path)) != digest:
                raise RuntimeError(f'{path} changed outside Hostctl; reconcile that change before applying or disabling')
        for key, expected in PARAMETERS.items():
            if run('postconf', '-h', key).stdout.strip() != expected:
                raise RuntimeError(f'Postfix {key} changed outside Hostctl; reconcile it before applying or disabling')


def preflight(manifest):
    for command in ('postconf', 'postfix', 'dovecot', 'doveconf', 'systemctl', 'apt-get'):
        if not shutil.which(command):
            raise RuntimeError(f'{command} is missing. Install Hostctl Email Server first')
    version = run('dovecot', '--version').stdout.strip()
    if not version.startswith('2.3.'):
        raise RuntimeError(f'Dovecot {version.split()[0]} is unsupported by this setup; Dovecot 2.3 is required')
    if not Path('/etc/dovecot/conf.d/99-hostctl.conf').exists():
        raise RuntimeError('Hostctl virtual mailbox configuration is missing. Set up Email Server first')
    for service in ('postfix', 'dovecot'):
        if not service_active(service):
            raise RuntimeError(f'{service} is not running; repair Email Server first')
    if run('postconf', '-h', 'content_filter').stdout.strip():
        raise RuntimeError('Postfix already has a content filter. Remove that integration before enabling Rspamd')
    overrides = run('postconf', '-P', check=False).stdout
    if re.search(r'/(?:smtpd_milters|non_smtpd_milters|content_filter)\s*=', overrides):
        raise RuntimeError('Postfix has per-service filter overrides; reconcile those before enabling Rspamd')
    if not manifest or not manifest['enabled']:
        for key in ('smtpd_milters', 'non_smtpd_milters'):
            if run('postconf', '-h', key).stdout.strip():
                raise RuntimeError(f'Postfix {key} is already configured; reconcile the existing filter first')
        if run('postconf', '-h', 'virtual_transport').stdout.strip() != 'virtual':
            raise RuntimeError('Postfix uses a custom virtual transport; reconcile it before enabling Spam Protection')
        existing = run('doveconf', '-n').stdout
        if re.search(r'^\s*(?:sieve_before|imapsieve_mailbox\d+_\w+)\s*=', existing, re.M):
            raise RuntimeError('Dovecot has existing global Sieve hooks; reconcile them first')
        for directory in ('/etc/rspamd/local.d', '/etc/rspamd/override.d'):
            for path in Path(directory).glob('*'):
                if path.suffix in ('.conf', '.inc') and path.stat().st_size:
                    raise RuntimeError('Existing custom Rspamd configuration found; reconcile it before using managed setup')
    ensure_no_drift(manifest)


def validate():
    run('rspamadm', 'configtest')
    run('doveconf', '-n')
    for path in FILE_PATHS:
        if path.suffix == '.sieve':
            run('sievec', str(path))
    run('postfix', 'check')


def health(manifest):
    if not manifest or not manifest['enabled']:
        return False, 'Spam Protection is disabled.'
    try:
        ensure_no_drift(manifest)
        if not all(service_active(s) for s in SERVICES):
            return False, 'A required mail or learning service is down.'
        for port in (11332,):
            with socket.create_connection(('127.0.0.1', port), timeout=3):
                pass
        for path in ('/var/spool/postfix/private/hostctl-lmtp', '/run/rspamd/hostctl-controller.sock'):
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.settimeout(3)
                client.connect(path)
        if run('redis-cli', '-s', '/run/hostctl-spam-redis/redis.sock', 'ping').stdout.strip() != 'PONG':
            return False, 'Redis learning storage is unavailable.'
        return True, 'Filtering and delivery services are running. Learning uses the shared server classifier.'
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        return False, str(error)


def status():
    manifest = read_json(STATE / 'manifest.json')
    healthy, message = health(manifest)
    print(json.dumps({'enabled': bool(manifest and manifest['enabled']),
                      'digest': manifest['digest'] if manifest else None,
                      'healthy': healthy, 'message': message}))


def apply(bundle):
    if not isinstance(bundle.get('enabled'), bool) or not re.fullmatch('[a-f0-9]{64}', bundle.get('digest', '')):
        raise RuntimeError('Invalid configuration bundle')
    expected = {str(p) for p in FILE_PATHS} if bundle['enabled'] else set()
    if set(bundle.get('files', {})) != expected or not all(isinstance(v, str) for v in bundle['files'].values()):
        raise RuntimeError('Unexpected configuration paths')
    previous = read_json(STATE / 'manifest.json')
    baseline = read_json(STATE / 'baseline.json')
    if not bundle['enabled'] and (not previous or not previous['enabled']):
        write_json(STATE / 'manifest.json', {**bundle, 'hashes': {}})
        return
    if bundle['enabled']:
        preflight(previous)
        # Installing only missing packages keeps policy changes usable offline
        # and leaves package upgrades to the server's normal update workflow.
        missing = [name for name in PACKAGES if run(
            'dpkg-query', '-W', '-f=${Status}', name, check=False
        ).stdout.strip() != 'install ok installed']
        if missing:
            redis_was_installed = shutil.which('redis-server') is not None
            run('apt-get', 'update', timeout=300)
            run('env', 'DEBIAN_FRONTEND=noninteractive', 'apt-get', 'install', '-y',
                *missing, timeout=480)
            if not redis_was_installed:
                # Only the private instance is needed. Preserve existing Redis services.
                run('systemctl', 'disable', '--now', 'redis-server')
    else:
        ensure_no_drift(previous)
        if baseline is None:
            raise RuntimeError('Original configuration backup is missing; cannot disable safely')

    rollback = {'files': snapshot(FILE_PATHS + COMPILED), 'postfix': postfix_values()}
    running = {service: service_active(service) for service in SERVICES}
    startup = {service: run('systemctl', 'is-enabled', service, check=False).stdout.strip() for service in SERVICES}
    if bundle['enabled'] and (not previous or not previous['enabled']):
        baseline = rollback
        write_json(STATE / 'baseline.json', baseline)
    # Survives a terminated apply process and allows explicit recovery.
    write_json(STATE / 'recovery.json', {**rollback, 'running': running, 'startup': startup, 'manifest': previous})
    try:
        if bundle['enabled']:
            for name, content in bundle['files'].items():
                atomic_write(name, content.encode(), 0o755 if '/bin/' in name else 0o644)
            validate()
            run('systemctl', 'daemon-reload')
            run('systemctl', 'enable', '--now', 'hostctl-spam-redis', 'rspamd')
            run('systemctl', 'restart', 'hostctl-spam-redis')
            run('systemctl', 'restart', 'rspamd')
            run('systemctl', 'restart', 'dovecot')
            # Connect Postfix only after config validation and service startup.
            set_postfix(PARAMETERS)
            run('postfix', 'check')
            run('systemctl', 'reload', 'postfix')
            candidate = {'enabled': True, 'digest': bundle['digest'],
                         'hashes': {str(p): fingerprint(p) for p in FILE_PATHS + COMPILED}}
            deadline = time.monotonic() + 15
            while True:
                healthy, message = health(candidate)
                if healthy:
                    break
                if time.monotonic() >= deadline:
                    raise RuntimeError(message)
                time.sleep(0.25)
        else:
            # Switch back to the original delivery path before removing LMTP hooks.
            set_postfix(baseline['postfix'])
            run('postfix', 'check')
            run('systemctl', 'reload', 'postfix')
            run('systemctl', 'disable', '--now', 'rspamd', 'hostctl-spam-redis')
            restore_files(baseline['files'])
            run('systemctl', 'daemon-reload')
            run('doveconf', '-n')
            run('systemctl', 'restart', 'dovecot')
            candidate = {'enabled': False, 'digest': bundle['digest'], 'hashes': {}}
        write_json(STATE / 'manifest.json', candidate)
        (STATE / 'recovery.json').unlink()
    except Exception as error:
        try:
            recover()
        except Exception:
            raise RuntimeError(f'{error}. Automatic rollback also failed; run manage.py recover as root and inspect mail services') from error
        raise RuntimeError(f'{error}. Previous mail configuration restored') from error


def recover():
    saved = read_json(STATE / 'recovery.json')
    if not saved:
        return
    # Stop newly-created units before removing their configuration files.
    for service, was_running in saved['running'].items():
        if not was_running:
            run('systemctl', 'disable', '--now', service, check=False)
    restore_files(saved['files'])
    run('systemctl', 'daemon-reload')
    set_postfix(saved['postfix'])
    for service, startup in saved.get('startup', {}).items():
        if startup == 'enabled':
            run('systemctl', 'enable', service)
        elif startup == 'disabled':
            run('systemctl', 'disable', service, check=False)
    for service, was_running in saved['running'].items():
        if was_running:
            run('systemctl', 'restart' if service == 'dovecot' else 'reload-or-restart', service)
    if saved['manifest']:
        write_json(STATE / 'manifest.json', saved['manifest'])
    else:
        (STATE / 'manifest.json').unlink(missing_ok=True)
    (STATE / 'recovery.json').unlink()


def main():
    if os.geteuid() != 0:
        raise RuntimeError('Run via Hostctl or as root')
    STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (STATE / 'lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        command = sys.argv[1]
        if command == 'status':
            if (STATE / 'recovery.json').exists():
                print(json.dumps({'enabled': False, 'healthy': False, 'digest': None,
                                  'message': 'An apply was interrupted; run manage.py recover as root before retrying.'}))
            else:
                status()
        elif command == 'recover':
            recover()
        elif command == 'apply':
            if (STATE / 'recovery.json').exists():
                raise RuntimeError('An apply was interrupted. Run manage.py recover as root before retrying')
            apply(json.loads(Path(sys.argv[2]).read_text()))
        else:
            raise RuntimeError('Unknown operation')


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print(f'Spam Protection: {exc}', file=sys.stderr)
        sys.exit(1)
