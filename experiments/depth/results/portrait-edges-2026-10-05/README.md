# Background replacement: portrait hair edges (investigation closed 2026-10-05, defects unresolved)

**Status: three open release blockers. Not fixed. Nothing here is a release approval.**
The current implementation (`a5a4b48`, rendering-v2 revision 5: foreground-colour estimate; Android MODNet
portrait matting `c37eddf`) is an **experimental checkpoint**, not a release-approved fix. Passing the shared
rendering goldens shows each platform matches the reference implementation, not that the image quality is
acceptable. No rendering baseline was regenerated to accept these results.

| # | Defect | Platform | Seen in |
|---|---|---|---|
| 1 | Red wall colour stays in the curls after replacement (light and dark backgrounds) | iOS | `portrait_medium_02`, preview and saved copy |
| 2 | Teal cast in the curls (dark background; a little on light) | Android | `portrait_medium_02`, saved copy |
| 3 | Grey haze around the hair; hair texture lost in it | Android | both portraits, worst on light background |

Comparison sheet (saved copies, both portraits, light `#F4F1EC` and dark `#1F2328`, iOS and Android, 1:1 hair
detail per tile): `../portrait-edges-2026-10-05.jpg`.

## What was measured

Measurements, not ground truth. There is no ground-truth alpha or foreground for these photos.

- **iOS matte (Apple Vision `VNGenerateForegroundInstanceMaskRequest`).** The simulator cannot run the request;
  simulator runs use mattes recorded on macOS (`ios/Tests/Fixtures/SubjectMattes`). A live run on an iPhone 11 Pro
  Max (iOS 27.0.1, DEBUG build, `--dump-subject-matte`) produced `live-pm02-matte.png` and `live-pd03-matte.png`:
  IoU against the recorded macOS mattes 0.992 and 0.994, mean absolute difference 0.08 in the soft band. At the
  pixels where the iOS saved copy of `portrait_medium_02` stays red, the median matte value is 1.0 in both the live
  and the recorded matte: the composite treats them as fully subject, so the foreground estimate (which only acts
  where 0 < alpha < 1) cannot change them. Live **saved copies** from the device are **pending**: no file appeared
  within 45 s, then the device connection dropped.
- **Android: colour correction off vs on, everything else fixed** (offline reproduction `stages.py`, validated
  against the emulator's saved copies: mean |difference| 0.8 / 0.5 of 255 for `portrait_medium_02` dark / light,
  2.4 for `portrait_deep_03` light). `portrait_medium_02`, dark background, head region, soft band:
  correction off: 325 teal pixels, red excess 17.8; on: 52,733 teal pixels, red excess 1.3. The teal appears only
  with the foreground estimate. At those pixels MODNet's alpha (working size) has median 0.62, and the estimated
  foreground's red channel is clipped to 0 in 74 % of them.
- **Inference, not established:** if the hair there were neutral, the compositing equation with the estimator's own
  background estimate would need alpha ≈ 0.99 (median). This suggests MODNet underestimates opacity in dense curls
  over the saturated wall and the estimate then over-subtracts red. It does **not** prove the estimator is correct:
  its background estimate at those pixels (sRGB ≈ 188, 98, 95) differs from the nearby wall (≈ 167, 37, 36).
- **Refinement tried and failed (one, fixed a priori):** colour guided filter on MODNet's alpha (guide = photo,
  r = 8 px at 1600, eps = 1e-4). Teal pixels 56,379 → 55,298 (no meaningful change); haze worse on
  `portrait_deep_03` (ring deviation from the replacement 15.1 → 18.8 light, 3.0 → 4.3 dark). Not adopted.
  Speculative hair corrections are stopped.

## Files

Tracked here: `live-*-matte.png` (live device Vision mattes), `*-modnet-alpha-*.png` (MODNet alpha at the display
size 1600 and the Save-copy working size 768), `*-foreground-estimate-*.png` (Germer estimate F at 768, sRGB).
Recorded macOS mattes: `ios/Tests/Fixtures/SubjectMattes/portrait_{medium_02,deep_03}.png`.

Untracked, on disk (`experiments/depth/out/portrait-edges-2026-10-05/`, ignored by `experiments/depth/.gitignore`):
input photos (`iosbg/pm02_12mp.jpg` sha256 ae21969b…, `iosbg/pd03_full.jpg` sha256 8d82056f…), iOS simulator
previews and saved copies (`iosbg/`), Android saved copies (`fg-*` MODNet + estimate, `mn-*` MODNet only, `ca-*`
selfie segmenter baseline), per-stage arrays (`stages/*.npz`: alpha, I, F, output off/on, Android saved;
`stages/*.npy`: guided-filter experiment outputs), device mattes (`device/`).

## Reproduction (scripts in `experiments/depth/portrait_edges/`)

Python: a venv with numpy, opencv-python, pillow, ai-edge-litert, pymatting. MODNet LiteRT file:
`experiments/android-vision/models/modnet_photographic_512_fp16.tflite` (sha256 4b57ff612f1a…, see
`experiments/android-vision/models/MODELS.csv`).

```
python experiments/depth/portrait_edges/stages.py          # Android stages, off/on, validation vs emulator saves
python experiments/depth/portrait_edges/diag.py            # teal/red counts and alpha/I/F at teal pixels
python experiments/depth/portrait_edges/diagB.py           # estimator background vs wall; inferred alpha (hypothesis)
python experiments/depth/portrait_edges/exp_guided.py      # the failed colour-guided-filter refinement
python experiments/depth/portrait_edges/save_intermediates.py
python experiments/depth/portrait_edges/sheet.py           # the comparison sheet
scripts/heavy ios-bg bash experiments/depth/portrait_edges/ios_sim_run.sh PHOTO MATTE bg-colour-dark OUTPREFIX
scripts/heavy android-bg bash experiments/depth/portrait_edges/bgrun2.sh bg-export-dark pd03_full.jpg OUTDIR
scripts/heavy ios-device bash experiments/depth/portrait_edges/ios_device_run.sh   # iPhone 11 Pro Max (dev device)
```

iOS device build: Xcode automatic signing, existing team, registered device:
`xcodebuild -scheme Lightly -configuration Debug -destination id=<device> -allowProvisioningUpdates
CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=<team> build`.
