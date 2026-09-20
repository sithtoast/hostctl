"""Real Nginx HTTP, HTTPS and WebSocket forwarding in a disposable Linux container.

Mount the synthetic generated config at /proxy.conf. No external network needed.
"""
import base64
import hashlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import socket
import ssl
import subprocess
import threading

assert Path('/.dockerenv').exists(), 'Disposable container required'


def exact(stream, count):
    output = b''
    while len(output) < count:
        part = stream.read(count - len(output))
        assert part, 'unexpected EOF'
        output += part
    return output


class Upstream(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def do_GET(self):
        if self.headers.get('Upgrade', '').lower() == 'websocket':
            key = self.headers['Sec-WebSocket-Key']
            accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
            self.send_response(101)
            self.send_header('Upgrade', 'websocket')
            self.send_header('Connection', 'Upgrade')
            self.send_header('Sec-WebSocket-Accept', accept)
            self.end_headers()
            header = exact(self.rfile, 2)
            assert header[0] == 0x81 and header[1] & 0x80
            length = header[1] & 0x7f
            mask = exact(self.rfile, 4)
            payload = exact(self.rfile, length)
            plain = bytes(value ^ mask[i % 4] for i, value in enumerate(payload))
            self.wfile.write(bytes((0x81, len(plain))) + plain)
            self.wfile.flush()
            self.close_connection = True
        else:
            body = json.dumps({'path': self.path, 'host': self.headers['Host'],
                               'upgrade': self.headers.get('Upgrade'),
                               'scheme': self.headers.get('X-Forwarded-Proto')}).encode()
            self.send_response(200)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    def log_message(self, *_args):
        pass


def get(host, path='/', upgrade=False):
    connection = http.client.HTTPConnection('127.0.0.1', 80, timeout=5)
    headers = {'Host': host}
    if upgrade:
        headers.update(Upgrade='websocket', Connection='Upgrade', **{'Sec-WebSocket-Key': 'dGhlIHNhbXBsZSBub25jZQ==', 'Sec-WebSocket-Version': '13'})
    connection.request('GET', path, headers=headers)
    response = connection.getresponse()
    content = response.read()
    location = response.getheader('Location')
    connection.close()
    return response.status, content, location


subprocess.run(['/usr/bin/openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', '/tmp/upstream.key', '-out', '/tmp/upstream.pem', '-days', '1', '-subj', '/CN=local-test'], check=True, capture_output=True)
http_server = ThreadingHTTPServer(('127.0.0.1', 18080), Upstream)
https_server = ThreadingHTTPServer(('127.0.0.1', 18443), Upstream)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain('/tmp/upstream.pem', '/tmp/upstream.key')
https_server.socket = context.wrap_socket(https_server.socket, server_side=True)
for server in (http_server, https_server):
    threading.Thread(target=server.serve_forever, daemon=True).start()
Path('/etc/nginx/sites-enabled/default').unlink(missing_ok=True)
Path('/etc/nginx/conf.d/proxy-test.conf').write_bytes(Path('/proxy.conf').read_bytes())
root = Path('/var/www/example.test/httpdocs')
root.mkdir(parents=True, exist_ok=True)
(root / 'index.html').write_text('APEX UNCHANGED')
subprocess.run(['/usr/sbin/nginx', '-t'], check=True)
subprocess.run(['/usr/sbin/nginx'], check=True)
try:
    assert get('example.test')[1] == b'APEX UNCHANGED'
    for host in ('app.example.test', 'secure.example.test'):
        status, body, _ = get(host, '/nested?query=yes')
        assert status == 200 and json.loads(body) == {'path': '/nested?query=yes', 'host': host, 'upgrade': None, 'scheme': 'http'}, body
    assert get('api.example.test', '/api')[0] == 301
    assert json.loads(get('api.example.test', '/api/nested?ok=1')[1])['path'] == '/nested?ok=1'
    status, body, _ = get('plain.example.test', upgrade=True)
    assert status == 200 and json.loads(body)['upgrade'] is None
    with socket.create_connection(('127.0.0.1', 80), timeout=5) as client:
        client.sendall(b'GET /socket HTTP/1.1\r\nHost: app.example.test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n')
        stream = client.makefile('rb')
        headers = b''
        while not headers.endswith(b'\r\n\r\n'):
            headers += exact(stream, 1)
        assert b'101 Switching Protocols' in headers, headers
        assert b's3pPLMBiTxaQ9kYGzzhZRbK+xOo=' in headers
        message, mask = b'websocket-echo', b'abcd'
        client.sendall(bytes((0x81, 0x80 | len(message))) + mask + bytes(value ^ mask[i % 4] for i, value in enumerate(message)))
        assert exact(stream, 2) == bytes((0x81, len(message)))
        assert exact(stream, len(message)) == message
    print('PASS: actual Nginx root/subdomain routing, prefix stripping, local HTTPS, WebSocket handshake/echo and disabled-upgrade behavior')
finally:
    subprocess.run(['/usr/sbin/nginx', '-s', 'quit'], check=True)
    for server in (http_server, https_server):
        server.shutdown()
        server.server_close()
