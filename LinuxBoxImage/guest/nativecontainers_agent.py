#!/usr/bin/python3
import base64
import binascii
import collections
import fcntl
import json
import os
import queue
import resource
import selectors
import signal
import socket
import stat
import subprocess
import sys
import threading
import time
import uuid

import nativecontainers_runtime as runtime
import nativecontainers_verify as verifier

SCHEMA_VERSION = 2
PROTOCOL_VERSION = 2
VSOCK_PORT = 4050
STARTUP_STAGE_NONE = "none"
STARTUP_STAGE_MAIN_ENTERED = "main_entered"
STARTUP_STAGE_PROCESS_HARDENED = "process_hardened"
STARTUP_STAGE_IMAGE_IDENTITY_LOADED = "image_identity_loaded"
STARTUP_STAGE_BOOT_ID_LOADED = "boot_id_loaded"
STARTUP_STAGE_FAIL_CLOSED_INITIALIZED = "fail_closed_initialized"
STARTUP_STAGE_SERVE_ENTERED = "serve_entered"
STARTUP_STAGE_VSOCK_CONFIRMED = "vsock_capability_confirmed"
STARTUP_STAGE_LISTENER_CREATED = "listener_socket_created"
STARTUP_STAGE_BOUND_LISTENING = "bound_listening"
_startup_stage = STARTUP_STAGE_NONE
_STARTUP_MARKER_PATHS = ("/dev/hvc0", "/dev/ttyS0")


def _emit_startup_marker(marker):
    payload = (f"NATIVECONTAINERS_AGENT_STARTUP_{marker}\n").encode("ascii")
    for path in _STARTUP_MARKER_PATHS:
        descriptor = None
        written_successfully = False
        try:
            descriptor = os.open(path, os.O_WRONLY | os.O_NOCTTY | os.O_CLOEXEC)
            offset = 0
            while offset < len(payload):
                try:
                    written = os.write(descriptor, payload[offset:])
                except InterruptedError:
                    continue
                if written <= 0:
                    raise OSError("startup marker write made no progress")
                offset += written
            written_successfully = True
        except OSError:
            pass
        finally:
            if descriptor is not None:
                try:
                    os.close(descriptor)
                except OSError:
                    pass
        if written_successfully:
            return


def _mark_startup(stage):
    global _startup_stage
    _startup_stage = stage
    _emit_startup_marker(f"STAGE={stage}")


def _emit_startup_failure():
    _emit_startup_marker(f"FAILED stage={_startup_stage}")


MAX_FRAME_BYTES = 1024 * 1024
MAX_OUTPUT_BYTES = 256 * 1024
HEARTBEAT_TIMEOUT_SECONDS = 30
IMAGE_IDENTITY_PATH = "/usr/lib/nativecontainers/image.json"
AUTHORIZATION_SERVICE = "nativecontainers-network-authorization.service"
BASELINE_SERVICE = "nativecontainers-baseline-firewall.service"
NETWORKD_SERVICE = "systemd-networkd.service"
SING_BOX_SERVICE = "nativecontainers-sing-box.service"
SYSTEMCTL = "/usr/bin/systemctl"
SYSTEMD_RUN = "/usr/bin/systemd-run"
IP = "/usr/sbin/ip"

STATES = {
    "awaitingConfiguration",
    "authorizing",
    "healthy",
    "verifying",
    "ready",
    "quiescing",
    "quiesced",
    "failed",
}
OPERATIONS = {"hello", "configure", "ping", "status", "exec", "verify", "quiesce", "shutdown"}
ERROR_CODES = {
    "invalid_request",
    "protocol_mismatch",
    "invalid_state",
    "busy",
    "configuration_invalid",
    "not_ready",
    "exec_failed",
    "output_limit",
    "operation_timed_out",
    "internal_error",
}


class AgentFailure(Exception):
    def __init__(self, code, message, details=None):
        if code not in ERROR_CODES:
            code = "internal_error"
            details = None
        if details is not None and code not in {
            "exec_failed",
            "output_limit",
            "operation_timed_out",
        }:
            details = None
        self.code = code
        self.safe_message = message
        self.details = details
        super().__init__(message)


class DuplicateKeyFailure(ValueError):
    pass


def reject_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise DuplicateKeyFailure("duplicate JSON key")
        result[key] = value
    return result


def reject_constant(_value):
    raise ValueError("non-finite JSON number")


def exact_object(value, keys):
    if not isinstance(value, dict) or set(value) != set(keys):
        raise AgentFailure("invalid_request", "request object schema is invalid")
    return value


