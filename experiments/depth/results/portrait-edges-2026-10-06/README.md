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
