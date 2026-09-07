#!/usr/bin/env python3
"""Create one protected RSA key per domain. Never return or log private material."""
import base64
import fcntl
import grp
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import tempfile

ROOT = Path('/var/lib/hostctl/dkim')

def prepare(domain, selector=None):
    if len(domain) > 253 or '.' not in domain or not all(
        re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', p) for p in domain.split('.')
    ):
        raise ValueError('Invalid domain')
    if selector is not None and not re.fullmatch(r'hc[a-f0-9]{16}', selector):
        raise ValueError('Invalid selector')
    existing_selector = selector is not None
    gid = grp.getgrnam('_rspamd').gr_gid
    # Root-owned parent prevents service users replacing keys or symlinking paths.
    ROOT.mkdir(parents=True, exist_ok=True, mode=0o750)
    if ROOT.is_symlink():
        raise ValueError('Unsafe key directory')
    os.chown(ROOT, 0, gid)
    os.chmod(ROOT, 0o750)
    with (ROOT / '.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        folder = ROOT / domain
        if folder.is_symlink():
            raise ValueError('Unsafe domain directory')
        folder.mkdir(mode=0o750, exist_ok=True)
        os.chown(folder, 0, gid)
        os.chmod(folder, 0o750)
        metadata = folder / 'selector'
        if selector is None:
            selector = metadata.read_text().strip() if metadata.exists() else 'hc' + secrets.token_hex(8)
        if not re.fullmatch(r'hc[a-f0-9]{16}', selector):
            raise ValueError('Invalid saved selector')
        key = folder / (selector + '.key')
        if key.is_symlink():
            raise ValueError('Unsafe key file')
        if not key.exists():
            # An explicit selector means a key was previously published. Never silently rotate it.
            if existing_selector:
                raise ValueError('Previously prepared key is missing; restore it from backup')
            fd, temp = tempfile.mkstemp(dir=folder)
            os.close(fd)
            try:
                subprocess.run(['openssl', 'genpkey', '-algorithm', 'RSA', '-pkeyopt',
                    'rsa_keygen_bits:2048', '-out', temp], check=True, capture_output=True, timeout=30)
                os.chown(temp, 0, gid)
                os.chmod(temp, 0o640)
                os.replace(temp, key)
            finally:
                if os.path.exists(temp):
                    os.unlink(temp)
        os.chown(key, 0, gid)
        os.chmod(key, 0o640)
        public = subprocess.run(['openssl', 'pkey', '-in', str(key), '-pubout', '-outform', 'DER'],
            check=True, capture_output=True, timeout=10).stdout
        subprocess.run(['runuser', '-u', '_rspamd', '--', 'test', '-r', str(key)], check=True, capture_output=True, timeout=5)
        metadata.write_text(selector)
        os.chmod(metadata, 0o600)
        return {'selector': selector, 'public_key': base64.b64encode(public).decode('ascii')}

if __name__ == '__main__':
    try:
        if os.geteuid() != 0 or len(sys.argv) not in (2, 3):
            raise ValueError('Run as root with a domain and optional existing selector')
        print(json.dumps(prepare(sys.argv[1], sys.argv[2] if len(sys.argv) == 3 else None)))
    except Exception:
        print('DKIM key preparation failed; inspect server configuration', file=sys.stderr)
        sys.exit(1)
