#!/bin/sh
# Copies the sunglasses pack (format "lightly-sunglasses-pack" 1: sunglasses.json, mesh/*.lsg, tex/*, thumb/*.png)
# into the app bundle as `SunglassesPack/` (Portrait › Sunglasses, owner-approved design portrait-sunglasses-v2,
# 2026-10-13: the ten purchased 3D pairs).
#
# Run by the "LookPack" aggregate target next to bundle_leak_pack.sh, for the same reason: the pack is built by
# shared/sunglasses/build_sunglasses.py and is git-ignored (the purchased models never enter the repository), so it is
# looked up rather than committed:
#   1. $LIGHTLY_SUNGLASSES_PACK_DIR, when set
#   2. this checkout's shared/sunglasses/out
#   3. from a .claude/worktrees/<name> worktree: the main checkout's shared/sunglasses/out
#
# No pack is not an error: the build warns and the Sunglasses row offers only None. A pack of another format IS an
# error. The app checks every file's SHA-256 against the manifest when it loads a pair.
set -eu

: "${LIGHTLY_REPO_ROOT:?set in ios/project.yml}"
: "${BUILT_PRODUCTS_DIR:?run from Xcode}"
: "${LIGHTLY_APP_WRAPPER_NAME:?set by the LookPack target in ios/project.yml}"

destination="${BUILT_PRODUCTS_DIR}/${LIGHTLY_APP_WRAPPER_NAME}/SunglassesPack"
expected_format="lightly-sunglasses-pack"
expected_format_version=1

candidates=""
if [ -n "${LIGHTLY_SUNGLASSES_PACK_DIR:-}" ]; then
    candidates="${LIGHTLY_SUNGLASSES_PACK_DIR}"
fi
candidates="${candidates}
${LIGHTLY_REPO_ROOT}/shared/sunglasses/out"
case "${LIGHTLY_REPO_ROOT}" in
    */.claude/worktrees/*)
        main_checkout="${LIGHTLY_REPO_ROOT%%/.claude/worktrees/*}"
        candidates="${candidates}
${main_checkout}/shared/sunglasses/out"
        ;;
esac

source_dir=""
old_ifs="$IFS"
IFS='
'
for candidate in $candidates; do
    if [ -f "${candidate}/sunglasses.json" ]; then
        source_dir="$candidate"
        break
    fi
done
IFS="$old_ifs"

# Always start empty: pairs from an earlier build must never ship after their source disappeared.
rm -rf "$destination"

if [ -z "$source_dir" ]; then
    echo "warning: No sunglasses pack found (set LIGHTLY_SUNGLASSES_PACK_DIR or run shared/sunglasses/build_sunglasses.py). Sunglasses will offer only None."
    exit 0
fi

header=$(head -c 4096 "${source_dir}/sunglasses.json" | tr -d '\n')
format=$(printf '%s' "$header" | sed -n 's/.*"format"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
format_version=$(printf '%s' "$header" | sed -n 's/.*"formatVersion"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n 1)
if [ "${format:-}" != "${expected_format}" ] || [ "${format_version:-}" != "${expected_format_version}" ]; then
    echo "error: Sunglasses pack at ${source_dir} is ${format:-unknown} ${format_version:-unknown}; this app reads ${expected_format} ${expected_format_version}. Rebuild it with shared/sunglasses/build_sunglasses.py."
    exit 1
fi

mkdir -p "${destination}/mesh" "${destination}/tex" "${destination}/thumb"
cp "${source_dir}/sunglasses.json" "${destination}/sunglasses.json"
# Only the pack's own file kinds; the builder's _normalised/ work folder is never copied.
find "${source_dir}/mesh" -maxdepth 1 -type f -name 'sun-*.lsg' -exec cp {} "${destination}/mesh/" \;
find "${source_dir}/tex" -maxdepth 1 -type f \( -name 'sun-*.jpg' -o -name 'sun-*.png' \) -exec cp {} "${destination}/tex/" \;
find "${source_dir}/thumb" -maxdepth 1 -type f -name 'sun-*.png' -exec cp {} "${destination}/thumb/" \;
echo "Bundled sunglasses pack (${format} ${format_version}) from ${source_dir}"
