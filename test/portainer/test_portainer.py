import copy
import importlib.util
import json
import os
from pathlib import Path
import socket
import tempfile
import threading
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("broker", ROOT / "priv/portainer/broker.py")
broker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(broker)
agent = broker.portainer
CONFIG = {"version": "2.39.0", "bind_address": "127.0.0.1", "agent_secret": "test-secret"}
RECORD = {"schema_version": 1, "marker": "a" * 48, "config": CONFIG}


def request(operation="portainer-install", payload=None):
    return {"version": 1, "id": "604e7211-80cf-44bb-b1d6-8f1441582245", "operation": operation,
            "payload": dict(CONFIG) if payload is None else payload}


def container():
    return {"Config": {"Image": "portainer/agent:2.39.0", "Labels": {agent.LABEL: RECORD["marker"]},
                       "Env": ["AGENT_SECRET=test-secret"]},
            "HostConfig": {"Binds": ["/var/run/docker.sock:/var/run/docker.sock", "/var/lib/docker/volumes:/var/lib/docker/volumes"],
                           "RestartPolicy": {"Name": "unless-stopped"},
                           "PortBindings": {"9001/tcp": [{"HostIp": "127.0.0.1", "HostPort": "9001"}]}},
            "State": {"Running": True}}


class ValidationTest(unittest.TestCase):
    def test_valid_request(self):
        self.assertEqual(broker.validate(request()), ("portainer-install", CONFIG))

    def test_no_arbitrary_operation_or_options(self):
        for operation in ("exec", "docker", "portainer-install;id", {}, None):
            with self.assertRaises(ValueError):
                broker.validate(request(operation))
        for extra in ({"privileged": True}, {"image": "evil/root:latest"}, {"mounts": ["/:/host"]}):
            with self.assertRaises(ValueError):
                broker.validate(request(payload=dict(CONFIG, **extra)))

    def test_malicious_inputs(self):
        for field, values in {"version": ["latest", "2.39.0;id", "../../root", True],
                              "bind_address": ["localhost", "::", "127.0.0.1:9001", "239.1.1.1", "0.0.0.0 --privileged"],
                              "agent_secret": ["secret\nPATH=/tmp", "a\x00b", "x" * 257]}.items():
            for value in values:
                with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                    broker.validate(request(payload=dict(CONFIG, **{field: value})))

    def test_duplicate_keys_and_protocol_versions(self):
        with self.assertRaises(ValueError):
            json.loads('{"version":1,"version":2}', object_pairs_hook=broker.unique_object)
        for version in (True, 2, "1"):
            req = request()
            req["version"] = version
            with self.assertRaises(ValueError):
                broker.validate(req)

    def test_unmanaged_collision(self):
        with self.assertRaises(ValueError):
            agent.owned(container(), None)
        other = dict(RECORD, marker="b" * 48)
        with self.assertRaises(ValueError):
            agent.owned(container(), other)

    def test_tampered_configuration_rejected(self):
        for change in ({"Privileged": True}, {"NetworkMode": "host"}, {"PidMode": "host"},
                       {"Binds": ["/:/host"]}, {"PortBindings": {}}):
            modified = container()
            modified["HostConfig"].update(change)
            with self.assertRaises(ValueError):
                agent.verify(modified, RECORD)

    def test_stopped_is_reported_without_claiming_running(self):
        stopped = container()
        stopped["State"]["Running"] = False
        self.assertFalse(agent.verify(stopped, RECORD, require_running=False)["running"])
        with self.assertRaises(ValueError):
            agent.verify(stopped, RECORD)

    def test_retry_does_not_recreate_verified_container(self):
        with patch.object(agent, "load", return_value=RECORD), patch.object(agent, "inspect_container", return_value=container()), patch.object(agent, "docker") as docker:
            result = agent.call("portainer-install", dict(CONFIG), Mock())
            self.assertTrue(result["running"])
            docker.assert_not_called()
            self.assertNotIn("agent_secret", result)

    def test_failed_run_keeps_claim_for_retry_and_secret_is_not_in_argv(self):
        runtime = Mock()
        def run(args, **kwargs):
            self.assertNotIn("test-secret", json.dumps(args))
            if args[:2] == ["container", "run"]:
                self.assertNotIn("--privileged", args)
                self.assertEqual(kwargs["env"], {"AGENT_SECRET": "test-secret"})
                raise RuntimeError("simulated interruption")
            return Mock(stdout=b"/var/lib/docker\n")
        with patch.object(agent, "load", return_value=None), patch.object(agent, "inspect_container", return_value=None), patch.object(agent, "docker", side_effect=run):
            with self.assertRaises(RuntimeError):
                agent.call("portainer-install", dict(CONFIG), runtime)
            runtime.atomic.assert_called_once()
            self.assertEqual(json.loads(runtime.atomic.call_args.args[1])["config"], CONFIG)

    def test_removal_targets_only_managed_agent(self):
        with patch.object(agent, "load", return_value=RECORD), patch.object(agent, "inspect_container", return_value=container()), patch.object(agent, "docker") as docker:
            self.assertFalse(agent.call("portainer-remove", {}, Mock())["installed"])
            docker.assert_called_once_with(["container", "rm", "--force", "hostctl-portainer-agent"])


@unittest.skipUnless(hasattr(socket, "SO_PEERCRED"), "Linux peer credentials required")
class SocketTest(unittest.TestCase):
    def exchange(self, uid, content):
        with tempfile.TemporaryDirectory() as directory:
            path = directory + "/broker.sock"
            dispatch = Mock(return_value={"installed": False})
            with broker.Server(path, uid, dispatch) as server:
                thread = threading.Thread(target=server.handle_request)
                thread.start()
                with socket.socket(socket.AF_UNIX) as client:
                    client.settimeout(3)
                    client.connect(path)
                    client.sendall(content)
                    response = json.loads(client.makefile("rb").readline())
                thread.join(timeout=3)
                self.assertFalse(thread.is_alive())
                return response, dispatch

    def test_real_peer_credentials(self):
        data = json.dumps(request("portainer-status", {})).encode() + b"\n"
        reply, dispatch = self.exchange(os.getuid(), data)
        self.assertEqual(reply["ok"], {"installed": False})
        dispatch.assert_called_once()
        reply, dispatch = self.exchange(os.getuid() + 1, data)
        self.assertIn("error", reply)
        dispatch.assert_not_called()

    def test_bad_frames_never_dispatch(self):
        for data in (b"no json\n", b"[]\n", b"\xff\n", b"a" * broker.MAX_REQUEST + b"\n"):
            reply, dispatch = self.exchange(os.getuid(), data)
            self.assertIn("error", reply)
            dispatch.assert_not_called()


if __name__ == "__main__":
    unittest.main()
