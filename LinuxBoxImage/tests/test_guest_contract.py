import base64
import importlib.util
import io
import json
import os
from pathlib import Path
import socket
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "guest"))

import nativecontainers_agent as agent
import nativecontainers_runtime as runtime
import nativecontainers_verify as verifier


def configuration():
    return {
        "schema": 1,
        "credentials": {
            "schema": 1,
            "provider": "decodo",
            "product": "residential",
            "scheme": "socks5",
            "host": "gate.decodo.com",
            "port": 7000,
            "username": "account-session-0123456789abcdef-sessionduration-1440",
            "password": "secret",
        },
        "endpoints": {
            "schema": 1,
            "host": "gate.decodo.com",
            "port": 7000,
            "selected": "93.184.216.34",
            "allowed": ["1.1.1.1", "93.184.216.34"],
            "doh": {
                "address": "1.1.1.1",
                "port": 443,
                "server_name": "cloudflare-dns.com",
                "path": "/dns-query",
            },
            "resolved_at": "2026-07-18T00:00:00Z",
        },
    }


class ProfileContractTests(unittest.TestCase):
    def _request(self, operation, payload):
        return agent.validate_operation_payload(operation, payload)

    def test_schema_two_identity_and_exact_profile_payloads(self):
        self.assertEqual(agent.SCHEMA_VERSION, 2)
        self.assertEqual(agent.PROTOCOL_VERSION, 2)
        self.assertEqual(self._request("configure", {"profile": "standard"}), {"profile": "standard"})
        residential = {
            "profile": "residential",
            "configuration": configuration(),
            "expectedProxyIP": "93.184.216.34",
        }
        self.assertEqual(self._request("configure", residential), residential)
        self.assertEqual(
            self._request("verify", {"profile": "standard"}),
            {"profile": "standard"},
        )
        self.assertEqual(
            self._request(
                "verify",
                {
                    "profile": "residential",
                    "expectedProxyIP": "93.184.216.34",
                    "hostDirectIP": "1.2.3.4",
                },
            ),
            {
                "profile": "residential",
                "expectedProxyIP": "93.184.216.34",
                "hostDirectIP": "1.2.3.4",
            },
        )

    def test_profile_payloads_reject_extra_and_mixed_fields(self):
        invalid = (
            ("configure", {"profile": "standard", "configuration": configuration()}),
            ("configure", {"profile": "residential"}),
            ("configure", {"profile": "residential", "configuration": configuration()}),
            ("configure", {"profile": "standard", "expectedProxyIP": "93.184.216.34"}),
            ("verify", {"profile": "standard", "expectedProxyIP": "93.184.216.34"}),
            ("verify", {"profile": "residential", "expectedProxyIP": "93.184.216.34"}),
            ("verify", {"profile": "unknown"}),
        )
        for operation, payload in invalid:
            with self.subTest(operation=operation, payload=payload):
                with self.assertRaises(agent.AgentFailure):
                    self._request(operation, payload)


    def test_standard_status_is_explicit_and_nullable(self):
        machine = object.__new__(agent.LinuxBoxAgent)
        machine.state = "awaitingConfiguration"
        machine.profile = None
        machine.boot_id = "01234567-89ab-cdef-8123-456789abcdef"
        machine.uplink = None
        machine.active_operation = None
        machine.state_lock = threading.RLock()
        with mock.patch.object(agent.os.path, "isfile", return_value=False), mock.patch.object(
            agent, "service_active", return_value=False
        ), mock.patch.object(machine, "_baseline_active", return_value=True):
            status = machine.status()
        self.assertEqual(
            set(status),
            {
                "profile", "state", "bootID", "uplink", "authorizationActive",
                "networkdActive", "singBoxActive", "baselineActive", "ready",
                "activeOperation",
            },
        )
        self.assertIsNone(status["profile"])
        self.assertIsNone(status["uplink"])
        self.assertIsNone(status["activeOperation"])
        self.assertFalse(status["authorizationActive"])
        self.assertFalse(status["singBoxActive"])
        self.assertTrue(status["baselineActive"])

    def test_standard_verify_has_no_proxy_evidence(self):
        machine = object.__new__(agent.LinuxBoxAgent)
        machine.state = "healthy"
        machine.profile = "standard"
        machine.boot_id = "01234567-89ab-cdef-8123-456789abcdef"
        machine.uplink = "enp0s1"
        machine.state_lock = threading.RLock()
        with mock.patch.object(
            verifier, "run_standard", return_value={"checks": []}
        ) as run_standard, mock.patch.object(verifier, "publish") as publish:
            result = machine.verify({"profile": "standard"})
        self.assertEqual(result, {"egress": None, "doh": None, "checks": []})
        run_standard.assert_called_once_with("enp0s1")
        publish.assert_not_called()

    def test_standard_control_loss_does_not_quiesce(self):
        machine = object.__new__(agent.LinuxBoxAgent)
        machine.state = "ready"
        machine.profile = "standard"
        machine.state_lock = threading.RLock()
        machine.active_operation = None
        machine.active_cancel = None
        with mock.patch.object(machine, "quiesce") as quiesce:
            machine.control_loss()
        quiesce.assert_not_called()
        self.assertEqual(machine.state, "ready")

