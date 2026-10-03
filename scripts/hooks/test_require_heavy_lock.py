"""Cases for require_heavy_lock.py. Run: python3 scripts/hooks/test_require_heavy_lock.py"""
import unittest

from require_heavy_lock import command_bypasses_lock

REFUSED = [
    "cd ios && xcodebuild test -scheme X | tail",
    "cd android && ./gradlew test",
    "scripts/heavy x true; ./gradlew assembleDebug",
    "xcrun simctl boot FA7C",
    "xcrun simctl io booted screenshot a.png",
    "~/Library/Android/sdk/emulator/emulator -avd P9 -no-window &",
    "nohup ~/Library/Android/sdk/emulator/emulator -avd P9 > /dev/null 2>&1 &",
    "OMP_NUM_THREADS=2 time xcodebuild build",
    "bash -c 'cd ios; xcodebuild test'",
    "open -a Simulator",
    "swift test --package-path shared",
    "echo $(xcodebuild -version)",
]
ALLOWED = [
    "scripts/heavy ios-unit xcodebuild test -scheme X | tail -5",
    "cd ios && ../scripts/heavy ios-unit xcodebuild test 2>&1 | grep -E 'error:'",
    "/Users/sg/Documents/Dev/Projects/lightly/scripts/heavy l bash -c 'cd ios; xcodebuild test; xcrun simctl io booted screenshot a.png'",
    "scripts/heavy android bash -c \"cd android && ./gradlew test\"",
    "xcrun simctl list devices",
    "git log --grep xcodebuild",
    "grep -E 'xcodebuild|gradlew' notes.md",
    "pgrep -f qemu-system",
    "adb -s ZY22MQNLBJ shell getprop",
    "git status && git diff --stat",
]


class RequireHeavyLockTests(unittest.TestCase):
    def test_refuses_unwrapped_heavy_commands(self):
        for command in REFUSED:
            with self.subTest(command=command):
                self.assertTrue(command_bypasses_lock(command))

    def test_allows_wrapped_or_light_commands(self):
        for command in ALLOWED:
            with self.subTest(command=command):
                self.assertFalse(command_bypasses_lock(command))


if __name__ == "__main__":
    unittest.main()
