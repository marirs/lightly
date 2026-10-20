# Sunglasses (1.1): open issues

Status as of 2026-10-20, master at 672f563. Production behaviour is
unchanged: `minFaceLogit` stays 0, and any face below it shows the
existing "eyes not visible" state.

## Unresolved photos

Both photos stay on "eyes not visible". Neither is fixed.

### profile_beard_man_01 — missing pair (unresolved bug)

- The face landmarker can't read this photo. Its score swings from run
  to run (−2.1, −3.0, −4.6, −5.3) and always stays below the cut-off.
  Every crop, brightness lift and mirror tried gave a wrong mesh. Some
  crops scored +4.5 to +5.0, but the irises landed on the forehead.
- The pose model (option 2) was checked before any integration and
  fails:
  - Head-only crops: presence 0.0–0.19, with all the points collapsed
    together.
  - Body-shaped crops: presence 0.95–0.99, but the eye point sits on
    the cheek, about 90 px or more from the real eye, and the nose and
    ear miss by about 300 px or more (1600 px image).
  - Real positions in the 1600 px image: eye ≈ (530, 740), nose tip
    ≈ (240, 910), ear ≈ (1080, 1040).
- Not integrated.

### profile_bw_woman_hair_01 — blown-hair woman (unresolved)

- Score about −1.2 to −1.5, below the cut-off, although her mesh looks
  right.
- A geometry check that would allow placement was investigated, and
  none is reliable enough on the photos we have:
  - Iris contrast (is the iris darker than the ring around it?): wrong
    meshes read as high as 1.00, and right meshes as low as −0.27.
  - Crop-shift drift (how far, in iris radii, the iris moves when the
    face box shifts 8%): wrong low-score variants moved 4.8 or more,
    right ones 1.3–3.4. But the beard man's wrong mesh (3.3) is as
    steady as her right one (2.3), and some good high-score faces
    move 10–11.
  - A combined rule (score ≥ −2, contrast > 0.15, drift < 4) would
    rest on only three right low-score examples, and the run-to-run
    swing in the score makes any threshold unstable.
- The cut-off is not lowered globally on the strength of one photo.
- A fallback needs more real low-score photos whose landmarks are known
  to be right, to measure a check against.

### Diagnostics

The review-only tests in `ios/Tests/LightlyTests/SunglassesEngineTests.swift`
(commit 672f563) are skipped unless `LIGHTLY_SUNGLASSES_MATRIX=1` is set:

- `testLandmarkerExposureDiagnosticIsPrinted`
- `testIrisContrastDiagnosticIsPrinted`
- `testLowLogitVariantsArePrinted`

They aren't part of the app, and they don't run in normal test runs.

## Remaining checks — UNVERIFIED

None of these has been verified on the current build (c118144 or
later). Each one stays **untested** until it's checked on a real device
and the evidence is recorded.

| Check | Status |
|---|---|
| iPhone SE 3: full sunglasses pass (only partly checked; a low-battery alert covered the screenshots) | UNVERIFIED |
| Android foldable (unfolded) and Duo two-pane layouts | UNVERIFIED |
| VoiceOver (iOS) | UNVERIFIED |
| TalkBack (Android) | UNVERIFIED |
| Tilted thin-metal woman: brows sit under the Club's rim | UNVERIFIED (open defect) |
| A real Android 17 phone | UNVERIFIED |

Checked on c118144: moto edge 60, Nothing A069 and iPhone 11 Pro Max,
for the captured scenarios only. That doesn't cover the rows above.
