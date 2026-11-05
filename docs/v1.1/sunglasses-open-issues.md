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
| iPhone SE 3: full sunglasses pass (only partly checked; a low-battery alert covered the screenshots) | VERIFIED 2026-11-05 on build 1.1.0 (261102001), light and dark, `PortraitBorderDeviceUITests`: Oval and Club applied on a photo with the person's own glasses ("Glasses found", replaced), brown lens, Darkness 75 → 30 with Undo/Redo, saved copy reopened and matching. Same pass on iPhone 11 Pro Max, light and dark. The dark SE run used the previous run's saved copy (sunglasses already applied). Not covered: the full pair × lens matrix on a phone |
| Android foldable (unfolded) and Duo two-pane layouts | UNVERIFIED |
| VoiceOver (iOS) | UNVERIFIED — deferred to the last release with the full VoiceOver/TalkBack pass (owner, 2026-10-21) |
| TalkBack (Android) | UNVERIFIED — deferred to the last release with the full VoiceOver/TalkBack pass (owner, 2026-10-21) |
| Tilted thin-metal woman: brows sit under the Club's rim | Investigated 2026-11-01, not changed (below) |
| A real Android 17 phone | UNVERIFIED |

Checked on c118144: moto edge 60, Nothing A069 and iPhone 11 Pro Max,
for the captured scenarios only. That doesn't cover the rows above.

## Tilted thin-metal woman: brows (investigated 2026-11-01)

`glasses_thin_metal_01`, iPhone 17 simulator, removal-only and pair-matrix review tests (photos filter
`LIGHTLY_SUNGLASSES_PHOTOS`):

- Her brows lie inside every pair's outline: the pairs are fitted to the eye corners and face width, and
  her brows sit close above her eyes. At the default lens darkness (transmission about 0.2) her eyes
  still show through the lens, but her brows don't.
- The paint-out also repaints both brows: the segmenter counts dark brows beside a rim as part of the
  glasses, so the 0.8 % mask covers them.
- Tried and dropped (engine unchanged):
  - Keeping MediaPipe's brow strips (upper contour 70/63/105/66/107 and 300/293/334/296/336, lower
    46/53/52/65/55 and 276/283/282/295/285) out of the mask. It brings the brows back in the
    removal-only image, but her old rim runs through the strips, so grey rim pieces come back with
    them. Keeping only the upper 60 % of each strip leaves fewer pieces. With a pair on, both
    versions look the same as before at the default darkness.
  - Measuring the painted area's top from the patch's painted pixels instead of its rectangle. It
    made no difference on this photo.
- Still open: with a light lens, the repainted brows (or rim pieces, if the strips are kept) would
  show. Separating the rim from the brows needs a rim-only signal that the 256 px segmenter doesn't
  give.
