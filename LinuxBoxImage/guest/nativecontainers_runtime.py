import datetime
import ipaddress
import json
import os
import re
import stat
import subprocess
import tempfile

RUNTIME_DIR = "/run/nativecontainers"
CONFIG_PATH = f"{RUNTIME_DIR}/sing-box.json"
RUNTIME_PATH = f"{RUNTIME_DIR}/runtime.json"
CONFIGURED_PATH = f"{RUNTIME_DIR}/configured"
READY_PATH = f"{RUNTIME_DIR}/ready"
PROFILE_PATH = f"{RUNTIME_DIR}/profile"
NETWORKD_CONFIG_PATH = "/etc/systemd/network/10-nativecontainers.network"
NETWORKD_AUTHORIZATION_DROPIN = "/etc/systemd/system/systemd-networkd.service.d/10-nativecontainers-authorization.conf"

def read_profile():
    try:
        with open(PROFILE_PATH, "r", encoding="ascii") as stream:
            value = stream.read(32)
    except FileNotFoundError:
        return None
    if value not in ("standard\n", "residential\n"):
        raise RuntimeFailure("invalid configured profile")
    return value.rstrip("\n")
NFT = "/usr/sbin/nft"
IP = "/usr/sbin/ip"
SYSCTL = "/usr/sbin/sysctl"
SYS_CLASS_NET = "/sys/class/net"
IFNAME_RE = re.compile(r"^[A-Za-z0-9_.-]{1,15}$")
EFFECTIVE_USERNAME_RE = re.compile(
    r"^(.+)-session-([0-9a-f]{16})-sessionduration-1440$"
)
DOH_ENDPOINTS = {
    ("1.1.1.1", 443, "cloudflare-dns.com", "/dns-query"),
    ("8.8.8.8", 443, "dns.google", "/dns-query"),
}


class RuntimeFailure(Exception):
    pass


class ValidationFailure(RuntimeFailure):
    pass


def _reject_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValidationFailure("duplicate key")
        result[key] = value
    return result


def read_json(stream, max_bytes=65536):
    raw = stream.read(max_bytes + 1)
    if isinstance(raw, str):
        raw = raw.encode("utf-8")
    if len(raw) > max_bytes:
        raise ValidationFailure("input too large")
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ValidationFailure("invalid utf-8") from exc
    decoder = json.JSONDecoder(object_pairs_hook=_reject_duplicates)
    try:
        value, offset = decoder.raw_decode(text.lstrip())
    except (ValueError, ValidationFailure) as exc:
        raise ValidationFailure("invalid json") from exc
    leading = len(text) - len(text.lstrip())
    if text[leading + offset :].strip():
        raise ValidationFailure("trailing data")
    return value


def _exact_object(value, keys):
    if not isinstance(value, dict) or set(value) != set(keys):
        raise ValidationFailure("invalid object schema")
    return value


def _global_ipv4(value):
    if not isinstance(value, str):
        raise ValidationFailure("invalid ipv4")
    try:
        address = ipaddress.IPv4Address(value)
    except ValueError as exc:
        raise ValidationFailure("invalid ipv4") from exc
    if not address.is_global:
        raise ValidationFailure("non-global ipv4")
    return str(address)


def _utc_rfc3339(value):
    if not isinstance(value, str):
        raise ValidationFailure("invalid timestamp")
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.datetime.fromisoformat(normalized)
    except ValueError as exc:
        raise ValidationFailure("invalid timestamp") from exc
    if parsed.tzinfo is None or parsed.utcoffset() != datetime.timedelta(0):
        raise ValidationFailure("timestamp is not UTC")
    return value


