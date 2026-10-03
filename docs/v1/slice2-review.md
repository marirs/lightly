# Slice 2 review package: editor session and Develop

- **Reference:** approved `docs/ui/app/` (ff5c5ae, canonical at 0352972), reviewed under `docs/ui/REVIEW-RULES.md`.
- **Status: handed over as progress, not accepted.**
  - The comparison matrix is incomplete on both platforms; the capture loop was stopped on 2026-10-03 for this handover.
  - No screen is exact-match verified.
  - Known deviations and UX conflicts below need correction or your decision.
- **Platform detail:** `docs/v1/slice2-ios.md` and `docs/v1/slice2-android.md`.

## Exact commits

| Platform | Commits |
|---|---|
| iOS | 0e37dd2 format-3 pack loader, `develop.global` port, bake/cache, spatial and finishing operators, parity tests, `scripts/bundle_look_pack.sh` · 521a71d EditState schema 3 · c4f4a75 editor session, editor shell, Develop panel (removes the M2 editor and the format-2 loader) · cdc01d5, 773adec, 1a4503c, 7278bfc comparison fixes · 9161aac notes |
| Android | 5b991d0 `:core-develop` (develop.global, 33³ bake, pack reader, lookVersion) · 47485ea spatial and finishing operators, tiled · 1f912a1 EditState schema 3 with migration · 80991d3 faster reader and bake, any-plan export · 490cbee editor and Develop panel, format 3 bundled and checked · f8a024c layout fixes · 7290012 Robolectric editor tests · 745d68f notes |
| Shared/tooling | b9b1f76 Auto kept as an unresolved release requirement · f7f20cf one-heavy-job lock and hook, `docs/v1/workflow.md` |

- **Build gap:** the Android app module doesn't compile at 80991d3 alone; it builds from 490cbee onward.
- **Attribution:** no commit carries co-author or AI attribution lines.

## Tests

| Run | Result |
|---|---|
| iOS (agent, at 7278bfc, under the lock) | Unit 241 pass, 0 fail, 3 skipped (timing assertions that run only in optimised builds; their optimised run passed). UI 28 pass, 0 fail, 6 skipped (capture tests) |
| Android (agent, under the lock) | 218 pass, 0 fail, 0 skipped. Debug and release APKs build; look-pack and launcher-icon checks pass in both. This run took 2 s, so Gradle probably served cached results |
| Coordinator, clean export of 9161aac (`git archive`; agents' uncommitted work excluded), one job at a time | **Android** `--rerun-tasks test assembleDebug assembleRelease` with the Android Studio JDK: 218 pass, 0 fail, 0 skipped, build successful in 2 min. **iOS unit:** 241 run, 3 skipped. 1 failure: `LUTGoldenTests` cannot find the git-ignored golden set in the export, and passes in the main checkout. Environment, not code. **iOS UI:** 28 run, 6 skipped, **1 failure**: `WelcomeAndMoreUITests.testFavouritesCanBeRemovedAndReordered` (dragging the handle doesn't reorder within the wait). It also failed in the main checkout, so it is reproducible, and is assigned to the iOS agent for a root-cause fix |
| Environment notes | Android unit tests need JDK ≤ 25 (Robolectric). The Mac's default JDK 26 fails before any test runs |

## Parity and performance

**Parity** on all 40 fixture presets, both platforms:

| Check | iOS worst | Android worst | Tolerance |
|---|---|---|---|
| 17³ LUT node | 2.4e-4 | 2.44e-4 | 1e-3 |
| Direct probe | 5e-8 | 5e-8 | 5e-4 |
| Via 33³ bake | 5e-8 | 1.6e-7 | 1e-3 |

- On both platforms, `lookVersion` is equal and the random vectors match exactly.
- On Android, the full pack (2,591 presets) parses and every recipe bakes. Tiled rendering is byte-identical to whole-frame rendering, and Save copy matches the committed preview.
- **What parity proves:** both apps match the shared reference model. It does not show the presets look like Lightroom. Every preset is still `approximate`, and validation has not been run (D8).

**Performance.** All figures come from a simulator or emulator. Device numbers are pending.

| Measure | Target | iOS (iPhone 17 simulator) | Android (Pixel 9 Pro emulator, host heavily loaded) |
|---|---|---|---|
| 33³ bake | median ≤ 16 ms, p95 ≤ 33 ms | 4.7 ms, p95 ≤ 6.4 ms ✓ | 28.6 ms, p95 71 ms ✗ (host JVM 10.6 ms) |
| Manifest parse | ≤ 300 ms | 261–288 ms ✓ (near the limit) | 71–111 ms ✓ |
| Stalest preview while scrubbing 20 stops | ≤ 100 ms | 42 ms ✓ | max 57 ms ✓ (drag uses a 17³ bake) |

## Working-flow evidence

- **Opening:** "Opening photo…" with the photo visible, then automatic Develop, then the editor.
- **Auto:** the approved "Automatic correction isn't available on this device. Presets still work." state. No unchanged photo is labelled Auto.
- **One session per photo:**
  - one EditState schema 3 recipe, with whole-recipe Undo/Redo;
  - switching photos closes the old session;
  - previews are latest-request-wins.
