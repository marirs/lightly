#!/bin/sh
# Fails unless a BUILT Lightly.app carries its app icon.
#
#   scripts/check_app_icon.sh path/to/Lightly.app     # any built product, e.g. before installing it
#   (no argument)                                       # from the Lightly target's last build phase
#
# It inspects the product, not the sources: an asset catalog that exists in the repository but is
# missing from the target's Resources phase (as happened before c1a5fcf) still produces an app with
# the blank placeholder icon, and only the built bundle shows that. Checks:
#   1. Info.plist: CFBundleIcons > CFBundlePrimaryIcon > CFBundleIconName == AppIcon,
#      and CFBundlePrimaryIcon > CFBundleIconFiles is not empty
#   2. Assets.car exists and contains AppIcon renditions (xcrun assetutil --info)
#   3. the loose iPhone home-screen icon actool emits for pre-iOS 18 deployment targets
#      (AppIcon60x60@2x.png) is in the bundle
set -eu

icon_name="AppIcon"

if [ $# -ge 1 ]; then
    app="$1"
else
    : "${TARGET_BUILD_DIR:?pass the .app path, or run from Xcode}"
    : "${WRAPPER_NAME:?run from Xcode}"
    app="${TARGET_BUILD_DIR}/${WRAPPER_NAME}"
fi

failures=0
fail() {
    echo "error: App icon check: $1 (${app})"
    failures=$((failures + 1))
}

plist="${app}/Info.plist"
if [ ! -f "$plist" ]; then
    fail "Info.plist is missing"
else
    name=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName" "$plist" 2>/dev/null || true)
    [ "$name" = "$icon_name" ] || fail "Info.plist CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconName is '${name}', expected '${icon_name}'"
    files=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles:0" "$plist" 2>/dev/null || true)
    [ -n "$files" ] || fail "Info.plist CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconFiles is missing or empty"
fi

car="${app}/Assets.car"
if [ ! -f "$car" ]; then
    fail "Assets.car is missing"
else
    renditions=$(xcrun --sdk iphonesimulator assetutil --info "$car" 2>/dev/null | grep -c "\"Name\" : \"${icon_name}\"" || true)
    [ "$renditions" -gt 0 ] || fail "Assets.car has no '${icon_name}' renditions"
fi

[ -f "${app}/${icon_name}60x60@2x.png" ] || fail "${icon_name}60x60@2x.png (home-screen icon) is missing"

if [ "$failures" -gt 0 ]; then
    exit 1
fi
echo "App icon check passed: ${icon_name} in Info.plist, ${renditions} renditions in Assets.car, ${icon_name}60x60@2x.png present"