class RuntimePolicyTests(unittest.TestCase):
    def test_exact_payload_and_rendered_policy(self):
        payload = runtime.validate_payload(configuration())
        rules = runtime.render_nftables("enp0s1", payload["endpoints"])
        self.assertIn('iifname "enp0s1" udp sport 67 udp dport 68 accept', rules)
        self.assertIn('oifname "enp0s1" udp sport 68 udp dport 67 accept', rules)
        self.assertIn("meta skuid 0", rules)
        self.assertIn("@proxy_endpoints accept", rules)
        self.assertIn("counter name unprivileged_gateway_drop drop", rules)
        self.assertIn("counter name host_route_drop drop", rules)
        self.assertIn("counter name physical_udp_drop drop", rules)
        self.assertIn("counter name physical_ipv4_drop drop", rules)
        self.assertIn("counter name ipv6_drop drop", rules)

        rendered = runtime.render_sing_box("enp0s1", payload["credentials"], payload["endpoints"])
        self.assertTrue(rendered["log"]["disabled"])
        self.assertEqual(rendered["inbounds"][0]["interface_name"], "sb-tun")
        self.assertEqual(rendered["inbounds"][0]["address"], ["172.19.0.1/30"])
        self.assertTrue(rendered["inbounds"][0]["strict_route"])
        self.assertEqual(rendered["outbounds"][0]["network"], "tcp")
        self.assertEqual(rendered["outbounds"][0]["bind_interface"], "enp0s1")
        self.assertEqual(rendered["dns"]["servers"][0]["server"], "1.1.1.1")
        self.assertEqual(rendered["dns"]["servers"][0]["tls"]["server_name"], "cloudflare-dns.com")
        self.assertEqual(rendered["route"]["rules"][1], {"network": "udp", "action": "reject", "method": "drop"})

    def test_payload_rejects_extra_duplicate_and_unsorted_endpoints(self):
        extra = configuration()
        extra["unexpected"] = True
        with self.assertRaises(runtime.ValidationFailure):
            runtime.validate_payload(extra)
        with self.assertRaises(runtime.ValidationFailure):
            runtime.read_json(io.BytesIO(b'{"schema":1,"schema":1}'))
        unsorted = configuration()
        unsorted["endpoints"]["allowed"] = ["93.184.216.34", "1.1.1.1"]
        with self.assertRaises(runtime.ValidationFailure):
            runtime.validate_payload(unsorted)

    def test_uplink_discovery_uses_virtio_driver_before_dhcp(self):
        with tempfile.TemporaryDirectory() as directory:
            sys_class_net = Path(directory)
            uplink = sys_class_net / "enp0s1"
            (uplink / "device").mkdir(parents=True)
            (uplink / "type").write_text("1\n", encoding="ascii")
            driver = sys_class_net / "drivers" / "virtio_net"
            driver.mkdir(parents=True)
            (uplink / "device" / "driver").symlink_to(driver)
            (sys_class_net / "lo").mkdir()
            with mock.patch.object(runtime, "SYS_CLASS_NET", str(sys_class_net)):
                self.assertEqual(runtime.discover_uplink(), "enp0s1")

            second = sys_class_net / "ens2"
            (second / "device").mkdir(parents=True)
            (second / "type").write_text("1\n", encoding="ascii")
            (second / "device" / "driver").symlink_to(driver)
            with mock.patch.object(runtime, "SYS_CLASS_NET", str(sys_class_net)):
                with self.assertRaises(runtime.RuntimeFailure):
                    runtime.discover_uplink()