- **Develop:**
  - **Categories:** the approved 9, with exact counts, Favourites first, the applied-category dot, and tabs, wrapped tabs or a list depending on layout.
  - **Ruler:** one tick per preset stop, live preview while dragging, commit on release as one undo step, hold-still Fine mode, no arrows.
  - **Name line:** name, position and star; the "Applied: …" line.
  - **Amount:** slider with Done; the value is kept when the applied preset is re-selected.
  - **Favourites:** five maximum, with the full notice and the Replace sheet, shared with Preferences.
- **Compare:** hold to compare, with the "Original" badge; it is also an accessibility toggle.
- **Save copy:**
  - full-resolution tiled render of the committed recipe, with the slice-1 metadata switches;
  - Saving, Saved, Leave without saving, export-failed and storage-full states, with the approved copy;
  - on iOS, Saving can be cancelled without writing anything, and Saved has a Share button.
- **Evidence:** flow captures are in `~/.codex/artifacts/lightly/v1/slice2/{ios,android}/` (Android `flows/`).

## Update: iOS matrix complete (334aa33)

These are the iOS agent's results. The coordinator spot-checked one screen; nothing else has been independently verified.

- **Coverage:** all 24 cells × 21 screens (504) were captured with the validated runner, one cell per lock, from one recorded build at ea75592 with a clean tree.
  - The two grain screens were recaptured at ec1df87, after the rendering-v2 revision 1 port.
  - References come from `scripts/reference_cache.py`.
  - Each PNG has a JSON record of its revision, local-change fingerprint, cell and tool version, in `~/.codex/artifacts/lightly/v1/slice2/ios/runner/`.
