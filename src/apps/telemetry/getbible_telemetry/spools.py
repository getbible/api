"""Reclaim committed, closed transport spools without inspecting other processes.

A Linux read lease fails while *any* writable descriptor exists. This is a
kernel-enforced check, unlike a /proc walk which a rootful Docker container may
not be permitted to perform. Unsupported filesystems fail closed. This helper
runs in a separate, single-threaded process so adopting a file owner's effective
UID for the lease cannot change the collector's or sampler's credentials.
"""
from __future__ import annotations

import fcntl
import errno
import json
import os
from pathlib import Path
import signal
import stat
import sys
from typing import Any


def reclaim(item: dict[str, Any]) -> dict[str, Any]:
    path = Path(item["path"])
    result = {"path": str(path), "identity": item["identity"], "removed": False}
    if path.parent.name != "archive" or ".log-" not in path.name or not path.name.endswith(".spool"):
        return {**result, "reason": "not_a_transport_spool"}
    fd = None
    original_uid = os.geteuid()
    broken = False
    operation = "open"

    def on_break(_signum: int, _frame: object) -> None:
        nonlocal broken
        broken = True

    previous_handler = signal.signal(signal.SIGIO, on_break)
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        before = os.fstat(fd)
        if (not stat.S_ISREG(before.st_mode) or before.st_nlink != 1
                or f"{before.st_dev}:{before.st_ino}" != item["identity"]
                or before.st_size != item["size"] or before.st_mtime_ns != item["mtime_ns"]):
            return {**result, "reason": "source_changed"}
        # Acquiring a lease requires ownership or CAP_LEASE. Use the existing
        # root privilege to adopt only this file's owner; no container capability
        # such as SYS_PTRACE or LEASE needs to be granted. Restore it immediately.
        try:
            operation = "set_owner"
            if original_uid != before.st_uid:
                os.seteuid(before.st_uid)
            operation = "lease"
            fcntl.fcntl(fd, fcntl.F_SETLEASE, fcntl.F_RDLCK)
        finally:
            previous_operation = operation
            if os.geteuid() != original_uid:
                operation = "restore_owner"
                os.seteuid(original_uid)
            operation = previous_operation
        operation = "verify"
        current = path.lstat()
        if (broken or fcntl.fcntl(fd, fcntl.F_GETLEASE) != fcntl.F_RDLCK
                or (current.st_dev, current.st_ino, current.st_size, current.st_mtime_ns)
                != (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)):
            return {**result, "reason": "source_changed_or_opening"}
        # Producers open their active .log path, never a closed archive name.
        # Keep the lease until after unlink so no existing writer is overlooked.
        operation = "unlink"
        path.unlink()
        return {**result, "removed": True}
    except FileNotFoundError:
        return {**result, "reason": "source_missing"}
    except (OSError, AttributeError) as exc:
        code = getattr(exc, "errno", None)
        if operation == "lease" and code in {errno.EAGAIN, errno.EWOULDBLOCK}:
            reason = "writer_open"
        elif operation == "lease" and (isinstance(exc, AttributeError)
                or code in {errno.EINVAL, errno.ENOSYS, errno.EOPNOTSUPP}):
            reason = "lease_unsupported"
        elif code in {errno.EPERM, errno.EACCES}:
            reason = "permission_denied"
        else:
            reason = "filesystem_error"
        return {**result, "reason": reason, "errno": code, "operation": operation,
                "error": str(exc)[:512]}
    finally:
        if os.geteuid() != original_uid:
            os.seteuid(original_uid)
        if fd is not None:
            os.close(fd)
        signal.signal(signal.SIGIO, previous_handler)


def main() -> int:
    # Input comes only from the root collector's bounded cleanup batch.
    items = json.loads(sys.stdin.buffer.read(256 * 1024))
    if not isinstance(items, list) or len(items) > 32:
        raise ValueError("Expected at most 32 committed transport spools")
    print(json.dumps([reclaim(item) for item in items]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
