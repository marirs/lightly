#!/usr/bin/env python3
"""Minutes spent building, testing, capturing, verifying and waiting.

Reads /tmp/lightly-heavy.log (written by scripts/heavy) and reports measured
time per category, so progress is reported in minutes rather than agent counts
or estimates (owner instruction, 2026-10-03).

Category comes from the job label prefix: build-, test-, capture-, verify-.
Labels written before that convention are classified by keyword and reported
under "(by keyword)" so the guess is visible; labels matching nothing are
"other".

Waiting is measured twice, as job-minutes (summed per waiting job, so
overlapping waits add up and can exceed the window):
  - queued: time between WAIT and START for jobs that got the lock
  - refused: time between WAIT and BUSY for jobs that gave up (exit 75)
The header gives the wall-clock window and how much of it the lock was held.

Usage: scripts/heavy_report.py [--since "YYYY-MM-DD HH:MM"] [--log PATH] [--jobs]
"""
from __future__ import annotations

import argparse
import re
import sys
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

LOG_LINE = re.compile(
    r"^(?P<stamp>\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) (?P<event>WAIT|START|END|BUSY)\s+pid=\d+ label=(?P<label>\S+)"
    r"(?: waited=(?P<waited>\d+)s)?(?: ran=(?P<ran>\d+)s status=(?P<status>\d+))?"
)
PREFIX_CATEGORIES = ("build", "test", "capture", "verify")
KEYWORD_CATEGORIES = (
    ("capture", ("capture", "shots", "matrix", "runner-validate", "screens")),
    ("verify", ("verify",)),
    ("build", ("build", "apk", "compile", "assemble")),
    ("test", ("test",)),
)


@dataclass
class CategoryTotals:
    jobs: int = 0
    ran_seconds: int = 0
    failed_jobs: int = 0
    queued_seconds: int = 0
    refused_jobs: int = 0
    refused_seconds: int = 0


def categorise(label: str) -> tuple[str, bool]:
    """Return (category, was_guessed_from_keywords)."""
    head = label.split("-", 1)[0]
    if head in PREFIX_CATEGORIES:
        return head, False
    lowered = label.lower()
    for category, keywords in KEYWORD_CATEGORIES:
        if any(keyword in lowered for keyword in keywords):
            return category, True
    return "other", True


def parse_log(log_path: Path, since: datetime | None) -> list[dict[str, str]]:
    events = []
    for line in log_path.read_text().splitlines():
        match = LOG_LINE.match(line)
        if not match:
            continue
        event = match.groupdict()
        if since and datetime.strptime(event["stamp"], "%Y-%m-%d %H:%M:%S") < since:
            continue
        events.append(event)
    return events


def summarise(events: list[dict[str, str]]) -> tuple[dict[str, CategoryTotals], list[str]]:
    totals: dict[str, CategoryTotals] = defaultdict(CategoryTotals)
    job_lines = []
    for event in events:
        category, guessed = categorise(event["label"])
        key = f"{category} (by keyword)" if guessed and category != "other" else category
        bucket = totals[key]
        if event["event"] == "START":
            bucket.queued_seconds += int(event["waited"] or 0)
        elif event["event"] == "END":
            bucket.jobs += 1
            bucket.ran_seconds += int(event["ran"] or 0)
            if event["status"] != "0":
                bucket.failed_jobs += 1
            job_lines.append(
                f"{event['stamp']}  {key:<22} {int(event['ran'] or 0) / 60:6.1f} min  "
                f"status={event['status']}  {event['label']}"
            )
        elif event["event"] == "BUSY":
            bucket.refused_jobs += 1
            bucket.refused_seconds += int(event["waited"] or 0)
    return totals, job_lines


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--log", default="/tmp/lightly-heavy.log")
    parser.add_argument("--since", help='only events at or after "YYYY-MM-DD HH:MM"')
    parser.add_argument("--jobs", action="store_true", help="also list every finished job")
    arguments = parser.parse_args()
    since = datetime.strptime(arguments.since, "%Y-%m-%d %H:%M") if arguments.since else None
    events = parse_log(Path(arguments.log), since)
    if not events:
        print("no heavy-job events in range")
        return 0
    totals, job_lines = summarise(events)
    window_start = datetime.strptime(events[0]["stamp"], "%Y-%m-%d %H:%M:%S")
    window_end = datetime.strptime(events[-1]["stamp"], "%Y-%m-%d %H:%M:%S")
    window_minutes = (window_end - window_start).total_seconds() / 60
    held_minutes = sum(t.ran_seconds for t in totals.values()) / 60
    print(f"Heavy jobs {events[0]['stamp']} to {events[-1]['stamp']}: window {window_minutes:.0f} min, "
          f"lock held {held_minutes:.0f} min. Columns in minutes; waits are job-minutes and overlap.")
    print(f"{'category':<22} {'jobs':>5} {'running':>8} {'failed':>7} {'queued':>8} {'refused':>8} {'refused min':>12}")
    grand = CategoryTotals()
    for category in sorted(totals):
        t = totals[category]
        print(f"{category:<22} {t.jobs:>5} {t.ran_seconds / 60:>8.1f} {t.failed_jobs:>7} "
              f"{t.queued_seconds / 60:>8.1f} {t.refused_jobs:>8} {t.refused_seconds / 60:>12.1f}")
        grand.jobs += t.jobs
        grand.ran_seconds += t.ran_seconds
        grand.failed_jobs += t.failed_jobs
        grand.queued_seconds += t.queued_seconds
        grand.refused_jobs += t.refused_jobs
        grand.refused_seconds += t.refused_seconds
    print(f"{'total':<22} {grand.jobs:>5} {grand.ran_seconds / 60:>8.1f} {grand.failed_jobs:>7} "
          f"{grand.queued_seconds / 60:>8.1f} {grand.refused_jobs:>8} {grand.refused_seconds / 60:>12.1f}")
    if arguments.jobs:
        print()
        print("\n".join(job_lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
