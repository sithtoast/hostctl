"""Disposable Linux test of generated DKIM configuration and protected key storage."""
import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import socket
import subprocess
import time
import urllib.request

spec = importlib.util.spec_from_file_location('keys', '/key.py')
keys = importlib.util.module_from_spec(spec)
spec.loader.exec_module(keys)
first = keys.prepare('example.com')
second = keys.prepare('example.com', first['selector'])
assert first == second
key = keys.ROOT / 'example.com' / (first['selector'] + '.key')
assert key.stat().st_mode & 0o777 == 0o640
assert key.stat().st_uid == 0
try:
    keys.prepare('../bad.example')
    raise AssertionError('path traversal allowed')
except ValueError:
    pass
try:
    keys.prepare('example.com', 'hcffffffffffffffff')
    raise AssertionError('missing published key replaced')
except ValueError:
    pass
print('PASS: protected, idempotent key generation; unsafe paths and missing published keys refused', flush=True)
subprocess.run(['useradd', 'vmail'], check=True)
bundle = json.loads(Path('/bundle.json').read_text())
for path, content in bundle['files'].items():
    if '/rspamd/' in path or path == '/etc/hostctl-spam-redis.conf':
        p = Path(path)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content.replace('hc0123456789abcdef', first['selector']))
for directory in ('/run/rspamd', '/run/hostctl-spam-redis', '/var/lib/hostctl-spam-redis'):
    Path(directory).mkdir(exist_ok=True)
    subprocess.run(['chown', '_rspamd:_rspamd', directory], check=True)
subprocess.run(['rspamadm', 'configtest'], check=True)
subprocess.run(['runuser', '-u', '_rspamd', '--', 'redis-server', '/etc/hostctl-spam-redis.conf', '--daemonize', 'yes'], check=True)
logs = open('/tmp/rspamd.log', 'w')
subprocess.Popen(['rspamd', '-f', '-u', '_rspamd', '-g', '_rspamd'], stdout=logs, stderr=logs)
deadline = time.monotonic() + 15
while True:
    try:
        with socket.create_connection(('127.0.0.1', 11333), timeout=1):
            break
    except OSError:
        if time.monotonic() > deadline:
            raise
        time.sleep(.1)
body = b'An ordinary test message.\r\n'
headers = [('From', 'Alice <alice@example.com>'), ('To', 'Bob <bob@example.net>'), ('Subject', 'DKIM integration'), ('Date', 'Sun, 06 Sep 2026 12:00:00 -0400'), ('Message-ID', '<dkim-integration@example.com>')]
message = ('\r\n'.join(k + ': ' + v for k, v in headers) + '\r\n\r\n').encode() + body

def scan(user=None):
    req = urllib.request.Request('http://127.0.0.1:11333/checkv2', data=message,
        headers={'From': 'alice@example.com', 'Rcpt': 'bob@example.net', 'IP': '127.0.0.1', **({'User': user} if user else {})})
    with urllib.request.urlopen(req, timeout=30) as response:
        return json.load(response)

result = scan('alice@example.com')
added = result.get('milter', {}).get('add_headers', {})
sig = result.get('dkim-signature') or added.get('DKIM-Signature')
assert sig, result
if isinstance(sig, dict):
    sig = sig['value']
if isinstance(sig, list):
    sig = sig[0]['value'] if isinstance(sig[0], dict) else sig[0]
tags = dict(part.strip().split('=', 1) for part in sig.split(';') if '=' in part)
assert tags['d'] == 'example.com'
assert tags['s'] == first['selector']
assert tags['bh'] == base64.b64encode(hashlib.sha256(body).digest()).decode()

def canonical(name, value):
    value = re.sub(r'\r?\n[ \t]+', ' ', value)
    value = re.sub(r'[ \t]+', ' ', value).strip()
    return (name.lower() + ':' + value + '\r\n').encode()

signed = b''
remaining = list(headers)
for name in tags['h'].split(':'):
    name = name.strip().lower()
    for i in range(len(remaining) - 1, -1, -1):
        if remaining[i][0].lower() == name:
            signed += canonical(*remaining.pop(i))
            break
empty_sig = re.sub(r'\bb=[^;]*', 'b=', sig)
signed += canonical('DKIM-Signature', empty_sig).removesuffix(b'\r\n')
Path('/tmp/signed').write_bytes(signed)
Path('/tmp/signature').write_bytes(base64.b64decode(re.sub(r'\s', '', tags['b'])))
subprocess.run(['openssl', 'pkey', '-in', str(key), '-pubout', '-out', '/tmp/public.pem'], check=True, capture_output=True)
verified = subprocess.run(['openssl', 'dgst', '-sha256', '-verify', '/tmp/public.pem', '-signature', '/tmp/signature', '/tmp/signed'], capture_output=True)
assert verified.returncode == 0, verified.stdout
print('PASS: Rspamd produces a cryptographically valid DKIM signature with the prepared key', flush=True)
for user in (None, 'attacker@other.example'):
    result = scan(user)
    assert not result.get('dkim-signature'), result
    assert not result.get('milter', {}).get('add_headers', {}).get('DKIM-Signature'), result
print('PASS: unauthenticated local mail and mismatched authenticated domains are not signed', flush=True)
