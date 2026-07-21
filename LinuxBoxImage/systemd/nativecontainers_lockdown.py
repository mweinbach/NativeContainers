#!/usr/bin/python3
import json
import os
import stat
import subprocess
import sys

import nativecontainers_runtime as runtime

SYSTEMCTL = "/usr/bin/systemctl"
IP = "/usr/sbin/ip"
RUNTIME_FILES = (
    runtime.CONFIG_PATH,
    runtime.RUNTIME_PATH,
    runtime.CONFIGURED_PATH,
    runtime.READY_PATH,
    f"{runtime.RUNTIME_DIR}/watchdog.json",
)


def quiet(arguments):
    subprocess.run(
        arguments,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        close_fds=True,
        check=False,
        timeout=15,
        env={"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "LANG": "C.UTF-8"},
    )


def uplink():
    try:
        descriptor = os.open(runtime.RUNTIME_PATH, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
        try:
            metadata = os.fstat(descriptor)
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != 0 or metadata.st_size > 4096:
                return None
            value = json.loads(os.read(descriptor, metadata.st_size + 1).decode("utf-8"))
        finally:
            os.close(descriptor)
        candidate = value.get("uplink")
        return runtime._validate_uplink(candidate) if candidate else None
    except (OSError, ValueError, runtime.RuntimeFailure):
        return None


def main():
    candidate = uplink()
    quiet([SYSTEMCTL, "stop", "nativecontainers-sing-box.service"])
    quiet([SYSTEMCTL, "stop", "systemd-networkd.service"])
    quiet([SYSTEMCTL, "stop", "nativecontainers-network-authorization.service"])
    if candidate:
        quiet([IP, "address", "flush", "dev", candidate])
        quiet([IP, "route", "flush", "dev", candidate])
    for path in RUNTIME_FILES:
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
    try:
        runtime._disable_ipv6()
        runtime._load_nftables(runtime._baseline_nftables())
    except runtime.RuntimeFailure:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
