# Six loading states — physical phone review, 2026-11-09

Scope explicitly requested by the owner: opening, Auto, subject separation,
depth/blur, Eraser and saving, on all four test phones in light and dark.
No commit or reference-baseline update is authorised by this review.

## Method and build

These runs use real photo loading, Auto analysis, subject/depth inference,
inpainting and photo-library export. An opt-in diagnostic flag pauses those
operations long enough to inspect their otherwise brief loading states. It does
not inject successful results. The pause is absent on normal launches and in
release builds. These timings are not performance measurements.

- iOS: build `261109005`, base `22759720058b815088bc74a700bbc8795e5e4e59` plus the working changes.
- Production diff SHA-256: `daafe23d354f1bfc6c66234ec1b5ff93af21e037087190531397e6e0fe361267`.
- Android APK SHA-256: `a88eee6508fd63c3c6733eea493e759403c22b5fadbc9c386c100be9f650734e`.
- Evidence: `~/.codex/artifacts/lightly/processing-1.2/` (private).
- iOS XCTest: `ProcessingDeviceUITests.testSixLoadingStates`.
- Android: real UI interaction via ADB/UIAutomator; theme selected through More.
- Diagnostic dwell: 12 seconds; iOS depth uses 40 seconds because subject and depth
  run concurrently and both states must be separately visible.

Each state is checked for a standard animated spinner at the screen centre,
uniform dimming across the app, no visible loading copy or separate Cancel
control, blocked toolbar taps, and completion back to usable controls. Eraser
must clear its draft and enable Undo; saving must reach the saved-photo sheet.
Native screenshots are inspected; animation is checked using distinct frames
from the iOS recordings or paired Android screenshots.

## Coverage

| Physical phone | Light: six states | Dark: six states |
| --- | --- | --- |
| iPhone 11 Pro Max | Verified | Verified |
| iPhone SE 3 | Verified | Verified |
| moto edge 60 | Verified | Verified |
| Nothing A069 | Verified | Verified |

All 48 requested state/device/theme combinations are verified. The four iOS
test runs and four Android runs completed real operations successfully. Each
state has inspected native screenshots and animation evidence; the clean moto
dark saving retake below supersedes its notification-obscured capture.

All four phones were relaunched normally without the inspection flag after the
checks. Android appearance was restored to Light on moto and Dark on Nothing;
iOS launches no longer override the stored appearance. The installed builds
remain available for owner review. The production source fingerprint still
matches the tested build, and `git diff --check` passes. Nothing was committed.

## Review corrections

- The first iOS assertion incorrectly matched the existing toolbar Close icon's
  accessibility label, “Cancel”. Its screenshot showed the expected dimmed Close
  icon, not a loading Cancel button. The corrected check tests visible Cancel
  text and physically attempts the blocked toolbar action. The full run then passed.
- A system battery notification obscured the moto dark saving screenshot.
  It was not accepted. `moto-save-r3-dark` contains the clean repeated save check,
  with animation and blocked taps verified. The earlier screenshot is retained as
  superseded evidence. The first retake did not observe saving; the corrected
  setup waits for the editor to settle before tapping Save, and passed.

The 31 Android Edit/Effects unit tests also pass on this source revision.
This review covers the requested loading states, not broad inpainting quality,
foldable/tablet layouts or a full accessibility-service audit.