def canonical_uuid(value, name):
    if not isinstance(value, str):
        raise AgentFailure("invalid_request", f"{name} is invalid")
    try:
        parsed = uuid.UUID(value)
    except (ValueError, AttributeError) as exc:
        raise AgentFailure("invalid_request", f"{name} is invalid") from exc
    if str(parsed) != value:
        raise AgentFailure("invalid_request", f"{name} is invalid")
    return value


def canonical_base64(value, expected_bytes=None):
    if not isinstance(value, str) or not value.isascii():
        raise AgentFailure("invalid_request", "base64 value is invalid")
    try:
        decoded = base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise AgentFailure("invalid_request", "base64 value is invalid") from exc
    if base64.b64encode(decoded).decode("ascii") != value:
        raise AgentFailure("invalid_request", "base64 value is not canonical")
    if expected_bytes is not None and len(decoded) != expected_bytes:
        raise AgentFailure("invalid_request", "base64 value has an invalid length")
    return decoded


def validate_argv(value):
    if not isinstance(value, list) or not 1 <= len(value) <= 64:
        raise AgentFailure("invalid_request", "argv is invalid")
    total = 0
    for argument in value:
        if not isinstance(argument, str) or "\x00" in argument:
            raise AgentFailure("invalid_request", "argv is invalid")
        count = len(argument.encode("utf-8"))
        if not 1 <= count <= 4096:
            raise AgentFailure("invalid_request", "argv is invalid")
        total += count
    if total > 32 * 1024:
        raise AgentFailure("invalid_request", "argv is invalid")
    return list(value)


def parse_request(payload):
    try:
        value = json.loads(
            payload.decode("utf-8"),
            object_pairs_hook=reject_duplicates,
            parse_constant=reject_constant,
        )
    except (UnicodeDecodeError, ValueError, DuplicateKeyFailure) as exc:
        raise AgentFailure("invalid_request", "request JSON is invalid") from exc
    request = exact_object(value, {"schemaVersion", "requestID", "operation", "timeoutSeconds", "payload"})
    if type(request["schemaVersion"]) is not int or request["schemaVersion"] != SCHEMA_VERSION:
        raise AgentFailure("protocol_mismatch", "guest protocol schema is unsupported")
    request_id = canonical_uuid(request["requestID"], "requestID")
    operation = request["operation"]
    if not isinstance(operation, str) or operation not in OPERATIONS:
        raise AgentFailure("invalid_request", "operation is unknown")
    timeout = request["timeoutSeconds"]
    if type(timeout) is not int or not 1 <= timeout <= 3600:
        raise AgentFailure("invalid_request", "timeoutSeconds is invalid")
    parsed_payload = validate_operation_payload(operation, request["payload"])
    return {
        "requestID": request_id,
        "operation": operation,
        "timeoutSeconds": timeout,
        "payload": parsed_payload,
    }


def validate_operation_payload(operation, value):
    if operation == "hello":
        payload = exact_object(value, {"challenge"})
        return {"challenge": canonical_base64(payload["challenge"], 32)}
    if operation == "configure":
        if not isinstance(value, dict):
            raise AgentFailure("invalid_request", "configure payload is invalid")
        profile = value.get("profile")
        if profile == "standard":
            exact_object(value, {"profile"})
            return {"profile": "standard"}
        if profile == "residential":
            exact_object(value, {"profile", "configuration", "expectedProxyIP"})
            try:
                configuration = runtime.validate_payload(value["configuration"])
                expected_proxy_ip = runtime._global_ipv4(value["expectedProxyIP"])
            except runtime.RuntimeFailure as exc:
                raise AgentFailure("configuration_invalid", "residential configuration is invalid") from exc
            return {"profile": "residential", "configuration": configuration, "expectedProxyIP": expected_proxy_ip}
        raise AgentFailure("invalid_request", "configure profile is invalid")
    if operation == "hello":
        payload = exact_object(value, {"challenge"})
        return {"challenge": canonical_base64(payload["challenge"], 32)}
    if operation == "ping":
        payload = exact_object(value, {"sequence"})
        sequence = payload["sequence"]
        if type(sequence) is not int or not 0 <= sequence <= (1 << 64) - 1:
            raise AgentFailure("invalid_request", "ping sequence is invalid")
        return {"sequence": sequence}
    if operation in {"status", "shutdown"}:
        exact_object(value, set())
        return {}
    if operation == "exec":
        payload = exact_object(value, {"argv", "timeoutSeconds"})
        timeout = payload["timeoutSeconds"]
        if type(timeout) is not int or not 1 <= timeout <= 3600:
            raise AgentFailure("invalid_request", "exec timeoutSeconds is invalid")
        return {"argv": validate_argv(payload["argv"]), "timeoutSeconds": timeout}
    if operation == "verify":
        if not isinstance(value, dict):
            raise AgentFailure("invalid_request", "verify payload is invalid")
        if value.get("profile") == "standard":
            exact_object(value, {"profile"})
            return {"profile": "standard"}
        if value.get("profile") == "residential":
            exact_object(value, {"profile", "expectedProxyIP", "hostDirectIP"})
            try:
                expected = runtime._global_ipv4(value["expectedProxyIP"])
                direct = runtime._global_ipv4(value["hostDirectIP"])
            except runtime.RuntimeFailure as exc:
                raise AgentFailure("invalid_request", "verification identity is invalid") from exc
            return {"profile": "residential", "expectedProxyIP": expected, "hostDirectIP": direct}
        raise AgentFailure("invalid_request", "verify profile is invalid")
    if operation == "quiesce":
        payload = exact_object(value, {"reason"})
        if payload["reason"] not in {"pause", "refresh", "stop", "control_loss", "shutdown"}:
            raise AgentFailure("invalid_request", "quiesce reason is invalid")
        return {"reason": payload["reason"]}
    raise AgentFailure("invalid_request", "operation is unknown")


