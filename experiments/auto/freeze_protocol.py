"""Write PROTOCOL.lock for the current PROTOCOL.json, rubric.py and stats.py.

Run only when the protocol version has been bumped on purpose. Refuses to re-lock a changed protocol under an
unchanged version number, so a frozen version always means one set of rules.
"""
import json
import os
import sys

from lightly_auto.paths import PROTOCOL_LOCK
from lightly_auto.protocol import current_fingerprint

current = current_fingerprint()
if os.path.exists(PROTOCOL_LOCK):
    previous = json.load(open(PROTOCOL_LOCK))
    if previous == current:
        print(f"PROTOCOL.lock already matches version {current['version']}")
        sys.exit(0)
    if previous.get("version") == current["version"]:
        sys.exit(f"protocol files changed but version is still {current['version']}; bump PROTOCOL.json version first")
with open(PROTOCOL_LOCK, "w") as handle:
    json.dump(current, handle, indent=2)
    handle.write("\n")
print(f"locked protocol {current['version']}: {current['combined_sha256']}")
