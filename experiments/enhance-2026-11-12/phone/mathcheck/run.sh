#!/bin/bash
# Enhance step 2d: checks that the phone harnesses' image maths give bit-identical results to an earlier commit's
# (default 8f37b2f, step 2c) on the same deterministic workloads, and times both. Kotlin runs on the Mac's JVM, Swift
# as a Mac executable; both use only the files' image-maths sections (no Android, TFLite or Core ML).
# Run: phone/mathcheck/run.sh [commit]   (from experiments/enhance-2026-11-12; writes to a temporary folder)
set -eu
OLD=${1:-8f37b2f}
HERE=$(cd "$(dirname "$0")" && pwd)
PHONE=$(dirname "$HERE")
WORK=$(mktemp -d)
export JAVA_HOME=${JAVA_HOME:-'/Applications/Android Studio.app/Contents/jbr/Contents/Home'}
KOTLINC=${KOTLINC:-'/Applications/Android Studio.app/Contents/plugins/Kotlin/kotlinc/bin/kotlinc'}
cd "$WORK"
git -C "$PHONE" show "$OLD:experiments/enhance-2026-11-12/phone/EnhancePipeline.kt" > old.kt
git -C "$PHONE" show "$OLD:experiments/enhance-2026-11-12/phone/EnhancePipelineTests.swift" > old.swift

echo "== Kotlin (JVM)"
python3 "$HERE/extract.py" old.kt old Old.kt
python3 "$HERE/extract.py" "$PHONE/EnhancePipeline.kt" fresh Fresh.kt
sed 's/PKG/old/' "$HERE/Check.kt.in" > CheckOld.kt
sed 's/PKG/fresh/' "$HERE/Check.kt.in" > CheckFresh.kt
"$KOTLINC" Old.kt Fresh.kt CheckOld.kt CheckFresh.kt "$HERE/Main.kt" -include-runtime -d check.jar 2>&1 | grep -v '^warning' || true
"$JAVA_HOME/bin/java" -Xmx6g -jar check.jar

echo "== Swift (Mac)"
for v in old new; do
  src=old.swift; [ $v = new ] && src="$PHONE/EnhancePipelineTests.swift"
  mkdir -p swift-$v
  { echo "import Foundation"; sed -n '/^\/\/ MARK: - Image maths/,$p' "$src"; cat "$HERE/check.swift.in"; } > swift-$v/main.swift
  swiftc -O swift-$v/main.swift -o check-$v
  ./check-$v > out-$v.txt
done
paste -d'|' out-old.txt out-new.txt
if diff <(grep ' ms$' out-old.txt | awk '{print $(NF-2)}') <(grep ' ms$' out-new.txt | awk '{print $(NF-2)}') >/dev/null; then
  echo "SWIFT ALL IDENTICAL"
else
  echo "SWIFT MISMATCH"; exit 1
fi
rm -rf "${WORK:?}"
