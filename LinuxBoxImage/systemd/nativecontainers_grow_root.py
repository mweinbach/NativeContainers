#!/usr/bin/python3
import os
import re
import subprocess
import sys

FINDMNT = "/usr/bin/findmnt"
LSBLK = "/usr/bin/lsblk"
GROWPART = "/usr/bin/growpart"
RESIZE2FS = "/usr/sbin/resize2fs"
XFS_GROWFS = "/usr/sbin/xfs_growfs"
DEVICE_RE = re.compile(r"^/dev/([A-Za-z0-9._+-]+)$")
CAPACITY_PROOF_BYTES = 30_000_000_000
CAPACITY_PROOF_MARKER = b"NATIVECONTAINERS_ROOT_EXPANDED_32G\n"
ROOT_EXPANSION_FAILURE_MARKERS = {
    "root_source": b"NATIVECONTAINERS_ROOT_EXPANSION_FAILED step=root_source\n",
    "parent": b"NATIVECONTAINERS_ROOT_EXPANSION_FAILED step=parent\n",
    "partition_number": b"NATIVECONTAINERS_ROOT_EXPANSION_FAILED step=partition_number\n",
    "partition_size_before": b"NATIVECONTAINERS_ROOT_EXPANSION_FAILED step=partition_size_before\n",
    "disk_size": b"NATIVECONTAINERS_ROOT_EXPANSION_FAILED step=disk_size\n",
    "growpart": b"NATIVECONTAINERS_ROOT_EXPANSION_FAILED step=growpart\n",
    "partition_size_after": b"NATIVECONTAINERS_ROOT_EXPANSION_FAILED step=partition_size_after\n",
    "filesystem_type": b"NATIVECONTAINERS_ROOT_EXPANSION_FAILED step=filesystem_type\n",
    "filesystem_size": b"NATIVECONTAINERS_ROOT_EXPANSION_FAILED step=filesystem_size\n",
    "resize": b"NATIVECONTAINERS_ROOT_EXPANSION_FAILED step=resize\n",
    "final_size": b"NATIVECONTAINERS_ROOT_EXPANSION_FAILED step=final_size\n",
    "validation": b"NATIVECONTAINERS_ROOT_EXPANSION_FAILED step=validation\n",
}


def _emit_marker(marker):
    for path in ("/dev/hvc0", "/dev/ttyS0"):
        try:
            descriptor = os.open(
                path,
                os.O_WRONLY | os.O_CLOEXEC | os.O_NOCTTY,
            )
        except OSError:
            continue
        written_successfully = False
        try:
            offset = 0
            while offset < len(marker):
                written = os.write(descriptor, marker[offset:])
                if written <= 0:
                    raise OSError("serial marker write made no progress")
                offset += written
            written_successfully = True
        except OSError:
            pass
        finally:
            try:
                os.close(descriptor)
            except OSError:
                pass
        if written_successfully:
            return


def emit_failure_marker(step):
    marker = ROOT_EXPANSION_FAILURE_MARKERS.get(step)
    if marker is not None:
        _emit_marker(marker)


def emit_capacity_proof():
    _emit_marker(CAPACITY_PROOF_MARKER)



def output(arguments):
    result = subprocess.run(
        arguments,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        close_fds=True,
        check=False,
        text=True,
        timeout=30,
        env={"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "LANG": "C.UTF-8"},
    )
    if result.returncode != 0:
        raise RuntimeError("capacity inspection failed")
    return result.stdout.strip()


def quiet(arguments, accepted=(0,)):
    result = subprocess.run(
        arguments,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        close_fds=True,
        check=False,
        timeout=300,
        env={"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "LANG": "C.UTF-8"},
    )
    if result.returncode not in accepted:
        raise RuntimeError("capacity expansion failed")


def main():
    if os.geteuid() != 0:
        emit_failure_marker("validation")
        return 1
    step = "root_source"
    try:
        source = output([FINDMNT, "--noheadings", "--output", "SOURCE", "/"])
        if DEVICE_RE.fullmatch(source) is None:
            raise RuntimeError("root device is invalid")
        step = "parent"
        parent = output([LSBLK, "--nodeps", "--noheadings", "--output", "PKNAME", source])
        disk = f"/dev/{parent}"
        if not parent or DEVICE_RE.fullmatch(disk) is None:
            raise RuntimeError("root disk is invalid")
        step = "partition_number"
        partition = output([LSBLK, "--nodeps", "--noheadings", "--output", "PARTN", source])
        if not partition.isdigit():
            raise RuntimeError("root partition is invalid")
        step = "partition_size_before"
        before = int(output([LSBLK, "--nodeps", "--bytes", "--noheadings", "--output", "SIZE", source]))
        step = "disk_size"
        disk_size = int(output([LSBLK, "--nodeps", "--bytes", "--noheadings", "--output", "SIZE", disk]))
        if disk_size > before:
            step = "growpart"
            quiet([GROWPART, disk, partition], accepted=(0, 1))
        step = "partition_size_after"
        partition_size = int(
            output([LSBLK, "--nodeps", "--bytes", "--noheadings", "--output", "SIZE", source])
        )
        step = "filesystem_type"
        filesystem = output([FINDMNT, "--noheadings", "--output", "FSTYPE", "/"])
        step = "filesystem_size"
        filesystem_size = int(
            output([FINDMNT, "--bytes", "--noheadings", "--output", "SIZE", "/"])
        )
        if partition_size > filesystem_size:
            if filesystem == "ext4":
                step = "resize"
                quiet([RESIZE2FS, source])
            elif filesystem == "xfs":
                step = "resize"
                quiet([XFS_GROWFS, "/"])
            else:
                raise RuntimeError("root filesystem is unsupported")
        step = "final_size"
        final_size = int(
            output([FINDMNT, "--bytes", "--noheadings", "--output", "SIZE", "/"])
        )
        step = "validation"
        if final_size >= CAPACITY_PROOF_BYTES:
            emit_capacity_proof()
        return 0
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired):
        emit_failure_marker(step)
        return 1


if __name__ == "__main__":
    sys.exit(main())