def validate_payload(value):
    payload = _exact_object(value, {"schema", "credentials", "endpoints"})
    if type(payload["schema"]) is not int or payload["schema"] != 1:
        raise ValidationFailure("invalid payload schema")

    credentials = _exact_object(
        payload["credentials"],
        {"schema", "provider", "product", "scheme", "host", "port", "username", "password"},
    )
    if (
        type(credentials["schema"]) is not int
        or credentials["schema"] != 1
        or credentials["provider"] != "decodo"
        or credentials["product"] != "residential"
        or credentials["scheme"] != "socks5"
        or credentials["host"] != "gate.decodo.com"
        or type(credentials["port"]) is not int
        or credentials["port"] != 7000
    ):
        raise ValidationFailure("invalid credential contract")
    username = credentials["username"]
    password = credentials["password"]
    if not isinstance(username, str) or not isinstance(password, str):
        raise ValidationFailure("invalid credential values")
    if not 47 <= len(username) <= 4096 or not 1 <= len(password) <= 4096:
        raise ValidationFailure("invalid credential values")
    if (
        any(not 0x21 <= ord(character) <= 0x7E for character in username)
        or any(not 0x21 <= ord(character) <= 0x7E for character in password)
        or ":" in username
    ):
        raise ValidationFailure("invalid credential values")
    match = EFFECTIVE_USERNAME_RE.fullmatch(username)
    if match is None:
        raise ValidationFailure("invalid effective username")
    base = match.group(1)
    if not base or "-session-" in base or "-sessionduration-" in base:
        raise ValidationFailure("invalid effective username")

    endpoints = _exact_object(
        payload["endpoints"],
        {"schema", "host", "port", "selected", "allowed", "doh", "resolved_at"},
    )
    if (
        type(endpoints["schema"]) is not int
        or endpoints["schema"] != 1
        or endpoints["host"] != "gate.decodo.com"
        or type(endpoints["port"]) is not int
        or endpoints["port"] != 7000
    ):
        raise ValidationFailure("invalid endpoint contract")
    allowed_value = endpoints["allowed"]
    if not isinstance(allowed_value, list) or not allowed_value:
        raise ValidationFailure("invalid endpoint list")
    allowed = [_global_ipv4(item) for item in allowed_value]
    if len(set(allowed)) != len(allowed) or allowed != sorted(allowed, key=lambda item: int(ipaddress.IPv4Address(item))):
        raise ValidationFailure("endpoint list must be unique and sorted")
    selected = _global_ipv4(endpoints["selected"])
    if selected not in allowed:
        raise ValidationFailure("selected endpoint is not allowed")
    doh = _exact_object(endpoints["doh"], {"address", "port", "server_name", "path"})
    doh_address = _global_ipv4(doh["address"])
    doh_tuple = (doh_address, doh["port"], doh["server_name"], doh["path"])
    if doh_tuple not in DOH_ENDPOINTS:
        raise ValidationFailure("invalid doh endpoint")
    _utc_rfc3339(endpoints["resolved_at"])

    return {
        "schema": 1,
        "credentials": dict(credentials),
        "endpoints": {
            "schema": 1,
            "host": "gate.decodo.com",
            "port": 7000,
            "selected": selected,
            "allowed": allowed,
            "doh": {
                "address": doh_address,
                "port": 443,
                "server_name": doh["server_name"],
                "path": "/dns-query",
            },
            "resolved_at": endpoints["resolved_at"],
        },
    }


def _validate_uplink(value, require_exists=False):
    if not isinstance(value, str) or IFNAME_RE.fullmatch(value) is None:
        raise ValidationFailure("invalid uplink")
    if require_exists and not os.path.isdir(os.path.join(SYS_CLASS_NET, value)):
        raise RuntimeFailure("uplink is absent")
    return value


def discover_uplink():
    try:
        names = os.listdir(SYS_CLASS_NET)
    except OSError as exc:
        raise RuntimeFailure("uplink discovery failed") from exc
    candidates = []
    for name in names:
        if name in {"lo", "sb-tun"}:
            continue
        try:
            interface = _validate_uplink(name)
            with open(
                os.path.join(SYS_CLASS_NET, interface, "type"),
                "r",
                encoding="ascii",
            ) as stream:
                if stream.read().strip() != "1":
                    continue
            driver = os.path.realpath(
                os.path.join(SYS_CLASS_NET, interface, "device", "driver")
            )
            if os.path.basename(driver) != "virtio_net":
                continue
        except (OSError, UnicodeError, ValidationFailure):
            continue
        candidates.append(interface)
    if len(candidates) != 1:
        raise RuntimeFailure("uplink discovery is ambiguous")
    return _validate_uplink(candidates[0], require_exists=True)


def _nft_ifname(value):
    _validate_uplink(value)
    return value.replace("\\", "\\\\").replace('"', '\\"')


def _baseline_nftables():
    return """flush ruleset
table inet proxy_vm {
    chain input {
        type filter hook input priority filter; policy drop;
        iifname "lo" accept
        meta nfproto ipv6 drop
        meta nfproto ipv4 accept
    }
    chain forward {
        type filter hook forward priority filter; policy drop;
        meta nfproto ipv6 drop
        meta nfproto ipv4 accept
    }
    chain output {
        type filter hook output priority filter; policy drop;
        oifname "lo" accept
        meta nfproto ipv6 drop
        meta nfproto ipv4 accept
    }
}
"""