class FramingAndProtocolTests(unittest.TestCase):
    def test_fragmented_frame_and_exact_response(self):
        left, right = socket.socketpair()
        try:
            framed = agent.FramedConnection(left)
            payload = b'{"value":1}'
            wire = len(payload).to_bytes(4, "big") + payload

            def writer():
                for byte in wire:
                    right.send(bytes([byte]))
                    time.sleep(0.001)

            thread = threading.Thread(target=writer)
            thread.start()
            self.assertEqual(framed.read_frame(time.monotonic() + 2), payload)
            thread.join(timeout=2)
            framed.send({"ok": True})
            header = right.recv(4)
            length = int.from_bytes(header, "big")
            response = right.recv(length)
            self.assertEqual(json.loads(response), {"ok": True})
        finally:
            left.close()
            right.close()

    def test_request_requires_exact_schema_and_canonical_values(self):
        challenge = base64.b64encode(bytes(range(32))).decode("ascii")
        value = {
            "schemaVersion": 2,
            "requestID": "01234567-89ab-cdef-8123-456789abcdef",
            "operation": "hello",
            "timeoutSeconds": 30,
            "payload": {"challenge": challenge},
        }
        parsed = agent.parse_request(json.dumps(value).encode())
        self.assertEqual(parsed["payload"]["challenge"], bytes(range(32)))
        value["requestID"] = value["requestID"].upper()
        with self.assertRaises(agent.AgentFailure):
            agent.parse_request(json.dumps(value).encode())
        duplicate = b'{"schemaVersion":2,"schemaVersion":2,"requestID":"01234567-89ab-cdef-8123-456789abcdef","operation":"status","timeoutSeconds":30,"payload":{}}'
        with self.assertRaises(agent.AgentFailure):
            agent.parse_request(duplicate)

    def test_exec_bounds_are_enforced(self):
        self.assertEqual(agent.validate_argv(["/usr/bin/id"]), ["/usr/bin/id"])
        for invalid in ([], [""], ["a" * 4097], ["a"] * 65):
            with self.assertRaises(agent.AgentFailure):
                agent.validate_argv(invalid)

    def test_non_ascii_baked_identity_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            identity = Path(directory) / "image.json"
            identity.write_text(
                json.dumps(
                    {
                        "schema": 1,
                        "imageID": "débian",
                        "imageBuildRevision": "linux-box-image-v1",
                        "protocol": 2,
                    }
                ),
                encoding="utf-8",
            )
            real_fstat = os.fstat

            def root_owned_fstat(descriptor):
                metadata = real_fstat(descriptor)
                return mock.Mock(
                    st_mode=metadata.st_mode,
                    st_uid=0,
                    st_size=metadata.st_size,
                )

            candidate = object.__new__(agent.LinuxBoxAgent)
            with mock.patch.object(agent, "IMAGE_IDENTITY_PATH", str(identity)):
                with mock.patch.object(agent.os, "fstat", side_effect=root_owned_fstat):
                    with self.assertRaises(agent.AgentFailure) as raised:
                        candidate._load_identity()
            self.assertEqual(raised.exception.code, "internal_error")

    def test_exec_uses_pipe_stdin_and_closes_host_end_immediately(self):
        class ExpectedStop(Exception):
            pass

        class Stdin:
            def close(self):
                raise ExpectedStop()

        candidate = object.__new__(agent.LinuxBoxAgent)
        candidate.state = "ready"
        candidate.state_lock = threading.RLock()
        process = mock.Mock(stdin=Stdin())
        with mock.patch.object(agent.subprocess, "Popen", return_value=process) as popen:
            with self.assertRaises(ExpectedStop):
                candidate.exec(
                    {"argv": ["/usr/bin/id"]},
                    30,
                    threading.Event(),
                )
        self.assertIs(popen.call_args.kwargs["stdin"], agent.subprocess.PIPE)