class FramedConnection:
    def __init__(self, connection):
        self.connection = connection
        self.write_lock = threading.Lock()
        self.closed = False
        self.close_lock = threading.Lock()

    def read_exact(self, count, deadline):
        data = bytearray(count)
        view = memoryview(data)
        offset = 0
        while offset < count:
            try:
                received = self.connection.recv_into(view[offset:], count - offset)
            except socket.timeout:
                if time.monotonic() >= deadline:
                    raise EOFError()
                continue
            if received == 0:
                raise EOFError()
            offset += received
        return bytes(data)

    def read_frame(self, deadline):
        header = self.read_exact(4, deadline)
        length = int.from_bytes(header, "big")
        if not 1 <= length <= MAX_FRAME_BYTES:
            raise AgentFailure("invalid_request", "frame length is invalid")
        return self.read_exact(length, deadline)

    def send(self, value):
        payload = json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
        if not 1 <= len(payload) <= MAX_FRAME_BYTES:
            raise AgentFailure("internal_error", "response frame is invalid")
        frame = len(payload).to_bytes(4, "big") + payload
        with self.write_lock:
            self.connection.sendall(frame)

    def close(self):
        with self.close_lock:
            if self.closed:
                return
            self.closed = True
            try:
                self.connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            self.connection.close()


def success(request_id, data):
    return {"schemaVersion": SCHEMA_VERSION, "requestID": request_id, "ok": True, "data": data}


def failure(request_id, error):
    value = {
        "schemaVersion": SCHEMA_VERSION,
        "requestID": request_id,
        "ok": False,
        "error": {"code": error.code, "message": error.safe_message},
    }
    if error.details is not None:
        value["error"]["details"] = error.details
    return value


