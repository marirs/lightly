"""Loading and verifying the frozen evaluation protocol.

PROTOCOL.lock pins the sha256 of PROTOCOL.json and of the code that interprets it. A run against a protocol
whose files no longer match the lock is refused, so a threshold or metric cannot drift silently after G0.
"""
from __future__ import annotations

import hashlib
import json
import os

from .paths import AUTO_ROOT, PROTOCOL_JSON, PROTOCOL_LOCK

LOCKED_FILES = ["PROTOCOL.json", "lightly_auto/rubric.py", "lightly_auto/stats.py"]


def current_fingerprint() -> dict:
    files = {}
    for relative in LOCKED_FILES:
        with open(os.path.join(AUTO_ROOT, relative), "rb") as handle:
            files[relative] = hashlib.sha256(handle.read()).hexdigest()
    combined = hashlib.sha256("".join(files[k] for k in LOCKED_FILES).encode()).hexdigest()
    version = json.load(open(PROTOCOL_JSON))["version"]
    return {"version": version, "files": files, "combined_sha256": combined}


class ProtocolLockMismatch(RuntimeError):
    pass


def load_protocol(verify_lock: bool = True) -> dict:
    protocol = json.load(open(PROTOCOL_JSON))
    if verify_lock:
        if not os.path.exists(PROTOCOL_LOCK):
            raise ProtocolLockMismatch("PROTOCOL.lock missing; run freeze_protocol.py")
        locked = json.load(open(PROTOCOL_LOCK))
        current = current_fingerprint()
        if locked != current:
            changed = [k for k in LOCKED_FILES if locked.get("files", {}).get(k) != current["files"][k]]
            raise ProtocolLockMismatch(
                f"protocol files changed since lock {locked.get('version')}: {changed}. "
                "Bump PROTOCOL.json version and re-run freeze_protocol.py if the change is intended.")
    return protocol