class ServiceGraphTests(unittest.TestCase):
    def _unit(self, name):
        sections = {}
        current = None
        for raw in (ROOT / "systemd" / name).read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("[") and line.endswith("]"):
                current = line[1:-1]
                sections[current] = {}
                continue
            key, value = line.split("=", 1)
            sections[current][key] = value
        return sections

    def test_network_gate_is_acyclic_and_fail_closed(self):
        baseline = self._unit("nativecontainers-baseline-firewall.service")
        agent_unit = self._unit("nativecontainers-agent.service")
        authorization = self._unit("nativecontainers-network-authorization.service")
        networkd = self._unit("10-nativecontainers-authorization.conf")
        sing_box = self._unit("nativecontainers-sing-box.service")
        self.assertEqual(baseline["Unit"]["DefaultDependencies"], "no")
        self.assertIn("systemd-networkd.service", baseline["Unit"]["Before"])
        self.assertIn("nativecontainers-baseline-firewall.service", agent_unit["Unit"]["Requires"])
        self.assertIn("nativecontainers-baseline-firewall.service", agent_unit["Unit"]["After"])
        self.assertEqual(authorization["Service"]["Type"], "oneshot")
        self.assertEqual(authorization["Service"]["TimeoutStartSec"], "0")
        self.assertEqual(authorization["Service"]["RemainAfterExit"], "yes")
        self.assertNotIn("WantedBy", authorization.get("Install", {}))
        self.assertIn("systemd-networkd.service", authorization["Unit"]["Before"])
        for dependency in (
            "nativecontainers-baseline-firewall.service",
            "nativecontainers-agent.service",
            "nativecontainers-network-authorization.service",
        ):
            self.assertIn(dependency, networkd["Unit"]["Requires"])
            self.assertIn(dependency, networkd["Unit"]["After"])
        self.assertIn("nativecontainers-network-authorization.service", sing_box["Unit"]["Requires"])
        self.assertIn("network-online.target", sing_box["Unit"]["After"])

    def test_authorization_helper_blocks_until_marker_is_valid(self):
        path = ROOT / "systemd" / "nativecontainers_network_authorization.py"
        spec = importlib.util.spec_from_file_location("authorization_helper", path)
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        with mock.patch.object(helper, "authorized", side_effect=[False, False, True]) as authorized:
            with mock.patch.object(helper.time, "sleep") as sleep:
                self.assertEqual(helper.main(), 0)
        self.assertEqual(authorized.call_count, 3)
        self.assertEqual(sleep.call_count, 2)
    def test_capacity_proof_prefers_virtio_console_and_falls_back(self):
        path = ROOT / "systemd" / "nativecontainers_grow_root.py"
        spec = importlib.util.spec_from_file_location("grow_root_helper_serial", path)
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        opened = []

        def open_console(candidate, _flags):
            opened.append(candidate)
            if candidate == "/dev/hvc0":
                raise OSError("missing")
            return 42

        with mock.patch.object(helper.os, "open", side_effect=open_console), mock.patch.object(
            helper.os,
            "write",
            return_value=len(helper.CAPACITY_PROOF_MARKER),
        ) as write, mock.patch.object(helper.os, "close") as close:
            helper.emit_capacity_proof()

        self.assertEqual(opened, ["/dev/hvc0", "/dev/ttyS0"])
        write.assert_called_once_with(42, helper.CAPACITY_PROOF_MARKER)
        close.assert_called_once_with(42)

    def test_root_capacity_service_grows_only_available_capacity_and_emits_proof(self):
        path = ROOT / "systemd" / "nativecontainers_grow_root.py"
        spec = importlib.util.spec_from_file_location("grow_root_helper", path)
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        outputs = iter(
            [
                "/dev/vda1",
                "vda",
                "1",
                "8000000000",
                "32000000000",
                "32000000000",
                "ext4",
                "8000000000",
                "32000000000",
            ]
        )
        with mock.patch.object(helper.os, "geteuid", return_value=0), mock.patch.object(
            helper,
            "output",
            side_effect=lambda _arguments: next(outputs),
        ), mock.patch.object(helper, "quiet") as quiet, mock.patch.object(
            helper,
            "emit_capacity_proof",
        ) as proof:
            self.assertEqual(helper.main(), 0)
        self.assertEqual(quiet.call_count, 2)
        proof.assert_called_once_with()

        outputs = iter(
            [
                "/dev/vda1",
                "vda",
                "1",
                "8000000000",
                "8000000000",
                "8000000000",
                "ext4",
                "8000000000",
                "8000000000",
            ]
        )
        with mock.patch.object(helper.os, "geteuid", return_value=0), mock.patch.object(
            helper,
            "output",
            side_effect=lambda _arguments: next(outputs),
        ), mock.patch.object(helper, "quiet") as quiet, mock.patch.object(
            helper,
            "emit_capacity_proof",
        ) as proof:
            self.assertEqual(helper.main(), 0)
        quiet.assert_not_called()
        proof.assert_not_called()


