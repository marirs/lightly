#!/bin/bash
# build-apk.sh: builds the debug APK (incremental; never clean or --rerun-tasks) and records what it was
# built from next to it, so every capture can name its source.
# Run it through scripts/heavy:  scripts/heavy android-apk android/tools/capture/build-apk.sh
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
export JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
(cd "$REPO/android" && ./gradlew :app:assembleDebug --console=plain -q)
APK="$REPO/android/app/build/outputs/apk/debug/app-debug.apk"
"$(dirname "$0")/source-fingerprint.sh" > "$APK.build-info.tmp"
python3 - "$APK" <<'PY'
import hashlib, json, sys
apk = sys.argv[1]
info = dict(line.split("=", 1) for line in open(apk + ".build-info.tmp").read().split())
info["apk_sha256"] = hashlib.sha256(open(apk, "rb").read()).hexdigest()
json.dump(info, open(apk + ".build-info.json", "w"), indent=2)
print(json.dumps(info))
PY
rm "$APK.build-info.tmp"
