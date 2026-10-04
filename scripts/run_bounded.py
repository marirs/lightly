#!/usr/bin/env python3
"""Bound a complete heavy-job invocation, including lock waits, to ten minutes."""
import os
import signal
import subprocess
import sys

def run(command, seconds=600):
    process = subprocess.Popen(command, start_new_session=True)
    def stop():
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass
        # Descendants can outlive their shell; also kill the remaining group.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
    def interrupted(signum, frame):
        stop()
        raise SystemExit(128 + signum)
    previous = {s: signal.signal(s, interrupted) for s in (signal.SIGTERM, signal.SIGINT)}
    try:
        return process.wait(timeout=seconds)
    except subprocess.TimeoutExpired:
        stop()
        print("Review budget exhausted: work remains PENDING. Do not automatically retry.", file=sys.stderr)
        return 124
    finally:
        for s, handler in previous.items():
            signal.signal(s, handler)

if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(64)
    sys.exit(run(sys.argv[1:]))
