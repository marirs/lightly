#!/bin/sh
# Copies the ink pack (format "lightly-ink-pack" 1: inks.json, img/*.png|jpg, thumb/*.png|jpg) into the app bundle
# as `InkPack/` (Effects › Ink, owner-approved 2026-10-31: photographed ink scans).
#
# Run by the "LookPack" aggregate target, next to bundle_look_pack.sh and for the same reason (see ios/project.yml):
# the pack's location is resolved at build time and its file names come from the manifest, which the user-script
# sandbox cannot declare. The pack is built by shared/ink/build_inks.py and is git-ignored (like the leak pack, the
# scans stay out of the repository), so it is looked up rather than committed:
#   1. $LIGHTLY_INK_PACK_DIR, when set (CI, or a pack built elsewhere)
#   2. this checkout's shared/ink/out ($LIGHTLY_REPO_ROOT is the repository root; the Xcode project is in ios/)
#   3. when building from a .claude/worktrees/<name> worktree, which does not carry ignored files:
#      the main checkout's shared/ink/out, derived from that layout
#
# No pack is not an error: the build succeeds with a warning and Effects › Ink offers only None. A pack of
# another format IS an error, for the look pack's reason: it would ship a gallery with no inks. The app checks
# each image's SHA-256 in the tests (InkPackTests) and refuses an unreadable manifest at load.
set -eu

: "${LIGHTLY_REPO_ROOT:?set in ios/project.yml}"
: "${BUILT_PRODUCTS_DIR:?run from Xcode}"
: "${LIGHTLY_APP_WRAPPER_NAME:?set by the LookPack target in ios/project.yml}"

# iOS app bundles are flat: resources live at the wrapper's root.
destination="${BUILT_PRODUCTS_DIR}/${LIGHTLY_APP_WRAPPER_NAME}/InkPack"
expected_format="lightly-ink-pack"
expected_format_version=1

candidates=""
if [ -n "${LIGHTLY_INK_PACK_DIR:-}" ]; then
    candidates="${LIGHTLY_INK_PACK_DIR}"
fi
candidates="${candidates}
${LIGHTLY_REPO_ROOT}/shared/ink/out"
case "${LIGHTLY_REPO_ROOT}" in
    */.claude/worktrees/*)
        main_checkout="${LIGHTLY_REPO_ROOT%%/.claude/worktrees/*}"
        candidates="${candidates}
${main_checkout}/shared/ink/out"
        ;;
esac

source_dir=""
old_ifs="$IFS"
IFS='
'
for candidate in $candidates; do
    if [ -f "${candidate}/inks.json" ]; then
        source_dir="$candidate"
        break
    fi
done
IFS="$old_ifs"

# Always start from an empty destination: inks left over from an earlier build must never be shipped after their
# source disappeared, and two packs must never mix.
rm -rf "$destination"

if [ -z "$source_dir" ]; then
    echo "warning: No ink pack found (set LIGHTLY_INK_PACK_DIR or run shared/ink/build_inks.py). Ink will offer only None."
    exit 0
fi

# build_inks.py writes "format" and "formatVersion" as the manifest's first keys; read them without a JSON tool.
header=$(head -c 4096 "${source_dir}/inks.json" | tr -d '\n')
format=$(printf '%s' "$header" | sed -n 's/.*"format"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
format_version=$(printf '%s' "$header" | sed -n 's/.*"formatVersion"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n 1)
if [ "${format:-}" != "${expected_format}" ] || [ "${format_version:-}" != "${expected_format_version}" ]; then
    echo "error: Ink pack at ${source_dir} is ${format:-unknown} ${format_version:-unknown}; this app reads ${expected_format} ${expected_format_version}. Rebuild it with shared/ink/build_inks.py."
    exit 1
fi

mkdir -p "${destination}/img" "${destination}/thumb"
cp "${source_dir}/inks.json" "${destination}/inks.json"
# Only the JPEGs the manifest's entries point at live in these folders; anything else in out/ is not read.
find "${source_dir}/img" -maxdepth 1 -type f \( -name 'ink-*.png' -o -name 'ink-*.jpg' \) -exec cp {} "${destination}/img/" \;
find "${source_dir}/thumb" -maxdepth 1 -type f \( -name 'ink-*.png' -o -name 'ink-*.jpg' \) -exec cp {} "${destination}/thumb/" \;
echo "Bundled ink pack (${format} ${format_version}) from ${source_dir}"
