#!/bin/sh
# Copies the Look pack (manifest.json + luts/*.f32) into the app bundle as `LookPack/`.
#
# Run by the "LookPack" aggregate target, which the Lightly app target depends on (see project.yml for
# why it is a separate target). The pack is derived from the private
# preset collection and is git-ignored, so it is looked up rather than committed (spec §4.5):
#   1. $LIGHTLY_LOOK_PACK_DIR, when set (CI, or a pack built elsewhere)
#   2. this checkout's experiments/presets/look_pack/out
#   3. when building from a .claude/worktrees/<name> worktree, which does not carry ignored files:
#      the main checkout's experiments/presets/look_pack/out, derived from that layout (the same
#      lookup as the LUT golden set in Tests/LightlyTests/LUTGoldenTests.swift)
#
# No pack is not an error: the build succeeds with a warning and the app says "No Looks are
# available in this build." The app validates the pack (format, dimension, sizes, sha256) at load;
# this script only copies, so a bad pack is reported by the app rather than hidden by the build.
set -eu

: "${SRCROOT:?run from Xcode}"
: "${BUILT_PRODUCTS_DIR:?run from Xcode}"
: "${LIGHTLY_APP_WRAPPER_NAME:?set by the LookPack target in project.yml}"

# iOS app bundles are flat: resources live at the wrapper's root.
destination="${BUILT_PRODUCTS_DIR}/${LIGHTLY_APP_WRAPPER_NAME}/LookPack"

candidates=""
if [ -n "${LIGHTLY_LOOK_PACK_DIR:-}" ]; then
    candidates="${LIGHTLY_LOOK_PACK_DIR}"
fi
candidates="${candidates}
${SRCROOT}/experiments/presets/look_pack/out"
case "${SRCROOT}" in
    */.claude/worktrees/*)
        main_checkout="${SRCROOT%%/.claude/worktrees/*}"
        candidates="${candidates}
${main_checkout}/experiments/presets/look_pack/out"
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
# shipped after its source disappeared, and Looks from two packs must never mix.
rm -rf "$destination"

if [ -z "$source_dir" ]; then
    echo "warning: No Look pack found (set LIGHTLY_LOOK_PACK_DIR or run experiments/presets/look_pack/build_look_pack.py). The app will show no Looks."
    exit 0
fi

mkdir -p "${destination}/luts"
cp "${source_dir}/manifest.json" "${destination}/manifest.json"
# Only the LUT files: anything else in out/ (notes, caches) is not part of the pack contract.
find "${source_dir}/luts" -maxdepth 1 -type f -name '*.f32' -exec cp {} "${destination}/luts/" \;
echo "Bundled Look pack from ${source_dir}"
