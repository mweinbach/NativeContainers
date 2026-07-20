#!/usr/bin/python3
import os
import stat
import sys
import time

MARKER = "/run/nativecontainers/configured"


def authorized():
    try:
        descriptor = os.open(MARKER, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
        try:
            metadata = os.fstat(descriptor)
            value = os.read(descriptor, 64)
        finally:
            os.close(descriptor)
        return (
            stat.S_ISREG(metadata.st_mode)
            and metadata.st_uid == 0
            and stat.S_IMODE(metadata.st_mode) == 0o600
            and metadata.st_nlink == 1
            and value == b"authorized\n"
        )
    except OSError:
        return False


def main():
    while not authorized():
        time.sleep(0.05)
    return 0


if __name__ == "__main__":
    sys.exit(main())
