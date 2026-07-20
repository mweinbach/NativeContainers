import argparse
import ipaddress
import html
import json
import os
import re
import resource
import secrets
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time

RUNTIME_DIR = "/run/nativecontainers"
RUNTIME_PATH = f"{RUNTIME_DIR}/runtime.json"
CONFIG_PATH = f"{RUNTIME_DIR}/sing-box.json"
CONFIGURED_PATH = f"{RUNTIME_DIR}/configured"
READY_PATH = f"{RUNTIME_DIR}/ready"
WATCHDOG_PATH = f"{RUNTIME_DIR}/watchdog.json"
NFT = "/usr/sbin/nft"
DIG = "/usr/bin/dig"
CURL = "/usr/bin/curl"
PYTHON = "/usr/bin/python3"
SYSTEMD_RUN = "/usr/bin/systemd-run"
CHROMIUM = "/usr/bin/chromium"
SELF = "/usr/local/libexec/nativecontainers_verify.py"
COUNTER_NAMES = {
    "physical_ipv4_drop",
    "physical_udp_drop",
    "ipv6_drop",
    "unprivileged_gateway_drop",
    "host_route_drop",
}
IFNAME_RE = re.compile(r"^[A-Za-z0-9_.-]{1,15}$")
SYSTEMCTL = "/usr/bin/systemctl"
TOKEN_RE = re.compile(r"^[0-9a-f]{32}$")


class VerifyFailure(Exception):
    pass
class ChromiumSandboxFailure(VerifyFailure):
    pass