def render_standard_nftables(uplink):
    """Ordinary IPv4 networking without proxy/provider dependencies."""
    return """flush ruleset
table inet proxy_vm {
    chain input {
        type filter hook input priority filter; policy drop;
        iifname "lo" accept
        meta nfproto ipv6 drop
        meta nfproto ipv4 accept
    }
    chain forward {
        type filter hook forward priority filter; policy drop;
        meta nfproto ipv6 drop
        meta nfproto ipv4 accept
    }
    chain output {
        type filter hook output priority filter; policy drop;
        oifname "lo" accept
        meta nfproto ipv6 drop
        meta nfproto ipv4 accept
    }
}"""


def select_standard_networkd_configuration():
    return """[Match]
Driver=virtio_net

[Link]
RequiredForOnline=routable

[Network]
DHCP=ipv4
IPv6AcceptRA=no
LinkLocalAddressing=ipv4
LLMNR=no
MulticastDNS=no
DNSDefaultRoute=yes

[DHCPv4]
ClientIdentifier=mac
UseDNS=yes
UseNTP=no
UseHostname=no
SendHostname=no
"""


def remove_residential_authorization_dropin():
    try:
        os.unlink(NETWORKD_AUTHORIZATION_DROPIN)
    except FileNotFoundError:
        pass


def configure_standard_network():
    """Atomically switch from the boot baseline to ordinary DHCP networking."""
    _ensure_runtime_directory()
    uplink = discover_uplink()
    _disable_ipv6()
    _atomic_bytes(NETWORKD_CONFIG_PATH,
                  select_standard_networkd_configuration().encode("utf-8"), 0o644)
    remove_residential_authorization_dropin()
    _run_checked(["/bin/systemctl", "daemon-reload"])
    _load_nftables(render_standard_nftables(uplink))
    _run_checked(["/bin/systemctl", "start", "systemd-networkd.service"])
    _atomic_bytes(PROFILE_PATH, b"standard\n", 0o600)
    _atomic_json(RUNTIME_PATH, {"schema": 1, "profile": "standard", "uplink": uplink}, 0o600)
    _atomic_bytes(CONFIGURED_PATH, b"authorized\n", 0o600)
    return uplink


def render_nftables(uplink, endpoints):
    interface = _nft_ifname(uplink)
    selected = _global_ipv4(endpoints["selected"])
    port = endpoints.get("port")
    if type(port) is not int or port != 7000:
        raise ValidationFailure("invalid endpoint port")
    return f"""flush ruleset
table inet proxy_vm {{
    set proxy_endpoints {{
        type ipv4_addr . inet_service
        flags constant
        elements = {{ {selected} . {port} }}
    }}
    set host_routes {{
        type ipv4_addr
        flags interval,constant
        elements = {{ 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 }}
    }}
    counter physical_ipv4_drop {{}}
    counter physical_udp_drop {{}}
    counter ipv6_drop {{}}
    counter unprivileged_gateway_drop {{}}
    counter host_route_drop {{}}
    chain input {{
        type filter hook input priority filter; policy drop;
        meta nfproto ipv6 counter name ipv6_drop drop
        iifname "lo" accept
        iifname "{interface}" udp sport 67 udp dport 68 accept
        ct state established,related accept
        iifname "sb-tun" meta nfproto ipv4 accept
    }}
    chain forward {{
        type filter hook forward priority filter; policy drop;
    }}
    chain output {{
        type filter hook output priority filter; policy drop;
        meta nfproto ipv6 counter name ipv6_drop drop
        oifname "lo" accept
        meta skuid != 0 ip daddr . tcp dport @proxy_endpoints counter name unprivileged_gateway_drop drop
        ip daddr @host_routes counter name host_route_drop drop
        ct state established,related accept
        oifname "sb-tun" meta nfproto ipv4 accept
        meta skuid 0 oifname "{interface}" ip daddr . tcp dport @proxy_endpoints accept
        oifname "{interface}" udp sport 68 udp dport 67 accept
        meta l4proto udp counter name physical_udp_drop drop
        meta nfproto ipv4 counter name physical_ipv4_drop drop
    }}
}}
"""


