# iOS hair spill: where it enters, and the refinement (2026-10-06)

**Where the red enters (live iPhone Vision matte, `../portrait-edges-2026-10-05/live-pm02-matte.png`, the app's own
pipeline on the spare Simulator with that matte as fixture, dark #1F2328 replacement):** of 7,373 red pixels near the
hair outline, 5,548 (75 %) have matte ≥ 0.98 and the saved copy equals the original there (mean |Δ| 0.7). The
original colour (97, 29, 28) fits a ~50/50 mix of dark hair and the red wall (α ≈ 0.49 from red, 0.47 from green).
The instance mask is a smooth blob at the curls, so wall pockets between them are "subject". The other 25 % are soft
edge pixels the foreground estimate only partly corrects. `classify.py`.

**Tried and not adopted:** re-estimating α from local hair/wall colours (two-colour projection): red −55 % but red
patches remain and white/green blotches appear.

**Adopted:** Vision person segmentation `.accurate` (already an Apple system model; the app used `.balanced` for
Portrait) combined as min(instance, person) in a hair zone around each detected face (`SubjectMatte.refinedAtHair`).
App saved copies (Simulator, live instance matte + macOS person matte as fixtures, `person_mattes.swift`), red pixels
(excess > 25) / teal pixels (cyan > 8) in the head outline zone:

| Case | Before | After |
|---|---|---|
| pm02 dark (failing case) | 6,120 / 302 | 48 / 1,841 |
| pm02 light | 5,080 / 10 | 26 / 3 |
| pd03 light (regression: dark studio portrait) | 8,354 / 20 | 8,332 / 6 (no hair lost; outline sharper) |

(pd03's "red" pixels are skin tones inside the zone, unchanged.) Sheet: `hair-fix-sheet.png` (original | before |
after; dark then light for pm02; light for pd03).

**Still open:** a faint dark-teal tint on a few wisps on the dark background (foreground estimate over-subtracting the
wall red, the Android mechanism). Not verified on the iPhone: `.accurate` person segmentation's result and time on the
device.

## 2026-10-06: Android teal cast and grey haze (completion plan A4): closed-form matting of MODNet's matte
Diagnostic (`portrait_edges/exp_alpha_opacity.py`, recorded stages): the step that differs is the matte. MODNet's alpha
is too low in dense curls (median 0.62), so the foreground estimate over-subtracts the wall (teal); its soft tail is
the haze. Variants fixed in advance, head soft band, teal px / red excess / haze ring (pm02 dark | pm02 light):

| Alpha | pm02 dark | pm02 light |
|---|---|---|
| shipped (MODNet) | 56,379 / 1.3 / 5.5 | 2,966 / 4.0 / 26.2 |
| levels 0.1→0, 0.7→1 | 12,442 / 11.8 / 9.9 (red blobs) | 22 / 8.4 / 25.5 |
| gamma 0.6 | 80,223 / 4.2 / 17.1 | 1,846 / 4.8 / 46.1 |
| min(MODNet, selfie) in the head (iOS-style) | 27,690 / 2.9 / 2.3 (curls cut, blocky) | 484 / 3.9 / 7.2 |
| **closed-form matting, MODNet trimap** | **31,998 / 0.4 / 2.4** | **53 / 3.9 / 13.1** |

Adopted: closed-form matting (Levin et al.; pymatting's constants) in MODNet's uncertain band at 768 px, matrix-free
conjugate gradients with a half-size start (`ClosedFormMatting.kt`; parity with pymatting < 1e-3, test fixture from
`make_cf_golden.py`). Emulator Save copies (`closed-form-*.jpg`: shipped | refined):

| Case | Shipped | Refined |
|---|---|---|
| pm02 dark | 55,547 / 1.3 / 5.1 | 41,921 / 0.3 / 1.8 |
| pm02 light | 2,355 / 4.1 / 19.1 | 322 / 4.1 / 7.9 |
| pd03 light | 43 / 6.3 / 10.5 | 45 / 6.5 / 5.1 |

Hair crisp, haze roughly halved, red gone. **Residual:** a dark-teal cast stays on the left curls of pm02 over the dark
replacement (reduced, visible). Cost: 2.4–7.5 s on the CPU emulator for 28–31 k uncertain pixels (emulator timings vary
under host load); device time pending (no Android phone connected).
