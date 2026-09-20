#!/usr/bin/python3
"""Portainer-only Unix socket broker, installed outside service-writable code."""
import importlib.util
import json
import logging
import os
import pwd
import re
import socket
import socketserver
import stat
import struct
import tempfile
import time
import uuid

spec = importlib.util.spec_from_file_location("portainer", os.path.join(os.path.dirname(os.path.abspath(__file__)), "portainer.py"))
portainer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(portainer)

STATE = "/var/lib/hostctl-portainer"
SOCKET = "/run/hostctl-portainer/control.sock"
MAX_REQUEST = 8192
DIRECTORY = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
OPERATIONS = {"portainer-status", "portainer-install", "portainer-remove"}


def require(condition, message="invalid_request"):
    if not condition:
        raise ValueError(message)


def trusted_directory(path, mode=0o700):
    fd = os.open("/", DIRECTORY)
    try:
        for component in path.strip("/").split("/"):
            try:
                os.mkdir(component, mode, dir_fd=fd)
            except FileExistsError:
                pass
            child = os.open(component, DIRECTORY, dir_fd=fd)
            os.close(fd)
            fd = child
            info = os.fstat(fd)
            require(info.st_uid == 0 and info.st_mode & 0o022 == 0, "untrusted_directory")
    finally:
        os.close(fd)


def atomic(path, content):
    require(path == portainer.STATE)
    fd, temporary = tempfile.mkstemp(prefix=".agent-", dir=STATE)
    try:
        with os.fdopen(fd, "w") as output:
            os.fchmod(output.fileno(), 0o600)
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        parent = os.open(STATE, DIRECTORY)
        try:
            os.fsync(parent)
        finally:
            os.close(parent)
    finally:
        if os.path.lexists(temporary):
            os.unlink(temporary)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result)
        result[key] = value
    return result


def validate(request):
    require(type(request) is dict and set(request) == {"version", "id", "operation", "payload"})
    require(type(request["version"]) is int and request["version"] == 1)
    require(type(request["id"]) is str and
            re.fullmatch(r"[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}", request["id"]) is not None)
    operation, payload = request["operation"], request["payload"]
    require(type(operation) is str and operation in OPERATIONS)
    if operation == "portainer-install":
        portainer.validate(payload)
    else:
        require(type(payload) is dict and not payload)
    return operation, payload


def peer_uid(connection):
    return struct.unpack("3i", connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))[1]


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        self.connection.settimeout(5)
        operation_id, request_id, operation, uid = str(uuid.uuid4()), None, None, None
        outcome = "failed"
        started = time.monotonic()
        try:
            uid = peer_uid(self.connection)
            require(uid == self.server.allowed_uid, "unauthorized_peer")
            line = self.rfile.readline(MAX_REQUEST + 1)
            require(len(line) <= MAX_REQUEST and line.endswith(b"\n"))
            request = json.loads(line, object_pairs_hook=unique_object)
            operation, payload = validate(request)
            request_id = request["id"]
            response = {"ok": self.server.dispatch(operation, payload)}
            outcome = "completed"
        except Exception:
            response = {"error": "portainer_operation_failed"}
        response.update(version=1, id=request_id, operation_id=operation_id)
        logging.info(json.dumps({"operation_id": operation_id, "request_id": request_id,
                                 "operation": operation, "peer_uid": uid, "outcome": outcome,
                                 "duration_ms": int((time.monotonic() - started) * 1000)}))
        try:
            self.wfile.write(json.dumps(response).encode() + b"\n")
        except OSError:
            pass


class Server(socketserver.UnixStreamServer):
    request_queue_size = 16

    def __init__(self, path, allowed_uid, dispatch):
        self.allowed_uid, self.dispatch = allowed_uid, dispatch
        super().__init__(path, Handler)


def serve():
    require(os.geteuid() == 0, "root_required")
    os.environ.clear()
    os.environ.update(PATH="/usr/sbin:/usr/bin:/sbin:/bin", LANG="C.UTF-8")
    os.umask(0o077)
    service = pwd.getpwnam("hostctl")
    require(service.pw_uid != 0)
    trusted_directory(STATE)
    trusted_directory(os.path.dirname(SOCKET), 0o750)
    if os.path.lexists(SOCKET):
        info = os.lstat(SOCKET)
        require(stat.S_ISSOCK(info.st_mode) and info.st_uid == 0, "socket_collision")
        with socket.socket(socket.AF_UNIX) as probe:
            try:
                probe.connect(SOCKET)
            except ConnectionRefusedError:
                os.unlink(SOCKET)
            else:
                raise ValueError("broker_already_running")
    import sys
    runtime = sys.modules[__name__]
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    with Server(SOCKET, service.pw_uid, lambda action, data: portainer.call(action, data, runtime)) as server:
        os.chown(os.path.dirname(SOCKET), 0, service.pw_gid)
        os.chmod(os.path.dirname(SOCKET), 0o750)
        os.chown(SOCKET, 0, service.pw_gid)
        os.chmod(SOCKET, 0o660)
        server.serve_forever()


if __name__ == "__main__":
    serve()