- **Result:**
  - 72 screens match exactly, apart from the always-present D1, M1 and M7.
  - 432 carry only recorded deviations: M2 (iPad status bar), M3 (Large text metrics), M4 (default-size wrapping on dev-long-name and three iPad 11" landscape screens), M5 (Effects dot, slice 4) and M9 (grain strength, uncalibrated).
  - No screen is unverified and no defect is open: X1, X2 and M6 are fixed and verified in every cell.
- **Coordinator spot check:** `iphone17-portrait-dark-default/dev-amount` against the cached reference, PNG hash matching its record.
  - The layout, controls, copy, colours and state match.
  - Differences: the status bar (M1), the real versus simulated preset render (M7), and the home indicator, which the simulator screenshot doesn't draw. That is system chrome, now noted under M1.
- **Old evidence:** the earlier iOS evidence (1a4503c, 7356591) is superseded and marked STALE. The table further down is kept as history.
- **Android:** the matrix is being recaptured with its validated runner; still pending.
- **Status:** slice 2 is still not accepted. Owner review and decisions on M2, M3, M4, M8 and M9 (and Android's S1, S5, S7, S8) are outstanding.

## Comparison results

The evidence is in `~/.codex/artifacts/lightly/v1/slice2/ios/compare/<cell>/<screen>.png` and `…/android/side-by-side/`. There are 21–24 screens per cell.

**iOS** (24 cells: iPhone 17 and 17 Pro Max portrait; iPad Pro 11" and 13" in portrait and landscape; light and dark; default and large text):

| Cells | Captured on the final build | Reviewed |
|---|---|---|
| iPhone 17 (4 cells) | Yes | Light-default: all 21 screens. Light-large and dark-default: 4 screens each. Dark-large: none |
| iPhone 17 Pro Max (4 cells) | Yes | Light-default and light-large: 4 screens each. Others: none |
| iPad 11" portrait light-default, light-large, dark-default | Yes | Light-default: 4 screens |
| iPad 11" portrait dark-large, iPad 11" landscape (4), iPad 13" (8) | **No: unverified-pending** | Two landscape screens on an earlier build only, not counted |

**Android:**

| Cells | Status |
|---|---|
| Fold inner portrait (24 screens × 4 variants) | **STALE, not evidence.** Captured with fixed waits, before preset previews finished rendering (found at eb4aa8c, see below) |
| Fold outer light-default | Partly captured |
| Pixel 9 Pro, Pixel 10 Pro XL, Fold inner landscape, Pixel Tablet in portrait and landscape, rest of Fold outer | **Unverified-pending.** The Pixel 9 Pro pairs from 490cbee are older than f8a024c, so they are superseded and not counted |
| Slice-1 recapture | Fold inner portrait and landscape recaptured (112 files), **not yet compared**. Pixel 10 Pro XL, Fold outer and Pixel Tablet slice-1 cells are still pending |

**Android capture validity (eb4aa8c).** Android's old capture path waited fixed times (25 s and 10 s) and took screenshots before the preset preview finished rendering in the debug build. Measured on Pixel 9 Pro light-default with one APK:
- dev-preset, dev-starred and dev-browse show the undeveloped photo;
- dev-bw is still in colour;
- nine more screens show an earlier preview.

All Android slice-2 photo evidence from that path (f8a024c and earlier) is therefore invalid and marked STALE. The new persistent-session runner (one launch per batch, waiting for the app's ready signal) matches launch-with-ready-signal captures pixel for pixel in the app area on 23 of 23 screens. It is adopted for Android: 422 s per batch, against 679 s for launching per screen with the signal. Two runner timeouts are being fixed. The iOS capture path is being checked for the same problem.

**Coordinator spot checks** (two images; not a review of the matrix):
- iOS `iphone17-portrait-light-default/dev-preset`: the controls, text and spacing line up with the reference. The differences are the status bar and the photo, which shows the real preset render rather than the prototype's simulated colours.
- Android `dev-browse` on Fold inner portrait light-default: the structure, list, rail and ruler match, and the whole screen sits about 10 dp lower (S1). **Withdrawn:** that capture used the fixed-wait path, so its photo area is not valid evidence. The layout observation still needs confirming on a valid capture.

## Known deviations

| # | Platform | Approved | Implemented | Needs |
|---|---|---|---|---|
| 1 | iOS | iPad status bar 24 pt | iPadOS 26 draws 32 pt, so every iPad screen sits 8 pt lower | Your decision (the system draws the bar) |
| 2 | iOS | Line breaks as in the reference | iOS text is about 4% narrower: different wrapping at large text, and for "Landscape 15 - Winter Wonderland" even at default size | Your decision: match the reference's font metrics, or accept platform text metrics |
| 3 | Android | Editor position on the Fold | About 10 dp lower because of the real system bars (S1) | Your decision |
| 4 | Android | Large-text scaling | Android's non-linear font scaling (S5, as in slice 1 M7) | Your decision |
| 5 | both | Effects "used" dot in compare, saving, saved, leave, more | Missing: needs Effects (slice 4) | Fix in slice 4 |
| 6 | iOS | Replace sheet Cancel at 17 pt | Was 15 pt; fixed in 7278bfc | Recapture pending |
| 7 | iOS | Spinner drawn still | Rotates | Your decision |
| 8 | both | Auto-applied, Developing and Developed screens | Cannot occur without a model (D1). They appear in captures only as injected states; the photo is never corrected | Blocked on D1 |

Expected differences that are not layout: the status and navigation bars, and the real preset render versus the prototype's simulated colours.

## UX conflicts (reported, not changed)

1. **Strength and Reset vs Amount:**
   - The slice-2 instruction says "Strength" and "Reset".
   - The approved design has **Amount** and **no Reset control**. Both apps implement Amount, and ruler stop 0 removes the Look as one undo step.
   - Confirm that the approved design stands.
2. **Fine mode:** the design shows the Fine state but not when it starts or how much it slows the ruler. Both apps start it after 0.5 s of holding still, at quarter speed. Confirm.
3. **Unbuilt tools in release builds:**
   - Background, Edit, Effects, Watermark and Border are listed but do nothing.
   - In debug builds they open a panel marked "Development stub".
   - They are built in slices 3–5. This is interim only; no release ships with inert tools.
4. **Restored edits whose Look has changed or disappeared:** there's no approved notice for this. The apps render the photo without that Look and never substitute another. A notice is needed: design input from you.
5. **Portrait on Android:** the person detector is pending (D3). Debug builds show Portrait on every photo, marked as a stub; release builds hide it.
6. **Auto marker strings:** the Android-only recipe values `develop-failed` and `use-original` must be agreed across platforms in `shared/contracts/` before slice 6. This is an engineering item; it doesn't affect the UX.

## Rendering issues found

- **Grain is far too strong at real preset amounts.** Found on iOS; it reproduces with the shared `reference_model.apply_grain`, so the cause is the uncalibrated grain constant in the shared contract, not a port.
  - Example: "5 - (Portrait) - Glow" (grain 55) covers the photo in coarse, coloured grain.
  - 618 presets carry grain.
  - Fix: calibrate the grain constant in the reference model against measured Lightroom grain (D8 reference exports would settle it), then re-run parity. Until then, grain counts as a visual-fidelity defect.
- **Experimental, no golden values yet:** the spatial operators (noise reduction, clarity, texture, sharpening) and vignette.
  - Clarity's large blur works on a fixed 256 px copy of the photo.
  - The spatial stage uses a single colour-space conversion.
- **Android:** the GPU path handles colour tables only and is not validated, so rendering runs on the CPU. The committed preview takes about 463 ms on the loaded emulator.

## Missing coverage, before slice 2 can be accepted

0. The iOS Favourites reorder UI test is failing (above). It must be fixed at its root cause.

1. The full matrix on both platforms: the iOS cells and screens listed above; on Android everything except Fold inner portrait. Recapture only the cases changed since the last capture (`docs/v1/workflow.md`).
2. Review of every captured screen, not only the four-screen spot checks.
3. Comparison of the Android slice-1 recaptures, and the remaining slice-1 cells.
4. Device performance numbers on the oldest supported devices: iPhone SE 3 or 11 Pro Max, and the dev Android phones (benchmark apps only).
5. Grain calibration, then re-review of grain presets.
6. Your decisions on deviations 1–4 and 7 and conflicts 1–4.