def render_sing_box(uplink, credentials, endpoints):
    interface = _validate_uplink(uplink)
    return {
        "log": {"disabled": True},
        "dns": {
            "servers": [
                {
                    "type": "https",
                    "tag": "doh",
                    "server": endpoints["doh"]["address"],
                    "server_port": 443,
                    "path": "/dns-query",
                    "tls": {
                        "enabled": True,
                        "server_name": endpoints["doh"]["server_name"],
                    },
                    "detour": "decodo",
                }
            ],
            "final": "doh",
            "strategy": "ipv4_only",
        },
        "inbounds": [
            {
                "type": "tun",
                "interface_name": "sb-tun",
                "address": ["172.19.0.1/30"],
                "auto_route": True,
                "strict_route": True,
                "stack": "system",
            }
        ],
        "outbounds": [
            {
                "type": "socks",
                "tag": "decodo",
                "server": endpoints["selected"],
                "server_port": 7000,
                "username": credentials["username"],
                "password": credentials["password"],
                "network": "tcp",
                "bind_interface": interface,
            }
        ],
        "route": {
            "rules": [
                {"protocol": "dns", "action": "hijack-dns"},
                {"network": "udp", "action": "reject", "method": "drop"},
            ],
            "auto_detect_interface": True,
            "final": "decodo",
        },
    }


def _run_checked(arguments, stdin=None):
    result = subprocess.run(
        arguments,
        input=stdin,
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if result.returncode != 0:
        raise RuntimeFailure("guest command failed")


def _load_nftables(rules):
    _run_checked([NFT, "-f", "-"], rules.encode("utf-8"))


def _disable_ipv6():
    _run_checked([SYSCTL, "-q", "-w", "net.ipv6.conf.all.disable_ipv6=1"])
    _run_checked([SYSCTL, "-q", "-w", "net.ipv6.conf.default.disable_ipv6=1"])


def probe():
    try:
        device = os.stat("/dev/net/tun", follow_symlinks=False)
    except OSError as exc:
        raise RuntimeFailure("tun character device is unavailable") from exc
    if not stat.S_ISCHR(device.st_mode):
        raise RuntimeFailure("tun character device is unavailable")
    _run_checked([NFT, "list", "ruleset"])
    created = False
    try:
        _run_checked([IP, "tuntap", "add", "dev", "pv-probe", "mode", "tun"])
        created = True
    finally:
        if created:
            _run_checked([IP, "tuntap", "del", "dev", "pv-probe", "mode", "tun"])


def _mount_unescape(value):
    return re.sub(
        r"\\([0-7]{3})",
        lambda match: chr(int(match.group(1), 8)),
        value,
    )


def _prepare_workspace():
    matches = []
    try:
        with open("/proc/self/mountinfo", "r", encoding="utf-8") as stream:
            for line in stream:
                fields = line.rstrip("\n").split()
                if len(fields) >= 10 and _mount_unescape(fields[4]) == "/workspace":
                    matches.append(fields)
    except OSError as exc:
        raise RuntimeFailure("mount information is unavailable") from exc
    if len(matches) != 1 or _mount_unescape(matches[0][3]) != "/":
        raise RuntimeFailure("workspace is not an exact volume mount root")
    workspace = os.stat("/workspace", follow_symlinks=False)
    if not stat.S_ISDIR(workspace.st_mode) or workspace.st_uid != 0:
        raise RuntimeFailure("workspace ownership is invalid")
    os.chmod("/workspace", 0o1777, follow_symlinks=False)
    updated = os.stat("/workspace", follow_symlinks=False)
    if stat.S_IMODE(updated.st_mode) != 0o1777 or updated.st_uid != 0:
        raise RuntimeFailure("workspace mode update failed")


def _ensure_runtime_directory():
    try:
        os.mkdir(RUNTIME_DIR, 0o700)
    except FileExistsError:
        pass
    runtime = os.stat(RUNTIME_DIR, follow_symlinks=False)
    if (
        not stat.S_ISDIR(runtime.st_mode)
        or runtime.st_uid != 0
        or stat.S_IMODE(runtime.st_mode) != 0o700
    ):
        raise RuntimeFailure("runtime directory security is invalid")


def _atomic_bytes(path, data, mode):
    directory = os.path.dirname(path)
    descriptor, temporary = tempfile.mkstemp(prefix=".proxy-vm-", dir=directory)
    try:
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, "wb", closefd=True) as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
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
        raise RuntimeFailure("runtime file security is invalid")

def _remove_markers():
    for path in (CONFIGURED_PATH, READY_PATH, PROFILE_PATH, RUNTIME_PATH):
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
