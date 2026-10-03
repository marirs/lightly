#!/usr/bin/env python3
"""Seconds-long checks to run BEFORE taking the heavy-job lock for a verification.

Each check exists because a measured verification run failed on it
(/tmp/lightly-heavy.log, 2026-10-03):
  - Java: two Android runs died on JDK 26 (Robolectric needs JDK <= 25).
  - Assets: a 6.2-minute iOS unit run failed on the missing, git-ignored LUT
    golden set.
  - Source identity: one Android run built the moving working folder, which
    held another agent's uncommitted work, instead of the commit under test.
A failed check exits 1 immediately with the reason, before any lock or build.

Usage:
  scripts/verify_preflight.py snapshot <commit> <dir>
      Export <commit> with git archive into an empty <dir> and record the
      commit in <dir>/.lightly-source. Git-ignored inputs are not copied; the
      checks below point the build at the main checkout's copies.
  scripts/verify_preflight.py check <android|ios> <source-dir> <commit>
      Verify the source is exactly <commit> and that the platform's tools and
      git-ignored inputs are present. On success, prints the environment
      lines to use for the run (eval-able "export" lines).
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

MAIN_CHECKOUT = Path(__file__).resolve().parent.parent
SOURCE_MARKER = ".lightly-source"
MAXIMUM_ROBOLECTRIC_JAVA = 25
ANDROID_STUDIO_JDK = Path("/Applications/Android Studio.app/Contents/jbr/Contents/Home")
IOS_TEST_SIMULATOR = "iPhone 17"


class PreflightFailure(Exception):
    pass


def run(*arguments: str, cwd: Path | None = None) -> str:
    return subprocess.run(arguments, cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


def full_commit(commit: str) -> str:
    try:
        return run("git", "-C", str(MAIN_CHECKOUT), "rev-parse", "--verify", f"{commit}^{{commit}}")
    except subprocess.CalledProcessError as error:
        raise PreflightFailure(f"unknown commit {commit}") from error


def make_snapshot(commit: str, destination: Path) -> None:
    resolved = full_commit(commit)
    if destination.exists() and any(destination.iterdir()):
        raise PreflightFailure(f"{destination} is not empty; snapshots go into an empty folder")
    destination.mkdir(parents=True, exist_ok=True)
    archive = subprocess.Popen(["git", "-C", str(MAIN_CHECKOUT), "archive", resolved], stdout=subprocess.PIPE)
    subprocess.run(["tar", "-x", "-C", str(destination)], stdin=archive.stdout, check=True)
    if archive.wait() != 0:
        raise PreflightFailure("git archive failed")
    (destination / SOURCE_MARKER).write_text(resolved + "\n")
    print(f"snapshot of {resolved[:12]} in {destination}")


def require_source_identity(source: Path, expected_commit: str) -> str:
    """The build must see exactly the commit under test, nothing more."""
    expected = full_commit(expected_commit)
    marker = source / SOURCE_MARKER
    if marker.exists():
        recorded = marker.read_text().strip()
        if recorded != expected:
            raise PreflightFailure(f"snapshot holds {recorded[:12]}, not {expected[:12]}")
        return expected
    if (source / ".git").exists():
        head = run("git", "-C", str(source), "rev-parse", "HEAD")
        if head != expected:
            raise PreflightFailure(f"checkout is at {head[:12]}, not {expected[:12]}")
        # Untracked files count too: an untracked Swift file inside the app
        # folder is compiled into the build.
        changes = run("git", "-C", str(source), "status", "--porcelain", "--", "ios", "android", "shared")
        if changes:
            raise PreflightFailure(
                "the checkout has local changes, so it is not the commit under test; "
                "use `scripts/verify_preflight.py snapshot`:\n" + changes
            )
        return expected
    raise PreflightFailure(f"{source} is neither a snapshot ({SOURCE_MARKER}) nor a git checkout")


# A git-ignored input is present only when files matching its sentinel exist.
# Directory existence is not enough: the tracked .gitignore and metadata
# files keep these folders alive in every checkout and snapshot.
IGNORED_INPUT_SENTINELS = {
    "experiments/lut3d/golden": ("LUT golden set", "*/reference.png"),
    "experiments/lut3d/models": ("LUT models", "*.bin"),
    "shared/look-pack/out": ("look-pack manifest", "manifest.json"),
}


def has_sentinel(folder: Path, pattern: str) -> bool:
    return folder.is_dir() and any(folder.glob(pattern))


def resolve_ignored_input(source: Path, relative: str) -> Path:
    """Use the source's copy when it is complete, else the main checkout's; fail if neither is."""
    description, pattern = IGNORED_INPUT_SENTINELS[relative]
    for candidate in (source / relative, MAIN_CHECKOUT / relative):
        if has_sentinel(candidate, pattern):
            return candidate
    raise PreflightFailure(f"{description} missing: no {pattern} under {source / relative} or {MAIN_CHECKOUT / relative}")


def java_major_version(java_home: Path) -> int:
    java = java_home / "bin/java"
    if not java.exists():
        raise PreflightFailure(f"no java at {java}")
    banner = subprocess.run([str(java), "-version"], capture_output=True, text=True).stderr
    match = re.search(r'version "(\d+)', banner)
    if not match:
        raise PreflightFailure(f"cannot read the Java version from: {banner.strip()}")
    return int(match.group(1))


def choose_android_java_home() -> Path:
    candidates = [Path(os.environ["JAVA_HOME"])] if os.environ.get("JAVA_HOME") else []
    candidates.append(ANDROID_STUDIO_JDK)
    for candidate in candidates:
        if candidate.exists() and java_major_version(candidate) <= MAXIMUM_ROBOLECTRIC_JAVA:
            return candidate
    raise PreflightFailure(f"no JDK <= {MAXIMUM_ROBOLECTRIC_JAVA} found (tried {', '.join(map(str, candidates))})")


def check_android(source: Path) -> list[str]:
    java_home = choose_android_java_home()
    sdk_properties = source / "android/local.properties"
    if not sdk_properties.exists():
        sdk_properties = MAIN_CHECKOUT / "android/local.properties"
    sdk_line = next((l for l in sdk_properties.read_text().splitlines() if l.startswith("sdk.dir=")), None)
    if not sdk_line or not Path(sdk_line.split("=", 1)[1]).is_dir():
        raise PreflightFailure(f"android SDK not configured in {sdk_properties}")
    golden = resolve_ignored_input(source, "experiments/lut3d/golden")
    models = resolve_ignored_input(source, "experiments/lut3d/models")
    look_pack = resolve_ignored_input(source, "shared/look-pack/out")
    if not (source / "android/local.properties").exists():
        shutil.copy2(sdk_properties, source / "android/local.properties")
    return [
        f"export JAVA_HOME='{java_home}'",
        f"export LIGHTLY_GOLDEN_DIR='{golden}'",
        f"export LIGHTLY_MODELS_DIR='{models}'",
        f"export LIGHTLY_LOOK_PACK_DIR='{look_pack}'",
    ]


def check_ios(source: Path) -> list[str]:
    golden = resolve_ignored_input(source, "experiments/lut3d/golden")
    look_pack = resolve_ignored_input(source, "shared/look-pack/out")
    if not (source / "shared/look-pack/out/manifest.json").exists():
        # scripts/bundle_look_pack.sh reads the pack from the source tree.
        (source / "shared/look-pack/out").mkdir(parents=True, exist_ok=True)
        shutil.copy2(look_pack / "manifest.json", source / "shared/look-pack/out/manifest.json")
    devices = run("xcrun", "simctl", "list", "devices", "available")
    if not re.search(rf"^\s+{re.escape(IOS_TEST_SIMULATOR)} \(", devices, re.MULTILINE):
        raise PreflightFailure(f"simulator '{IOS_TEST_SIMULATOR}' not available")
    return [
        f"export TEST_RUNNER_LIGHTLY_GOLDEN_DIR='{golden}'",
        f"export LIGHTLY_GOLDEN_DIR='{golden}'",
    ]


def main(argv: list[str]) -> int:
    try:
        if len(argv) == 4 and argv[1] == "snapshot":
            make_snapshot(argv[2], Path(argv[3]))
            return 0
        if len(argv) == 5 and argv[1] == "check" and argv[2] in {"android", "ios"}:
            source = Path(argv[3]).resolve()
            commit = require_source_identity(source, argv[4])
            exports = check_android(source) if argv[2] == "android" else check_ios(source)
            print(f"# preflight ok: {argv[2]} {commit[:12]} in {source}")
            print("\n".join(exports))
            return 0
        print(__doc__, file=sys.stderr)
        return 64
    except PreflightFailure as failure:
        print(f"preflight FAILED: {failure}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
