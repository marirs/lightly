#!/bin/sh
# Writes Lightly.app/BuildInfo.json {"version": "1.0.0", "build": "261005052"} from scripts/version.sh, on every build,
# including builds made from the Xcode IDE (which do not pass CURRENT_PROJECT_VERSION). AppVersion prefers it, so About
# shows the real version and build ("1.0.0-dev" for uncommitted changes) instead of the project's placeholder 0.
# Run by the unsandboxed LookPack aggregate target (it reads git); see ios/project.yml.
set -eu
: "${LIGHTLY_REPO_ROOT:?set in ios/project.yml}"
: "${BUILT_PRODUCTS_DIR:?run from Xcode}"
: "${LIGHTLY_APP_WRAPPER_NAME:?set by the LookPack target}"
destination="${BUILT_PRODUCTS_DIR}/${LIGHTLY_APP_WRAPPER_NAME}"
mkdir -p "$destination"
if version=$(sh "${LIGHTLY_REPO_ROOT}/scripts/version.sh" 2>/dev/null); then
    printf '{"version": "%s", "build": "%s"}\n' "${version% *}" "${version#* }" > "$destination/BuildInfo.json"
else
    echo "warning: no git version (not a checkout?); About shows the Info.plist values"
    rm -f "$destination/BuildInfo.json"
fi