def _reject_duplicates(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise VerifyFailure("duplicate json key")
        value[key] = item
    return value


def _read_bounded_json_stream(stream, limit=65536):
    raw = stream.read(limit + 1)
    if len(raw) > limit:
        raise VerifyFailure("json input too large")
    try:
        value = json.loads(raw, object_pairs_hook=_reject_duplicates)
    except (UnicodeDecodeError, ValueError, VerifyFailure) as exc:
        raise VerifyFailure("invalid json") from exc
    return value


def _secure_json(path, mode=0o600, owner=0):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        current = os.fstat(descriptor)
        if (
            not stat.S_ISREG(current.st_mode)
            or current.st_uid != owner
            or stat.S_IMODE(current.st_mode) != mode
            or current.st_nlink != 1
        ):
            raise VerifyFailure("insecure runtime json")
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            return _read_bounded_json_stream(stream)
    finally:
        os.close(descriptor)


def _atomic_bytes(path, data, mode):
    descriptor, temporary = tempfile.mkstemp(prefix=".proxy-verify-", dir=RUNTIME_DIR)
    try:
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, "wb", closefd=True) as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory_fd = os.open(RUNTIME_DIR, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise
    current = os.stat(path, follow_symlinks=False)
    if current.st_uid != 0 or stat.S_IMODE(current.st_mode) != mode:
        raise VerifyFailure("runtime file security is invalid")


def _atomic_json(path, value, mode=0o600):
    _atomic_bytes(
        path,
        json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8") + b"\n",
        mode,
    )


def _remove_ready():
    try:
        os.unlink(READY_PATH)
    except FileNotFoundError:
        pass


def _require_root():
    if os.geteuid() != 0:
        raise VerifyFailure("root operation required")


def _ifname(value):
    if not isinstance(value, str) or IFNAME_RE.fullmatch(value) is None:
        raise VerifyFailure("invalid interface")
    return value


def _proc_starttime(pid):
    try:
        text = open(f"/proc/{pid}/stat", "r", encoding="utf-8").read(8192)
    except OSError:
        return None
    closing = text.rfind(")")
    if closing < 0:
        return None
    fields = text[closing + 2 :].split()
    if len(fields) <= 19 or not fields[19].isdigit():
        return None
    return fields[19]


def _proc_comm(pid):
    try:
        value = open(f"/proc/{pid}/comm", "r", encoding="utf-8").read(128).strip()
    except OSError:
        return None
    return value


def _runtime(runtime_path):
    if runtime_path != RUNTIME_PATH:
        raise VerifyFailure("unexpected runtime path")
    value = _secure_json(runtime_path)
    if not isinstance(value, dict) or set(value) != {"schema", "uplink", "sing_box_pid"}:
        raise VerifyFailure("invalid runtime schema")
    pid = value["sing_box_pid"]
    if type(value["schema"]) is not int or value["schema"] != 1 or type(pid) is not int or pid <= 1:
        raise VerifyFailure("invalid runtime schema")
    uplink = _ifname(value["uplink"])
    if _proc_comm(pid) != "sing-box" or _proc_starttime(pid) is None:
        raise VerifyFailure("sing-box process is not live")
    return {"schema": 1, "uplink": uplink, "sing_box_pid": pid}


def _configured_required():
    descriptor = os.open(CONFIGURED_PATH, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        current = os.fstat(descriptor)
        value = os.read(descriptor, 64)
    finally:
        os.close(descriptor)
    if (
        not stat.S_ISREG(current.st_mode)
        or current.st_uid != 0
        or stat.S_IMODE(current.st_mode) != 0o600
        or current.st_nlink != 1
        or value != b"authorized\n"
    ):
        raise VerifyFailure("configured marker is invalid")


def _nft_counter_values():
    result = subprocess.run(
        [NFT, "-j", "list", "table", "inet", "proxy_vm"],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    if result.returncode != 0 or len(result.stdout) > 1048576:
        raise VerifyFailure("nftables counters are unavailable")
    try:
        value = json.loads(result.stdout)
    except (UnicodeDecodeError, ValueError) as exc:
        raise VerifyFailure("invalid nftables json") from exc
    objects = value.get("nftables") if isinstance(value, dict) else None
    if not isinstance(objects, list):
        raise VerifyFailure("invalid nftables json")
    found = {}
    for item in objects:
        counter = item.get("counter") if isinstance(item, dict) else None
        if not isinstance(counter, dict) or counter.get("table") != "proxy_vm" or counter.get("family") != "inet":
            continue
        name = counter.get("name")
        packets = counter.get("packets")
        if name in found or name not in COUNTER_NAMES or type(packets) is not int or packets < 0:
            raise VerifyFailure("invalid named counter")
        found[name] = packets
    if set(found) != COUNTER_NAMES:
        raise VerifyFailure("named counters are incomplete")
    return found


def _counter_snapshot(runtime_path):
    runtime = _runtime(runtime_path)
    return {
        "schema": 1,
        "uplink": runtime["uplink"],
        "counters": _nft_counter_values(),
    }



def run_standard(uplink):
    """Verify ordinary DHCP/DNS readiness without residential evidence."""
    interface = _ifname(uplink)
    checks = []
    networkd = subprocess.run(
        [SYSTEMCTL, "is-active", "--quiet", "systemd-networkd.service"],
        check=False,
    ).returncode == 0
    checks.append({"name": "networkd_active", "ok": networkd})
    try:
        addresses = socket.if_nameindex()
        link_present = any(name == interface for _, name in addresses)
    except OSError:
        link_present = False
    checks.append({"name": "uplink_present", "ok": link_present})
    try:
        routes = subprocess.run(
            ["/usr/sbin/ip", "-4", "route", "show", "dev", interface],
            check=False, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            text=True, timeout=5,
        ).stdout
        has_default = any(line.startswith("default ") for line in routes.splitlines())
    except (OSError, subprocess.TimeoutExpired):
        has_default = False
    checks.append({"name": "dhcp_default_route", "ok": has_default})
    try:
        socket.getaddrinfo("debian.org", 443, socket.AF_INET, socket.SOCK_STREAM)
        dns = True
    except OSError:
        dns = False
    checks.append({"name": "dns_resolution", "ok": dns})
    checks.append({"name": "ordinary_ipv4_egress", "ok": networkd and has_default})
    return {"checks": checks}
def _emit(value):
    sys.stdout.write(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")


def _status_fields():
    try:
        lines = open("/proc/self/status", "r", encoding="utf-8").read().splitlines()
    except OSError as exc:
        raise VerifyFailure("process status is unavailable") from exc
    fields = {}
    for line in lines:
        if ":" in line:
            key, value = line.split(":", 1)
            fields[key] = value.strip()
    return fields


def _no_new_privileges():
    return _status_fields().get("NoNewPrivs") == "1"


def _capabilities_absent():
    value = _status_fields().get("CapEff")
    try:
        effective = int(value, 16)
    except (TypeError, ValueError):
        return False
    return effective == 0


def _supplementary_groups_absent():
    return os.getgroups() == []


def workspace():
    if os.geteuid() != 1000 or os.getegid() != 1000 or not _no_new_privileges():
        raise VerifyFailure("workspace privilege boundary is invalid")
    probe_path = f"/workspace/.proxy-vm-write-probe-{os.getpid()}"
    descriptor = os.open(probe_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    os.close(descriptor)
    os.unlink(probe_path)
    for path in ("/workspace/.config", "/workspace/.cache", "/workspace/chromium-profile"):
        try:
            os.mkdir(path, 0o700)
        except FileExistsError:
            pass
        current = os.stat(path, follow_symlinks=False)
        if (
            not stat.S_ISDIR(current.st_mode)
            or current.st_uid != 1000
            or current.st_gid != 1000
            or not os.access(path, os.W_OK | os.X_OK)
        ):
            raise VerifyFailure("workspace path is invalid")
    result = {"schema": 1, "no_new_privs": True}
    _emit(result)
    return result


def _command_fails(arguments, stdin=None, timeout=8):
    try:
        result = subprocess.run(
            arguments,
            input=stdin,
            check=False,
            stdin=subprocess.DEVNULL if stdin is None else None,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return True
    return result.returncode != 0


def _secrets_unreadable():
    try:
        descriptor = os.open(RUNTIME_DIR, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except (FileNotFoundError, PermissionError):
        descriptor = None
    if descriptor is not None:
        os.close(descriptor)
        return False
    for path in (CONFIG_PATH, RUNTIME_PATH, WATCHDOG_PATH):
        try:
            descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        except (FileNotFoundError, PermissionError):
            continue
        else:
            os.close(descriptor)
            return False
    return True


def _nftables_unmodifiable():
    if not _command_fails([NFT, "list", "ruleset"], timeout=5):
        return False
    transaction = b"add table inet pv_unprivileged_probe\ndelete table inet pv_unprivileged_probe\n"
    return _command_fails([NFT, "-f", "-"], stdin=transaction, timeout=5)


def _gateway_connection_blocked(endpoint, port):
    connection = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    connection.settimeout(5)
    try:
        connection.connect((endpoint, port))
    except OSError:
        return True
    finally:
        connection.close()
    return False


def _bound_user_curl_blocked(uplink):
    return _command_fails(
        [
            CURL,
            "-q",
            "--fail",
            "--silent",
            "--interface",
            uplink,
            "--connect-timeout",
            "3",
            "--max-time",
            "6",
            "--proto",
            "=https",
            "https://198.51.100.1/",
        ],
        timeout=8,
    )


def unprivileged(endpoint, port, uplink):
    if os.geteuid() != 1000 or os.getegid() != 1000 or not _no_new_privileges():
        raise VerifyFailure("unprivileged boundary is invalid")
    try:
        address = ipaddress.IPv4Address(endpoint)
    except ValueError as exc:
        raise VerifyFailure("invalid gateway endpoint") from exc
    if not address.is_global or type(port) is not int or port != 7000:
        raise VerifyFailure("invalid gateway endpoint")
    interface = _ifname(uplink)
    for path in ("/workspace/.config", "/workspace/.cache", "/workspace/chromium-profile"):
        current = os.stat(path, follow_symlinks=False)
        if not stat.S_ISDIR(current.st_mode) or current.st_uid != 1000 or not os.access(path, os.W_OK | os.X_OK):
            raise VerifyFailure("workspace path is invalid")
    checks = {
        "unprivileged_gateway_blocked": _gateway_connection_blocked(str(address), port),
        "unprivileged_caps_absent": _capabilities_absent(),
        "supplementary_groups_absent": _supplementary_groups_absent(),
        "secrets_unreadable": _secrets_unreadable(),
        "nftables_unmodifiable": _nftables_unmodifiable(),
        "physical_interface_blocked": _bound_user_curl_blocked(interface),
    }
    if not all(checks.values()):
        raise VerifyFailure("unprivileged security predicate failed")
    result = {"schema": 1, "checks": checks}
    _emit(result)
    return result


def counters(runtime_path):
    _require_root()
    result = _counter_snapshot(runtime_path)
    _emit(result)
    return result


def quiesce(runtime_path):
    _require_root()
    _runtime(runtime_path)
    _configured_required()
    _remove_ready()
    result = {"schema": 1, "quiesced": True}
    _emit(result)
    return result
def _user_command(arguments, timeout):
    unit = f"nativecontainers-verify-{secrets.token_hex(12)}"
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
        *arguments,
    ]
    try:
        result = subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            close_fds=True,
            check=False,
            timeout=timeout,
            env={
                "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                "LANG": "C.UTF-8",
            },
        )
    except subprocess.TimeoutExpired as exc:
        subprocess.run(
            ["/usr/bin/systemctl", "kill", "--kill-whom=all", "--signal=KILL", f"{unit}.service"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            close_fds=True,
            check=False,
            timeout=5,
        )
        raise VerifyFailure("unprivileged verifier timed out") from exc
    if result.returncode != 0 or len(result.stdout) > 1024 * 1024:
        raise VerifyFailure("unprivileged verifier failed")
    return result.stdout


def _json_output(raw):
    try:
        return json.loads(raw, object_pairs_hook=_reject_duplicates)
    except (UnicodeDecodeError, ValueError, VerifyFailure) as exc:
        raise VerifyFailure("invalid unprivileged verifier output") from exc


def _proxy_endpoint():
    value = _secure_json(CONFIG_PATH)
    try:
        endpoint = str(ipaddress.IPv4Address(value["outbounds"][0]["server"]))
        port = value["outbounds"][0]["server_port"]
    except (KeyError, IndexError, TypeError, ValueError) as exc:
        raise VerifyFailure("proxy endpoint is unavailable") from exc
    if not ipaddress.IPv4Address(endpoint).is_global or type(port) is not int or port != 7000:
        raise VerifyFailure("proxy endpoint is invalid")
    return endpoint, port


def _prepare_user_workspace():
    value = _json_output(_user_command([PYTHON, SELF, "workspace"], 15))
    if value != {"schema": 1, "no_new_privs": True}:
        raise VerifyFailure("workspace privilege boundary failed")


def _unprivileged_boundary(endpoint, port, uplink, runtime_path):
    before = _counter_snapshot(runtime_path)["counters"]["unprivileged_gateway_drop"]
    value = _json_output(
        _user_command(
            [
                PYTHON,
                SELF,
                "unprivileged",
                "--endpoint",
                endpoint,
                "--port",
                str(port),
                "--uplink",
                uplink,
            ],
            30,
        )
    )
    after = _counter_snapshot(runtime_path)["counters"]["unprivileged_gateway_drop"]
    required = {
        "unprivileged_gateway_blocked",
        "unprivileged_caps_absent",
        "supplementary_groups_absent",
        "secrets_unreadable",
        "nftables_unmodifiable",
        "physical_interface_blocked",
    }
    checks = value.get("checks") if isinstance(value, dict) else None
    if (
        not isinstance(checks, dict)
        or set(checks) != required
        or not all(item is True for item in checks.values())
        or after <= before
    ):
        raise VerifyFailure("unprivileged security predicate failed")
    return checks


def _identity_object(value):
    try:
        proxy = value["proxy"]
        isp = value["isp"]
        country = value["country"]
        address = ipaddress.IPv4Address(proxy["ip"])
        isp_name = isp["isp"]
        country_name = country["name"]
    except (KeyError, TypeError, ValueError) as exc:
        raise VerifyFailure("invalid proxied identity response") from exc
    if (
        not address.is_global
        or not isinstance(isp_name, str)
        or not isp_name
        or not isinstance(country_name, str)
        or not country_name
    ):
        raise VerifyFailure("invalid proxied identity response")
    return {"ip": str(address), "isp": isp_name, "country": country_name}


def _user_curl_identity():
    raw = _user_command(
        [
            CURL,
            "-q",
            "--fail",
            "--silent",
            "--connect-timeout",
            "5",
            "--max-time",
            "20",
            "--proto",
            "=https",
            "https://ip.decodo.com/json",
        ],
        25,
    )
    return _identity_object(_json_output(raw))


def _chromium_sandbox_enabled():
    raw = _user_command(
        [
            CHROMIUM,
            "--headless",
            "--disable-gpu",
            "--no-first-run",
            "--user-data-dir=/workspace/chromium-profile",
            "--dump-dom",
            "chrome://sandbox",
        ],
        60,
    )
    try:
        text = html.unescape(raw.decode("utf-8", "strict"))
    except UnicodeDecodeError as exc:
        raise ChromiumSandboxFailure("Chromium sandbox status is invalid") from exc
    status = re.sub(r"<[^>]+>", " ", text)
    seccomp = re.search(
        r"Seccomp-BPF(?: sandbox)?\s+Yes",
        status,
        flags=re.IGNORECASE,
    )
    namespace = re.search(
        r"(?:SUID Sandbox|PID namespaces|User namespaces|Namespace Sandbox)\s+Yes",
        status,
        flags=re.IGNORECASE,
    )
    if "sandbox" not in status.lower() or seccomp is None or namespace is None:
        raise ChromiumSandboxFailure("Chromium sandbox is unavailable")


def _user_chromium_identity():
    raw = _user_command(
        [
            CHROMIUM,
            "--headless",
            "--disable-gpu",
            "--no-first-run",
            "--user-data-dir=/workspace/chromium-profile",
            "--dump-dom",
            "https://ip.decodo.com/json",
        ],
        60,
    )
    try:
        text = raw.decode("utf-8", "strict")
    except UnicodeDecodeError as exc:
        raise VerifyFailure("invalid Chromium identity response") from exc
    match = re.search(r"<pre[^>]*>(.*?)</pre>", text, flags=re.IGNORECASE | re.DOTALL)
    payload = html.unescape(match.group(1)) if match else html.unescape(re.sub(r"<[^>]+>", "", text))
    try:
        value = json.loads(payload.strip(), object_pairs_hook=_reject_duplicates)
    except (ValueError, VerifyFailure) as exc:
        raise VerifyFailure("invalid Chromium identity response") from exc
    return _identity_object(value)


def _curl_identity(expect_success=True, max_time=15):
    try:
        result = subprocess.run(
            [
                CURL,
                "-q",
                "--fail",
                "--silent",
                "--connect-timeout",
                str(min(5, max_time)),
                "--max-time",
                str(max_time),
                "--proto",
                "=https",
                "https://ip.decodo.com/json",
            ],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=max_time + 3,
        )
    except subprocess.TimeoutExpired:
        result = None
    if not expect_success:
        if result is None or result.returncode != 0:
            return None
        raise VerifyFailure("proxied request survived proxy failure")
    if result is None or result.returncode != 0 or len(result.stdout) > 65536:
        raise VerifyFailure("proxied curl failed")
    return _identity_object(_json_output(result.stdout))


def _proxied_dns():
    try:
        result = subprocess.run(
            [DIG, "+time=10", "+tries=1", "+short", "example.com", "A"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=15,
        )
    except subprocess.TimeoutExpired as exc:
        raise VerifyFailure("proxied dns timed out") from exc
    if result.returncode != 0 or len(result.stdout) > 65536:
        raise VerifyFailure("proxied dns failed")
    for line in result.stdout.decode("utf-8", "strict").splitlines():
        try:
            address = ipaddress.IPv4Address(line.strip())
        except ValueError:
            continue
        if address.is_global:
            return True
    raise VerifyFailure("proxied dns returned no global address")


def _bind_socket(sock, uplink):
    if not hasattr(socket, "SO_BINDTODEVICE"):
        raise VerifyFailure("SO_BINDTODEVICE is unavailable")
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, uplink.encode("ascii") + b"\x00")


def _physical_tcp(runtime_path):
    before = _counter_snapshot(runtime_path)["counters"]["physical_ipv4_drop"]
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(4)
    try:
        _bind_socket(sock, _runtime(runtime_path)["uplink"])
        try:
            sock.connect(("198.51.100.1", 443))
        except OSError:
            pass
        else:
            raise VerifyFailure("physical tcp path was reachable")
    finally:
        sock.close()
    after = _counter_snapshot(runtime_path)["counters"]["physical_ipv4_drop"]
    if after <= before:
        raise VerifyFailure("physical tcp counter did not increase")


def _physical_udp(runtime_path, port):
    before = _counter_snapshot(runtime_path)["counters"]["physical_udp_drop"]
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(2)
    try:
        _bind_socket(sock, _runtime(runtime_path)["uplink"])
        try:
            sock.sendto(b"proxy-vm-leak-probe", ("198.51.100.1", port))
        except OSError:
            pass
        try:
            sock.recvfrom(64)
        except OSError:
            pass
        else:
            raise VerifyFailure("physical udp path returned data")
    finally:
        sock.close()
    after = _counter_snapshot(runtime_path)["counters"]["physical_udp_drop"]
    if after <= before:
        raise VerifyFailure("physical udp counter did not increase")


def _physical_dns(runtime_path):
    before = _counter_snapshot(runtime_path)["counters"]["physical_udp_drop"]
    query = (
        b"\x4e\x43\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00"
        b"\x07example\x03com\x00\x00\x01\x00\x01"
    )
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(2)
    try:
        _bind_socket(sock, _runtime(runtime_path)["uplink"])
        try:
            sock.sendto(query, ("1.1.1.1", 53))
        except OSError:
            pass
        try:
            sock.recvfrom(512)
        except OSError:
            pass
        else:
            raise VerifyFailure("physical DNS returned data")
    finally:
        sock.close()
    after = _counter_snapshot(runtime_path)["counters"]["physical_udp_drop"]
    if after <= before:
        raise VerifyFailure("physical DNS counter did not increase")


def _ipv6_blocked(runtime_path):
    before = _counter_snapshot(runtime_path)["counters"]["ipv6_drop"]
    failed = False
    try:
        sock = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
        sock.settimeout(3)
        try:
            sock.connect(("2001:db8::1", 443))
        except OSError:
            failed = True
        else:
            failed = False
        finally:
            sock.close()
    except OSError:
        failed = True
    if not failed:
        raise VerifyFailure("ipv6 path was reachable")
    after = _counter_snapshot(runtime_path)["counters"]["ipv6_drop"]
    if after > before:
        return
    try:
        all_disabled = open("/proc/sys/net/ipv6/conf/all/disable_ipv6", "r", encoding="ascii").read().strip() == "1"
        default_disabled = open("/proc/sys/net/ipv6/conf/default/disable_ipv6", "r", encoding="ascii").read().strip() == "1"
    except OSError as exc:
        raise VerifyFailure("ipv6 disable state is unavailable") from exc
    if not all_disabled or not default_disabled:
        raise VerifyFailure("ipv6 was neither disabled nor counted")


def _host_route_blocked(runtime_path):
    before = _counter_snapshot(runtime_path)["counters"]["host_route_drop"]
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(4)
    try:
        _bind_socket(sock, _runtime(runtime_path)["uplink"])
        try:
            sock.connect(("169.254.169.254", 80))
        except OSError:
            pass
        else:
            raise VerifyFailure("host metadata route was reachable")
    finally:
        sock.close()
    after = _counter_snapshot(runtime_path)["counters"]["host_route_drop"]
    if after <= before:
        raise VerifyFailure("host route counter did not increase")


def _watchdog_metadata():
    value = _secure_json(WATCHDOG_PATH)
    if not isinstance(value, dict) or set(value) != {"schema", "pid", "starttime", "token", "sing_box_pid"}:
        raise VerifyFailure("invalid watchdog metadata")
    if (
        type(value["schema"]) is not int
        or value["schema"] != 1
        or type(value["pid"]) is not int
        or value["pid"] <= 1
        or type(value["sing_box_pid"]) is not int
        or value["sing_box_pid"] <= 1
        or not isinstance(value["starttime"], str)
        or TOKEN_RE.fullmatch(value["token"]) is None
    ):
        raise VerifyFailure("invalid watchdog metadata")
    return value


def _wait_watchdog(token, pid, sing_box_pid):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        try:
            metadata = _watchdog_metadata()
        except (FileNotFoundError, VerifyFailure):
            time.sleep(0.05)
            continue
        if (
            metadata["token"] == token
            and metadata["pid"] == pid
            and metadata["sing_box_pid"] == sing_box_pid
            and _proc_starttime(pid) == metadata["starttime"]
        ):
            return metadata
        raise VerifyFailure("watchdog identity did not match")
    raise VerifyFailure("watchdog did not arm")


def _spawn_watchdog(runtime_path, runtime):
    token = secrets.token_hex(16)
    deadline = int(time.time()) + 8
    process = subprocess.Popen(
        [
            PYTHON,
            SELF,
            "watchdog",
            "--runtime",
            runtime_path,
            "--token",
            token,
            "--deadline",
            str(deadline),
        ],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
        close_fds=True,
    )
    _wait_watchdog(token, process.pid, runtime["sing_box_pid"])
    return process


def _wait_process_gone(pid, starttime, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        current = _proc_starttime(pid)
        if current is None or current != starttime:
            try:
                os.waitpid(pid, os.WNOHANG)
            except ChildProcessError:
                pass
            return True
        try:
            os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            pass
        time.sleep(0.05)
    return False


def cancel_watchdog(runtime_path):
    _require_root()
    _runtime(runtime_path)
    try:
        metadata = _watchdog_metadata()
    except FileNotFoundError:
        return {"schema": 1, "cancelled": False}
    current = _proc_starttime(metadata["pid"])
    if current is not None and current != metadata["starttime"]:
        raise VerifyFailure("watchdog pid identity was reused")
    if current == metadata["starttime"]:
        os.kill(metadata["pid"], signal.SIGTERM)
        if not _wait_process_gone(metadata["pid"], metadata["starttime"], 2):
            current = _proc_starttime(metadata["pid"])
            if current != metadata["starttime"]:
                raise VerifyFailure("watchdog identity changed")
            os.kill(metadata["pid"], signal.SIGKILL)
            if not _wait_process_gone(metadata["pid"], metadata["starttime"], 2):
                raise VerifyFailure("watchdog did not terminate")
    os.unlink(WATCHDOG_PATH)
    return {"schema": 1, "cancelled": True}


def _resume_and_probe(runtime_path):
    runtime = _runtime(runtime_path)
    os.kill(runtime["sing_box_pid"], signal.SIGCONT)
    deadline = time.monotonic() + 15
    last_failure = None
    while time.monotonic() < deadline:
        try:
            return _curl_identity(expect_success=True)
        except VerifyFailure as exc:
            last_failure = exc
            time.sleep(0.25)
    raise VerifyFailure("sing-box recovery failed") from last_failure


def run(runtime_path):
    _require_root()
    runtime = None
    identity = None
    user_identity = None
    chromium_identity = None
    recovered_identity = None
    watchdog_process = None
    watchdog_recovered = False
    user_checks = {}
    failure = None
    try:
        runtime = _runtime(runtime_path)
        _configured_required()
        if os.path.exists(READY_PATH):
            raise VerifyFailure("readiness must be absent during verification")
        endpoint, port = _proxy_endpoint()
        _prepare_user_workspace()
        user_checks = _unprivileged_boundary(endpoint, port, runtime["uplink"], runtime_path)
        identity = _curl_identity(expect_success=True)
        user_identity = _user_curl_identity()
        _chromium_sandbox_enabled()
        chromium_identity = _user_chromium_identity()
        if identity != user_identity or identity != chromium_identity:
            raise VerifyFailure("proxied workload identities differ")
        _proxied_dns()
        _physical_tcp(runtime_path)
        _physical_udp(runtime_path, 53)
        _physical_udp(runtime_path, 443)
        _physical_dns(runtime_path)
        _host_route_blocked(runtime_path)
        _ipv6_blocked(runtime_path)
        watchdog_process = _spawn_watchdog(runtime_path, runtime)
        os.kill(runtime["sing_box_pid"], signal.SIGSTOP)
        _curl_identity(expect_success=False, max_time=3)
        watchdog_process.wait(timeout=12)
        if watchdog_process.returncode != 0:
            raise VerifyFailure("watchdog recovery failed")
        watchdog_recovered = True
        recovered_identity = _resume_and_probe(runtime_path)
    except BaseException as exc:
        failure = exc
    finally:
        if runtime is not None:
            try:
                cancel_watchdog(runtime_path)
            except BaseException as exc:
                if failure is None:
                    failure = exc
            if recovered_identity is None:
                try:
                    recovered_identity = _resume_and_probe(runtime_path)
                except BaseException as exc:
                    if failure is None:
                        failure = exc
        _remove_ready()
        if watchdog_process is not None:
            try:
                watchdog_process.wait(timeout=0)
            except (subprocess.TimeoutExpired, ChildProcessError):
                pass
    if failure is not None:
        if isinstance(failure, Exception):
            raise failure
        raise VerifyFailure("verification interrupted")
    if (
        identity is None
        or user_identity is None
        or chromium_identity is None
        or recovered_identity is None
        or recovered_identity != identity
        or not watchdog_recovered
    ):
        raise VerifyFailure("residential identity changed during recovery")
    checks = [
        "proxied_curl",
        "proxied_chromium",
        "chromium_sandbox_enabled",
        "proxied_dns",
        "counter_enforcement",
        "physical_tcp_blocked",
        "physical_udp53_blocked",
        "physical_udp443_blocked",
        "unprivileged_gateway_blocked",
        "ipv6_blocked",
        "host_route_blocked",
        "physical_dns_blocked",
        "proxy_failure_closed",
        "watchdog_armed",
        "proxy_recovered",
        "readiness_eligible",
        *sorted(user_checks),
    ]
    result = {
        "schema": 1,
        "egress": {
            "ip": identity["ip"],
            "chromium_ip": chromium_identity["ip"],
            "isp": identity["isp"],
            "country": identity["country"],
        },
        "checks": [{"name": name, "ok": True, "details": None} for name in checks],
    }
    _emit(result)
    return result


def recover(runtime_path):
    _require_root()
    _remove_ready()
    cancel_watchdog(runtime_path)
    identity = _resume_and_probe(runtime_path)
    _atomic_bytes(CONFIGURED_PATH, b"authorized\n", 0o600)
    _remove_ready()
    result = {"schema": 1, "recovered": True, "ip": identity["ip"]}
    _emit(result)
    return result


def publish(runtime_path):
    _require_root()
    _runtime(runtime_path)
    _configured_required()
    if os.path.lexists(WATCHDOG_PATH):
        raise VerifyFailure("watchdog metadata remains")
    _curl_identity(expect_success=True)
    _atomic_bytes(READY_PATH, b"ready\n", 0o600)
    result = {"schema": 1, "ready": True}
    _emit(result)
    return result


def watchdog(runtime_path, token, deadline):
    _require_root()
    if TOKEN_RE.fullmatch(token) is None or type(deadline) is not int:
        raise VerifyFailure("invalid watchdog arguments")
    now = int(time.time())
    if deadline <= now or deadline > now + 30:
        raise VerifyFailure("invalid watchdog deadline")
    runtime = _runtime(runtime_path)
    starttime = _proc_starttime(os.getpid())
    if starttime is None:
        raise VerifyFailure("watchdog identity is unavailable")
    _atomic_json(
        WATCHDOG_PATH,
        {
            "schema": 1,
            "pid": os.getpid(),
            "starttime": starttime,
            "token": token,
            "sing_box_pid": runtime["sing_box_pid"],
        },
        0o600,
    )
    while int(time.time()) < deadline:
        time.sleep(min(0.25, max(0.01, deadline - time.time())))
    metadata = _watchdog_metadata()
    if (
        metadata["pid"] != os.getpid()
        or metadata["starttime"] != starttime
        or metadata["token"] != token
        or metadata["sing_box_pid"] != runtime["sing_box_pid"]
        or _proc_starttime(os.getpid()) != starttime
        or _proc_starttime(runtime["sing_box_pid"]) is None
    ):
        raise VerifyFailure("watchdog identity changed")
    os.kill(runtime["sing_box_pid"], signal.SIGCONT)
    _remove_ready()
    return {"schema": 1, "resumed": True}


def _harden_process():
    os.umask(0o077)
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


class QuietParser(argparse.ArgumentParser):
    def error(self, message):
        raise VerifyFailure("invalid verifier arguments")


def _parser():
    parser = QuietParser(add_help=False)
    subparsers = parser.add_subparsers(dest="operation", required=True)
    subparsers.add_parser("workspace", add_help=False)
    user = subparsers.add_parser("unprivileged", add_help=False)
    user.add_argument("--endpoint", required=True)
    user.add_argument("--port", required=True, type=int)
    user.add_argument("--uplink", required=True)
    for operation in ("counters", "quiesce", "cancel_watchdog", "run", "recover", "publish"):
        item = subparsers.add_parser(operation, add_help=False)
        item.add_argument("--runtime", required=True)
    item = subparsers.add_parser("watchdog", add_help=False)
    item.add_argument("--runtime", required=True)
    item.add_argument("--token", required=True)
    item.add_argument("--deadline", required=True, type=int)
    return parser


def main():
    try:
        _harden_process()
        arguments = _parser().parse_args()
        if arguments.operation == "workspace":
            workspace()
        elif arguments.operation == "unprivileged":
            unprivileged(arguments.endpoint, arguments.port, arguments.uplink)
        elif arguments.operation == "counters":
            counters(arguments.runtime)
        elif arguments.operation == "quiesce":
            quiesce(arguments.runtime)
        elif arguments.operation == "cancel_watchdog":
            result = cancel_watchdog(arguments.runtime)
            _emit(result)
        elif arguments.operation == "run":
            run(arguments.runtime)
        elif arguments.operation == "recover":
            recover(arguments.runtime)
        elif arguments.operation == "publish":
            publish(arguments.runtime)
        elif arguments.operation == "watchdog":
            watchdog(arguments.runtime, arguments.token, arguments.deadline)
        else:
            raise VerifyFailure("unknown operation")
    except (VerifyFailure, OSError, ValueError, subprocess.SubprocessError):
        sys.stderr.write("proxy_verify: operation failed\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
