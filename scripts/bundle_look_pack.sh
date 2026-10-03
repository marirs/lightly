#!/bin/sh
# Copies the Develop preset pack (format 3: manifest.json, plus luts/*.f32 overrides when any exist)
# into the app bundle as `LookPack/`.
#
# Run by the "LookPack" aggregate target, which the Lightly app target depends on (see ios/project.yml for
# why it is a separate target). The pack is generated from the private preset collection by
# shared/look-pack/build_pack.py and is git-ignored, so it is looked up rather than committed:
#   1. $LIGHTLY_LOOK_PACK_DIR, when set (CI, or a pack built elsewhere)
#   2. this checkout's shared/look-pack/out ($LIGHTLY_REPO_ROOT is the repository root; the Xcode
#      project itself is in ios/)
#   3. when building from a .claude/worktrees/<name> worktree, which does not carry ignored files:
#      the main checkout's shared/look-pack/out, derived from that layout
#
# No pack is not an error: the build succeeds with a warning and Develop says no presets are available.
# A pack of another format IS an error: shipping it would show no presets at all, so the build stops
# here instead of the problem being found on a device. The app still validates the whole pack at
# load (format, recipe version, model constants, catalogue digest, every recipe).
# v3 differs: format 2 (experiments/presets/look_pack/out, one 33³ LUT file per Look) is retired; a
# format-2 pack is now refused.
set -eu

: "${LIGHTLY_REPO_ROOT:?set in ios/project.yml}"
: "${BUILT_PRODUCTS_DIR:?run from Xcode}"
: "${LIGHTLY_APP_WRAPPER_NAME:?set by the LookPack target in ios/project.yml}"

# iOS app bundles are flat: resources live at the wrapper's root.
destination="${BUILT_PRODUCTS_DIR}/${LIGHTLY_APP_WRAPPER_NAME}/LookPack"
expected_format_version=3

candidates=""
if [ -n "${LIGHTLY_LOOK_PACK_DIR:-}" ]; then
    candidates="${LIGHTLY_LOOK_PACK_DIR}"
fi
candidates="${candidates}
${LIGHTLY_REPO_ROOT}/shared/look-pack/out"
case "${LIGHTLY_REPO_ROOT}" in
    */.claude/worktrees/*)
        main_checkout="${LIGHTLY_REPO_ROOT%%/.claude/worktrees/*}"
        candidates="${candidates}
${main_checkout}/shared/look-pack/out"
        ;;
esac

source_dir=""
old_ifs="$IFS"
IFS='
'
for candidate in $candidates; do
    if [ -f "${candidate}/manifest.json" ]; then
        source_dir="$candidate"
        break
    fi
done
IFS="$old_ifs"

# Always start from an empty destination: a pack left over from an earlier build must never be
# shipped after its source disappeared, and presets from two packs must never mix.
rm -rf "$destination"

if [ -z "$source_dir" ]; then
    echo "warning: No preset pack found (set LIGHTLY_LOOK_PACK_DIR or run shared/look-pack/build_pack.py). Develop will offer no presets."
    exit 0
fi

# The manifest is compact JSON with formatVersion near the start; read it without a JSON tool.
format_version=$(head -c 4096 "${source_dir}/manifest.json" | sed -n 's/.*"formatVersion"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n 1)
if [ "${format_version:-}" != "${expected_format_version}" ]; then
    echo "error: Preset pack at ${source_dir} is format ${format_version:-unknown}; this app reads format ${expected_format_version}. Rebuild it with shared/look-pack/build_pack.py."
    exit 1
fi

mkdir -p "${destination}"
cp "${source_dir}/manifest.json" "${destination}/manifest.json"
# Only Lightroom HALD overrides (none exist yet); unconverted.json and anything else in out/ are build
# records, not part of what the app reads.
if [ -d "${source_dir}/luts" ] && [ -n "$(find "${source_dir}/luts" -maxdepth 1 -type f -name '*.f32' | head -n 1)" ]; then
    mkdir -p "${destination}/luts"
    find "${source_dir}/luts" -maxdepth 1 -type f -name '*.f32' -exec cp {} "${destination}/luts/" \;
fi
echo "Bundled preset pack (format ${format_version}) from ${source_dir}"