def run_quiet(arguments, check=True, timeout=30):
    result = subprocess.run(
        arguments,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        close_fds=True,
        timeout=timeout,
        check=False,
        env={"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "LANG": "C.UTF-8"},
    )
    if check and result.returncode != 0:
        raise AgentFailure("internal_error", "guest service operation failed")
    return result.returncode == 0


def service_active(name):
    return run_quiet([SYSTEMCTL, "is-active", "--quiet", name], check=False, timeout=5)


class LinuxBoxAgent:
    def __init__(self):
        self.identity = self._load_identity()
        _mark_startup(STARTUP_STAGE_IMAGE_IDENTITY_LOADED)
        self.boot_id = self._boot_id()
        _mark_startup(STARTUP_STAGE_BOOT_ID_LOADED)
        self.state = "awaitingConfiguration"
        self.profile = None
        self.uplink = None
        self.state_lock = threading.RLock()
        self.operation_lock = threading.Lock()
        self.active_operation = None
        self.active_cancel = None
        self.quiesce_lock = threading.Lock()
        self.listener = None
        self._initialize_fail_closed()
        _mark_startup(STARTUP_STAGE_FAIL_CLOSED_INITIALIZED)

    def _load_identity(self):
        descriptor = os.open(IMAGE_IDENTITY_PATH, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
        try:
            metadata = os.fstat(descriptor)
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != 0 or metadata.st_size > 4096:
                raise AgentFailure("internal_error", "baked image identity is invalid")
            raw = os.read(descriptor, metadata.st_size + 1)
        finally:
            os.close(descriptor)
        try:
            value = json.loads(raw.decode("utf-8"), object_pairs_hook=reject_duplicates, parse_constant=reject_constant)
        except (ValueError, UnicodeDecodeError) as exc:
            raise AgentFailure("internal_error", "baked image identity is invalid") from exc
        value = exact_object(value, {"schema", "imageID", "imageBuildRevision", "protocol"})
        if value["schema"] != 1 or value["protocol"] != PROTOCOL_VERSION:
            raise AgentFailure("internal_error", "baked image identity is invalid")
        for key in ("imageID", "imageBuildRevision"):
            try:
                byte_count = len(value[key].encode("ascii", "strict")) if isinstance(value[key], str) else 0
            except UnicodeError as exc:
                raise AgentFailure("internal_error", "baked image identity is invalid") from exc
            if not 1 <= byte_count <= 128:
                raise AgentFailure("internal_error", "baked image identity is invalid")
        return value

    def _boot_id(self):
        with open("/proc/sys/kernel/random/boot_id", "r", encoding="ascii") as stream:
            return canonical_uuid(stream.read().strip(), "bootID")

    def _initialize_fail_closed(self):
        runtime._ensure_runtime_directory()
        runtime._disable_ipv6()
        runtime._remove_markers()
        self._remove_runtime_secrets()
        runtime._load_nftables(runtime._baseline_nftables())

    def serve(self):
        _mark_startup(STARTUP_STAGE_SERVE_ENTERED)
        if os.geteuid() != 0:
            raise AgentFailure("internal_error", "guest agent requires root")
        if not hasattr(socket, "AF_VSOCK"):
            raise AgentFailure("internal_error", "AF_VSOCK is unavailable")
        _mark_startup(STARTUP_STAGE_VSOCK_CONFIRMED)
        listener = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM | socket.SOCK_CLOEXEC)
        listener.set_inheritable(False)
        _mark_startup(STARTUP_STAGE_LISTENER_CREATED)
        listener.bind((socket.VMADDR_CID_ANY, VSOCK_PORT))
        listener.listen(1)
        _mark_startup(STARTUP_STAGE_BOUND_LISTENING)
        self.listener = listener
        while True:
            connection, peer = listener.accept()
            _emit_startup_marker("STAGE=connection_accepted")
            connection.set_inheritable(False)
            peer_cid = peer[0] if isinstance(peer, tuple) else None
            if peer_cid != socket.VMADDR_CID_HOST:
                connection.close()
                continue
            self._serve_connection(FramedConnection(connection))

    def _serve_connection(self, framed):
        hello_completed = False
        last_heartbeat = time.monotonic()
        workers = set()
        seen_request_ids = set()
        seen_request_order = collections.deque()
        try:
            framed.connection.settimeout(1.0)
            while True:
                if hello_completed and time.monotonic() - last_heartbeat >= HEARTBEAT_TIMEOUT_SECONDS:
                    self.control_loss()
                    raise EOFError()
                payload = framed.read_frame(
                    last_heartbeat + HEARTBEAT_TIMEOUT_SECONDS
                )
                request_id = None
                try:
                    request = parse_request(payload)
                    request_id = request["requestID"]
                    if request_id in seen_request_ids:
                        raise AgentFailure("invalid_request", "requestID was already used")
                    seen_request_ids.add(request_id)
                    seen_request_order.append(request_id)
                    if len(seen_request_order) > 4096:
                        seen_request_ids.remove(seen_request_order.popleft())
                    operation = request["operation"]
                    if not hello_completed:
                        if operation != "hello":
                            raise AgentFailure("invalid_state", "hello must be the first request")
                        framed.send(success(request_id, self.hello(request["payload"])))
                        hello_completed = True
                        last_heartbeat = time.monotonic()
                        continue
                    if operation == "hello":
                        raise AgentFailure("invalid_state", "hello is already complete")
                    if operation in {"ping", "status"}:
                        last_heartbeat = time.monotonic()
                        result = self.ping(request["payload"]) if operation == "ping" else self.status()
                        framed.send(success(request_id, result))
                        continue
                    target = (
                        self._run_preempting_operation
                        if operation in {"quiesce", "shutdown"}
                        else self._run_operation
                    )
                    worker = threading.Thread(
                        target=target,
                        args=(framed, request),
                        daemon=True,
                    )
                    workers.add(worker)
                    worker.start()
                    workers = {item for item in workers if item.is_alive()}
                except AgentFailure as exc:
                    if request_id is not None:
                        framed.send(failure(request_id, exc))
                    else:
                        raise
            if hello_completed:
                self.control_loss()
        finally:
            framed.close()

    def _run_operation(self, framed, request):
        request_id = request["requestID"]
        operation = request["operation"]
        acquired = self.operation_lock.acquire(blocking=False)
        if not acquired:
            try:
                framed.send(failure(request_id, AgentFailure("busy", "another guest operation is active")))
            except (OSError, AgentFailure):
                pass
            return
        cancel = threading.Event()
        with self.state_lock:
            self.active_operation = operation
            self.active_cancel = cancel
        try:
            result = self.dispatch(operation, request["payload"], request["timeoutSeconds"], cancel)
            framed.send(success(request_id, result))
        except AgentFailure as exc:
            try:
                framed.send(failure(request_id, exc))
            except (OSError, AgentFailure):
                pass
        except BaseException:
            self._set_failed()
            try:
                framed.send(failure(request_id, AgentFailure("internal_error", "guest operation failed")))
            except (OSError, AgentFailure):
                pass
        finally:
            with self.state_lock:
                self.active_operation = None
                self.active_cancel = None
            self.operation_lock.release()

    def control_loss(self):
        self._cancel_active()
        with self.state_lock:
            profile = self.profile
        if profile == "residential":
            try:
                self.quiesce("control_loss")
            except AgentFailure:
                pass

    def _run_preempting_operation(self, framed, request):
        request_id = request["requestID"]
        operation = request["operation"]
        with self.state_lock:
            active = self.active_operation
            if active is not None and active != "exec":
                try:
                    framed.send(
                        failure(
                            request_id,
                            AgentFailure("busy", "another guest operation is active"),
                        )
                    )
                except (OSError, AgentFailure):
                    pass
                return
            if self.active_cancel is not None:
                self.active_cancel.set()
        if not self.operation_lock.acquire(timeout=min(30, request["timeoutSeconds"])):
            try:
                framed.send(
                    failure(
                        request_id,
                        AgentFailure("operation_timed_out", "guest exec cancellation timed out"),
                    )
                )
            except (OSError, AgentFailure):
                pass
            return
        with self.state_lock:
            self.active_operation = operation
            self.active_cancel = None
        try:
            result = self.dispatch(
                operation,
                request["payload"],
                request["timeoutSeconds"],
                threading.Event(),
            )
            framed.send(success(request_id, result))
        except AgentFailure as exc:
            try:
                framed.send(failure(request_id, exc))
            except (OSError, AgentFailure):
                pass
        finally:
            with self.state_lock:
                self.active_operation = None
                self.active_cancel = None
            self.operation_lock.release()

    def dispatch(self, operation, payload, timeout_seconds, cancel):
        if operation == "configure":
            return self.configure(payload)
        if operation == "exec":
            return self.exec(payload, min(timeout_seconds, payload["timeoutSeconds"]), cancel)
        if operation == "verify":
            return self.verify(payload)
        if operation == "quiesce":
            return self.quiesce(payload["reason"])
        if operation == "shutdown":
            self._require_configured_or_quiesced(allow_awaiting=True)
            self.quiesce("shutdown")
            run_quiet([SYSTEMCTL, "poweroff", "--no-block"], check=False, timeout=5)
            return {"accepted": True}
        raise AgentFailure("invalid_request", "operation is invalid")

    def hello(self, payload):
        return {
            "challenge": base64.b64encode(payload["challenge"]).decode("ascii"),
            "protocol": PROTOCOL_VERSION,
            "imageID": self.identity["imageID"],
            "imageBuildRevision": self.identity["imageBuildRevision"],
            "bootID": self.boot_id,
            "state": self.state,
        }

    def ping(self, payload):
        with self.state_lock:
            return {"sequence": payload["sequence"], "bootID": self.boot_id, "state": self.state}

    def status(self):
        with self.state_lock:
            state = self.state
            uplink = self.uplink
            profile = self.profile
            active = self.active_operation
        result = {
            "profile": profile,
            "state": state,
            "bootID": self.boot_id,
            "uplink": uplink,
            "authorizationActive": os.path.isfile(runtime.CONFIGURED_PATH)
            and service_active(AUTHORIZATION_SERVICE),
            "networkdActive": service_active(NETWORKD_SERVICE),
            "singBoxActive": service_active(SING_BOX_SERVICE),
            "baselineActive": self._baseline_active(),
            "ready": state == "ready" and os.path.isfile(runtime.READY_PATH),
            "activeOperation": active,
        }
        return result

    def configure(self, payload):
        with self.state_lock:
            if self.state not in {"awaitingConfiguration", "quiesced"}:
                raise AgentFailure("invalid_state", "configure is unavailable in the current state")
            self.state = "authorizing"
            self.profile = payload["profile"]
        try:
            if payload["profile"] == "standard":
                uplink = runtime.configure_standard_network()
            else:
                uplink = runtime.discover_uplink()
            with self.state_lock:
                self.uplink = uplink
            if payload["profile"] == "standard":
                run_quiet([SYSTEMCTL, "start", NETWORKD_SERVICE], timeout=30)
                self._wait_for_ipv4(uplink, 30)
                with self.state_lock:
                    self.state = "healthy"
                return {"profile": "standard", "state": "authorizing", "uplink": uplink, "authorizationPublished": False}
            rules = runtime.render_nftables(uplink, configuration["endpoints"])
            sing_box = runtime.render_sing_box(uplink, configuration["credentials"], configuration["endpoints"])
            runtime._atomic_json(runtime.CONFIG_PATH, sing_box, 0o600)
            runtime._atomic_json(runtime.RUNTIME_PATH, {"schema": 1, "uplink": uplink, "sing_box_pid": 0}, 0o600)
            runtime._load_nftables(rules)
            runtime._atomic_bytes(runtime.CONFIGURED_PATH, b"authorized\n", 0o600)
            run_quiet([SYSTEMCTL, "start", AUTHORIZATION_SERVICE], timeout=15)
            run_quiet([SYSTEMCTL, "start", NETWORKD_SERVICE], timeout=30)
            self._wait_for_ipv4(uplink, 30)
            run_quiet([SYSTEMCTL, "start", SING_BOX_SERVICE], timeout=30)
            self._wait_for_sing_box(30)
            pid = self._service_main_pid(SING_BOX_SERVICE)
            runtime._atomic_json(runtime.RUNTIME_PATH, {"schema": 1, "uplink": uplink, "sing_box_pid": pid}, 0o600)
            runtime.probe()
            with self.state_lock:
                self.state = "healthy"
            return {"profile": "residential", "state": "authorizing", "uplink": uplink, "authorizationPublished": True}
        except BaseException as exc:
            try:
                if self.profile == "residential":
                    self.quiesce("refresh")
            except AgentFailure:
                pass
            if isinstance(exc, AgentFailure):
                raise exc
            raise AgentFailure("configuration_invalid", "guest network configuration failed") from exc

    def verify(self, payload):
        with self.state_lock:
            if self.state not in {"healthy", "ready"}:
                raise AgentFailure("invalid_state", "verify is unavailable in the current state")
            self.state = "verifying"
            profile = self.profile
        try:
            if profile == "standard":
                result = verifier.run_standard(self.uplink)
                with self.state_lock:
                    self.state = "ready"
                return {"egress": None, "doh": None, "checks": result["checks"]}
            result = verifier.run(runtime.RUNTIME_PATH)
            identity = result.get("egress", {})
            if identity.get("ip") != payload["expectedProxyIP"] or identity.get("ip") == payload["hostDirectIP"]:
                raise AgentFailure("configuration_invalid", "guest proxy identity is not isolated")
            verifier.publish(runtime.RUNTIME_PATH)
            doh = self._runtime_configuration()["endpoints"]["doh"]
            with self.state_lock:
                self.state = "ready"
            return {"egress": {"curlIP": identity["ip"], "chromiumIP": identity.get("chromium_ip", identity["ip"]), "isp": identity["isp"], "country": identity["country"]}, "doh": {"address": doh["address"], "serverName": doh["server_name"]}, "checks": result["checks"]}
        except BaseException as exc:
            try:
                if profile == "residential":
                    self.quiesce("refresh")
                else:
                    with self.state_lock:
                        self.state = "healthy"
            except AgentFailure:
                pass
            if isinstance(exc, AgentFailure):
                raise exc
            raise AgentFailure("configuration_invalid", "guest verification failed") from exc

    def exec(self, payload, timeout_seconds, cancel):
        with self.state_lock:
            if self.state != "ready":
                raise AgentFailure("not_ready", "guest exec requires ready state")
        unit = f"nativecontainers-exec-{uuid.uuid4()}"
        command = [
            SYSTEMD_RUN,
            "--quiet",
            "--wait",
            "--pipe",
            "--collect",
            f"--unit={unit}",
            "--service-type=exec",
            "--uid=1000",
            "--gid=1000",
            "--working-directory=/workspace",
            "--setenv=HOME=/workspace",
            "--setenv=XDG_CONFIG_HOME=/workspace/.config",
            "--setenv=XDG_CACHE_HOME=/workspace/.cache",
            "--setenv=XDG_DATA_HOME=/workspace/.local/share",
            "--setenv=PATH=/usr/local/bin:/usr/bin:/bin",
            "--property=NoNewPrivileges=yes",
            "--property=Delegate=no",
            "--property=KillMode=control-group",
            "--property=UMask=0077",
            "--property=CapabilityBoundingSet=",
            "--property=AmbientCapabilities=",
            "--property=SupplementaryGroups=",
            "--",
            *payload["argv"],
        ]
        process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            close_fds=True,
            start_new_session=True,
            env={"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "LANG": "C.UTF-8"},
        )
        process.stdin.close()
        for stream in (process.stdout, process.stderr):
            flags = fcntl.fcntl(stream.fileno(), fcntl.F_GETFL)
            fcntl.fcntl(stream.fileno(), fcntl.F_SETFL, flags | os.O_NONBLOCK)
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ, "stdout")
        selector.register(process.stderr, selectors.EVENT_READ, "stderr")
        buffers = {"stdout": bytearray(), "stderr": bytearray()}
        deadline = time.monotonic() + timeout_seconds
        failure_code = None
        try:
            while selector.get_map() or process.poll() is None:
                if cancel.is_set():
                    failure_code = "exec_failed"
                    break
                if time.monotonic() >= deadline:
                    failure_code = "operation_timed_out"
                    break
                for key, _mask in selector.select(timeout=0.1):
                    chunk = os.read(key.fileobj.fileno(), 65536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    target = buffers[key.data]
                    target.extend(chunk)
                    if len(target) > MAX_OUTPUT_BYTES:
                        del target[MAX_OUTPUT_BYTES:]
                        failure_code = "output_limit"
                        break
                if failure_code is not None:
                    break
            if failure_code is not None:
                self._kill_exec_unit(unit, process)
                return_code = process.poll()
                details = {
                    "exitCode": return_code if return_code is not None else -1,
                    "stdoutBase64": base64.b64encode(buffers["stdout"]).decode("ascii"),
                    "stderrBase64": base64.b64encode(buffers["stderr"]).decode("ascii"),
                }
                raise AgentFailure(
                    failure_code,
                    "guest exec did not complete",
                    details,
                )
            return_code = process.wait(timeout=5)
            return {
                "exitCode": return_code,
                "stdoutBase64": base64.b64encode(buffers["stdout"]).decode("ascii"),
                "stderrBase64": base64.b64encode(buffers["stderr"]).decode("ascii"),
            }
        finally:
            selector.close()
            if process.poll() is None:
                self._kill_exec_unit(unit, process)

    def quiesce(self, _reason):
        with self.quiesce_lock:
            with self.state_lock:
                if self.state == "quiesced":
                    return self._quiesce_result()
                self.state = "quiescing"
            self._cancel_active(excluding="quiesce")
            self._attempt([SYSTEMCTL, "stop", SING_BOX_SERVICE], 15)
            self._attempt([SYSTEMCTL, "stop", NETWORKD_SERVICE], 15)
            self._attempt([SYSTEMCTL, "stop", AUTHORIZATION_SERVICE], 15)
            with self.state_lock:
                uplink = self.uplink
            if uplink:
                self._attempt([IP, "address", "flush", "dev", uplink], 10)
                self._attempt([IP, "route", "flush", "dev", uplink], 10)
            try:
                runtime._remove_markers()
            except OSError:
                pass
            try:
                self._remove_runtime_secrets()
            except OSError:
                pass
            try:
                runtime._load_nftables(runtime._baseline_nftables())
            except (OSError, runtime.RuntimeFailure):
                pass
            with self.state_lock:
                self.uplink = None
                self.state = "quiesced"
            result = self._quiesce_result()
            if not all(
                result[key]
                for key in (
                    "singBoxStopped",
                    "networkClientsStopped",
                    "runtimeSecretsRemoved",
                    "baselineActive",
                )
            ):
                self._set_failed()
                raise AgentFailure(
                    "internal_error",
                    "destructive quiesce postconditions were not proven",
                )
            return result

    def _quiesce_result(self):
        return {
            "state": "quiesced",
            "singBoxStopped": not service_active(SING_BOX_SERVICE),
            "networkClientsStopped": not service_active(NETWORKD_SERVICE),
            "runtimeSecretsRemoved": not any(
                os.path.lexists(path)
                for path in (
                    runtime.CONFIG_PATH,
                    runtime.RUNTIME_PATH,
                    runtime.CONFIGURED_PATH,
                    runtime.READY_PATH,
                )
            ),
            "baselineActive": self._baseline_active(),
        }

    def _attempt(self, arguments, timeout):
        try:
            return run_quiet(arguments, check=False, timeout=timeout)
        except (OSError, subprocess.TimeoutExpired, AgentFailure):
            return False

    def _cancel_active(self, excluding=None):
        with self.state_lock:
            if self.active_operation != excluding and self.active_cancel is not None:
                self.active_cancel.set()

    def _set_failed(self):
        with self.state_lock:
            self.state = "failed"

    def _baseline_active(self):
        try:
            result = subprocess.run(
                [runtime.NFT, "list", "table", "inet", "proxy_vm"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                close_fds=True,
                timeout=5,
                check=False,
                text=True,
                env={
                    "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                    "LANG": "C.UTF-8",
                },
            )
        except (OSError, subprocess.TimeoutExpired):
            return False
        rules = result.stdout
        return (
            result.returncode == 0
            and service_active(BASELINE_SERVICE)
            and "chain input" in rules
            and "chain forward" in rules
            and "chain output" in rules
            and rules.count("policy drop") >= 3
        )

    def _remove_runtime_secrets(self):
        for path in (
            runtime.CONFIG_PATH,
            runtime.RUNTIME_PATH,
            runtime.CONFIGURED_PATH,
            runtime.READY_PATH,
            verifier.WATCHDOG_PATH,
        ):
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass

    def _wait_for_ipv4(self, uplink, timeout_seconds):
        deadline = time.monotonic() + timeout_seconds
        while time.monotonic() < deadline:
            result = subprocess.run(
                [IP, "-4", "-o", "address", "show", "dev", uplink, "scope", "global"],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                close_fds=True,
                check=False,
            )
            if result.returncode == 0 and result.stdout.strip():
                return
            time.sleep(0.25)
        raise AgentFailure("configuration_invalid", "DHCP authorization timed out")

    def _wait_for_sing_box(self, timeout_seconds):
        deadline = time.monotonic() + timeout_seconds
        while time.monotonic() < deadline:
            if service_active(SING_BOX_SERVICE) and os.path.isdir("/sys/class/net/sb-tun"):
                return
            time.sleep(0.25)
        raise AgentFailure("configuration_invalid", "residential tunnel startup timed out")

    def _service_main_pid(self, service):
        result = subprocess.run(
            [SYSTEMCTL, "show", "--property=MainPID", "--value", service],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            close_fds=True,
            check=False,
            text=True,
        )
        try:
            pid = int(result.stdout.strip())
        except ValueError as exc:
            raise AgentFailure("internal_error", "service identity is invalid") from exc
        if result.returncode != 0 or pid <= 1:
            raise AgentFailure("internal_error", "service identity is invalid")
        return pid

    def _runtime_configuration(self):
        descriptor = os.open(runtime.CONFIG_PATH, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
        try:
            metadata = os.fstat(descriptor)
            raw = os.read(descriptor, metadata.st_size + 1)
        finally:
            os.close(descriptor)
        sing_box = json.loads(raw.decode("utf-8"), object_pairs_hook=reject_duplicates)
        runtime_record = verifier._runtime(runtime.RUNTIME_PATH)
        return {
            "endpoints": {
                "doh": {
                    "address": sing_box["dns"]["servers"][0]["server"],
                    "server_name": sing_box["dns"]["servers"][0]["tls"]["server_name"],
                },
                "uplink": runtime_record["uplink"],
            }
        }

    def _kill_exec_unit(self, unit, process):
        run_quiet([SYSTEMCTL, "kill", "--kill-whom=all", "--signal=KILL", f"{unit}.service"], check=False, timeout=5)
        run_quiet([SYSTEMCTL, "stop", f"{unit}.service"], check=False, timeout=5)
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass

    def _require_configured_or_quiesced(self, allow_awaiting=False):
        with self.state_lock:
            allowed = {"authorizing", "healthy", "verifying", "ready", "quiescing", "quiesced", "failed"}
            if allow_awaiting:
                allowed.add("awaitingConfiguration")
            if self.state not in allowed:
                raise AgentFailure("invalid_state", "operation is unavailable in the current state")


def harden_process():
    os.umask(0o077)
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    signal.signal(signal.SIGPIPE, signal.SIG_IGN)


def main():
    _mark_startup(STARTUP_STAGE_MAIN_ENTERED)
    try:
        harden_process()
        _mark_startup(STARTUP_STAGE_PROCESS_HARDENED)
        LinuxBoxAgent().serve()
    except BaseException:
        _emit_startup_failure()
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
