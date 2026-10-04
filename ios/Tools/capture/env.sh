#!/bin/bash
# Shared settings for the iOS capture tools. Source it; every path can be overridden from the
# environment, so nothing depends on one agent's session scratchpad.
#
#   LIGHTLY_REPO           repository root (default: derived from this file's location)
#   LIGHTLY_DD_UNIT        derived data of the app + unit-test build (default /tmp/lightly-dd-unit)
#   LIGHTLY_DD_UI          derived data of the optimised UI-test build (default /tmp/lightly-dd-ui)
#   LIGHTLY_ARTIFACTS      evidence root (default ~/.codex/artifacts/lightly/v1)
#   LIGHTLY_TOOLS_BIN      where the Swift helpers are compiled (default ${TMPDIR:-/tmp}/lightly-capture-tools)
#   LIGHTLY_SHEETS_DIR     JPEG review sheets made on demand (default $LIGHTLY_ARTIFACTS/sheets)
#   LIGHTLY_CAPTURE_TOOL   tool version recorded in each capture's JSON (default editor-capture-5)
CAPTURE_TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIGHTLY_REPO="${LIGHTLY_REPO:-$(cd "$CAPTURE_TOOLS_DIR/../../.." && pwd)}"
LIGHTLY_DD_UNIT="${LIGHTLY_DD_UNIT:-/tmp/lightly-dd-unit}"
LIGHTLY_DD_UI="${LIGHTLY_DD_UI:-/tmp/lightly-dd-ui}"
LIGHTLY_ARTIFACTS="${LIGHTLY_ARTIFACTS:-$HOME/.codex/artifacts/lightly/v1}"
LIGHTLY_TOOLS_BIN="${LIGHTLY_TOOLS_BIN:-${TMPDIR:-/tmp}/lightly-capture-tools}"
LIGHTLY_SHEETS_DIR="${LIGHTLY_SHEETS_DIR:-$LIGHTLY_ARTIFACTS/sheets}"
LIGHTLY_CAPTURE_TOOL="${LIGHTLY_CAPTURE_TOOL:-editor-capture-5}"

# swift_tool <name>: path of the compiled helper <name>.swift, compiled when missing or older than
# its source (swiftc on a one-file script is not a heavy job: no simulator, no xcodebuild).
swift_tool() {
  local name=$1 bin="$LIGHTLY_TOOLS_BIN/$1"
  mkdir -p "$LIGHTLY_TOOLS_BIN"
  if [ ! -x "$bin" ] || [ "$CAPTURE_TOOLS_DIR/$name.swift" -nt "$bin" ]; then
    xcrun swiftc -O "$CAPTURE_TOOLS_DIR/$name.swift" -o "$bin" >&2 || return 1
  fi
  printf '%s' "$bin"
}