class VerifierProofTests(unittest.TestCase):
    def test_chromium_sandbox_status_requires_namespace_and_seccomp(self):
        status = b"""
        <html><body>Sandbox Status
        <table><tr><td>PID namespaces</td><td>Yes</td></tr>
        <tr><td>Seccomp-BPF sandbox</td><td>Yes</td></tr></table>
        </body></html>
        """
        with mock.patch.object(verifier, "_user_command", return_value=status):
            verifier._chromium_sandbox_enabled()
        with mock.patch.object(
            verifier,
            "_user_command",
            return_value=b"<html>Sandbox Status Seccomp-BPF sandbox No</html>",
        ):
            with self.assertRaises(verifier.VerifyFailure):
                verifier._chromium_sandbox_enabled()

    def test_physical_dns_binds_real_resolver_and_requires_counter(self):
        class Datagram:
            def __init__(self):
                self.destination = None

            def settimeout(self, _timeout):
                pass

            def setsockopt(self, *_arguments):
                pass

            def sendto(self, payload, destination):
                self.destination = destination
                self.payload = payload
                return len(payload)

            def recvfrom(self, _count):
                raise TimeoutError()

            def close(self):
                pass

        datagram = Datagram()
        snapshots = iter(
            [
                {"counters": {"physical_udp_drop": 10}},
                {"counters": {"physical_udp_drop": 11}},
            ]
        )
        with mock.patch.object(
            verifier,
            "_counter_snapshot",
            side_effect=lambda _path: next(snapshots),
        ), mock.patch.object(
            verifier,
            "_runtime",
            return_value={"uplink": "enp0s1"},
        ), mock.patch.object(
            verifier.socket,
            "socket",
            return_value=datagram,
        ):
            verifier._physical_dns("/run/nativecontainers/runtime.json")
        self.assertEqual(datagram.destination, ("1.1.1.1", 53))
        self.assertTrue(datagram.payload.endswith(b"\x00\x01\x00\x01"))


class StateMachineTests(unittest.TestCase):
    def test_destructive_quiesce_clears_services_secrets_and_uplink(self):
        machine = agent.LinuxBoxAgent.__new__(agent.LinuxBoxAgent)
        machine.state = "ready"
        machine.uplink = "enp0s1"
        machine.state_lock = threading.RLock()
        machine.quiesce_lock = threading.Lock()
        machine.active_operation = None
        machine.active_cancel = None
        calls = []
        machine._remove_runtime_secrets = lambda: calls.append("secrets")
        machine._baseline_active = lambda: True
        machine._cancel_active = lambda excluding=None: calls.append(("cancel", excluding))

        with mock.patch.object(agent, "run_quiet", side_effect=lambda argv, **kwargs: calls.append(tuple(argv)) or True), \
             mock.patch.object(agent.runtime, "_remove_markers", side_effect=lambda: calls.append("markers")), \
             mock.patch.object(agent.runtime, "_load_nftables", side_effect=lambda rules: calls.append("firewall")), \
             mock.patch.object(agent.runtime, "_baseline_nftables", return_value="baseline"), \
             mock.patch.object(agent, "service_active", return_value=False), \
             mock.patch.object(agent.os.path, "lexists", return_value=False):
            result = machine.quiesce("control_loss")

        self.assertEqual(result["state"], "quiesced")
        self.assertTrue(result["runtimeSecretsRemoved"])
        self.assertTrue(result["baselineActive"])
        self.assertEqual(machine.state, "quiesced")
        self.assertIsNone(machine.uplink)
        self.assertIn("markers", calls)
        self.assertIn("secrets", calls)
        self.assertIn("firewall", calls)


    def test_response_helpers_advertise_schema_two(self):
        request_id = "00112233-4455-6677-8899-aabbccddeeff"
        data = {"state": "ready", "sequence": 7}
        self.assertEqual(
            agent.success(request_id, data),
            {
                "schemaVersion": 2,
                "requestID": request_id,
                "ok": True,
                "data": data,
            },
        )

        error = agent.AgentFailure(
            "operation_timed_out",
            "guest exec did not complete",
            {"exitCode": -1},
        )
        self.assertEqual(
            agent.failure(request_id, error),
            {
                "schemaVersion": 2,
                "requestID": request_id,
                "ok": False,
                "error": {
                    "code": "operation_timed_out",
                    "message": "guest exec did not complete",
                    "details": {"exitCode": -1},
                },
            },
        )

    def test_exec_failure_preserves_bounded_stream_details(self):
        details = {
            "exitCode": -1,
            "stdoutBase64": base64.b64encode(b"partial").decode("ascii"),
            "stderrBase64": base64.b64encode(b"timed out").decode("ascii"),
        }
        response = agent.failure(
            "00112233-4455-6677-8899-aabbccddeeff",
            agent.AgentFailure(
                "operation_timed_out",
                "guest exec did not complete",
                details,
            ),
        )
        self.assertEqual(response["error"]["details"], details)
        unrelated = agent.AgentFailure(
            "configuration_invalid",
            "guest configuration failed",
            details,
        )
        self.assertIsNone(unrelated.details)

if __name__ == "__main__":
    unittest.main()
