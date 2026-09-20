"""Fixed Portainer Standard Agent capability. No caller-selected Docker options."""
import ipaddress
import json
import os
import re
import secrets
import stat
import subprocess

NAME = "hostctl-portainer-agent"
LABEL = "io.hostctl.portainer-owner"
STATE = "/var/lib/hostctl-portainer/agent.json"
DOCKER = ["/usr/bin/docker", "--host=unix:///var/run/docker.sock"]


def validate(data):
    if type(data) is not dict or set(data) != {"version", "bind_address", "agent_secret"}:
        raise ValueError("invalid Portainer configuration")
    version, address, secret = data["version"], data["bind_address"], data["agent_secret"]
    if type(version) is not str or re.fullmatch(r"2\.[0-9]{1,3}\.[0-9]{1,3}", version) is None:
        raise ValueError("exact Portainer version required")
    if type(address) is not str or str(ipaddress.IPv4Address(address)) != address:
        raise ValueError("IPv4 bind address required")
    parsed = ipaddress.IPv4Address(address)
    if parsed.is_multicast or address == "255.255.255.255":
        raise ValueError("unicast or wildcard bind address required")
    if type(secret) is not str or len(secret) > 256 or any(c in secret for c in "\n\r\x00"):
        raise ValueError("invalid agent secret")
    return data


def docker(args, *, env=None, required=True):
    result = subprocess.run(DOCKER + args, capture_output=True, timeout=180,
                            env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", **(env or {})})
    if required and result.returncode:
        raise RuntimeError("Docker operation failed")
    return result


def inspect_container():
    # Check daemon availability before interpreting a missing container.
    docker(["info", "--format", "{{.ServerVersion}}"])
    result = docker(["container", "inspect", NAME], required=False)
    if result.returncode:
        # A missing name is the only benign inspection failure.
        if b"No such container" in result.stderr or b"No such object" in result.stderr:
            return None
        raise RuntimeError("Docker inspection failed")
    return json.loads(result.stdout)[0]


def load(runtime):
    if not os.path.lexists(STATE):
        return None
    fd = os.open(STATE, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd) as source:
        info = os.fstat(source.fileno())
        runtime.require(stat.S_ISREG(info.st_mode) and info.st_uid == 0 and info.st_mode & 0o077 == 0 and info.st_nlink == 1,
                        "untrusted Portainer record")
        record = json.load(source)
    runtime.require(type(record.get("schema_version")) is int and record["schema_version"] == 1 and
                    re.fullmatch(r"[a-f0-9]{48}", record.get("marker", "")) is not None,
                    "invalid Portainer record")
    validate(record["config"])
    return record


def owned(container, record):
    if container is not None and (record is None or
            container.get("Config", {}).get("Labels", {}).get(LABEL) != record["marker"]):
        raise ValueError("unmanaged container collision")


def verify(container, record, require_running=True):
    owned(container, record)
    if container is None:
        raise ValueError("agent container missing")
    config = record["config"]
    if container["Config"]["Image"] != "portainer/agent:" + config["version"]:
        raise ValueError("agent image changed")
    host = container["HostConfig"]
    if host.get("Privileged") or host.get("NetworkMode") == "host" or host.get("PidMode") == "host":
        raise ValueError("unexpected agent privilege")
    expected_binds = {"/var/run/docker.sock:/var/run/docker.sock", "/var/lib/docker/volumes:/var/lib/docker/volumes"}
    if set(host.get("Binds") or []) != expected_binds:
        raise ValueError("agent mounts changed")
    if host.get("PortBindings") != {"9001/tcp": [{"HostIp": config["bind_address"], "HostPort": "9001"}]}:
        raise ValueError("agent port changed")
    secret = [e for e in container["Config"].get("Env", []) if e.startswith("AGENT_SECRET=")]
    expected_secret = ["AGENT_SECRET=" + config["agent_secret"]] if config["agent_secret"] else []
    if secret != expected_secret or host.get("RestartPolicy", {}).get("Name") != "unless-stopped":
        raise ValueError("agent configuration changed")
    if require_running and not container["State"].get("Running"):
        raise ValueError("agent is not running")
    return {"installed": True, "running": bool(container["State"].get("Running")), "version": config["version"],
            "bind_address": config["bind_address"], "port": 9001,
            "secret_configured": bool(config["agent_secret"]), "connected": "unverified"}


def call(action, data, runtime):
    runtime.trusted_directory(runtime.STATE)
    record = load(runtime)
    container = inspect_container()
    owned(container, record)
    if action == "portainer-status":
        if container is None:
            return {"installed": False, "running": False}
        return verify(container, record, require_running=False)
    if action == "portainer-remove":
        if container is not None:
            docker(["container", "rm", "--force", NAME])
        # Keep the ownership reservation for idempotent retries and collision detection.
        return {"installed": False, "running": False}
    validate(data)
    if container is not None:
        if record["config"] != data:
            raise ValueError("remove managed agent before changing its configuration")
        verify(container, record, require_running=False)
        if not container["State"].get("Running"):
            docker(["container", "start", NAME])
        return verify(inspect_container(), record)
    # The repository and image name are fixed; require an exact version matching
    # the operator's server. Never deploy an arbitrary image, mount, or command.
    root = docker(["info", "--format", "{{.DockerRootDir}}"]).stdout.decode().strip()
    if root != "/var/lib/docker":
        raise ValueError("custom Docker data directory requires operator setup")
    docker(["image", "pull", "portainer/agent:" + data["version"]])
    if record is None:
        record = {"schema_version": 1, "marker": secrets.token_hex(24), "config": data}
    else:
        record["config"] = data
    runtime.atomic(STATE, json.dumps(record))
    args = ["container", "run", "--detach", "--name", NAME, "--restart", "unless-stopped",
            "--label", LABEL + "=" + record["marker"],
            "--publish", data["bind_address"] + ":9001:9001",
            "--volume", "/var/run/docker.sock:/var/run/docker.sock",
            "--volume", "/var/lib/docker/volumes:/var/lib/docker/volumes"]
    environment = {}
    if data["agent_secret"]:
        environment["AGENT_SECRET"] = data["agent_secret"]
        args += ["--env", "AGENT_SECRET"]
    args += ["portainer/agent:" + data["version"]]
    docker(args, env=environment)
    return verify(inspect_container(), record)
