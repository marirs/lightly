# Slice 5 on iOS: Watermark, saved signatures, Border follow-ups

Reference: the approved prototype `docs/ui/app/` (`watermarkPanel`, `watermarkHTML`, `sigSvg`, `LOGO`, the `sigDraw` and `sigImport` sheets, the `signature` and `prefborder` pages, the `polaroidSig` action), the screens `wm-none`, `wm-signature`, `wm-sig-draw`, `wm-sig-import`, `wm-text`, `wm-logo`, `wm-on-border`, `bd-polaroid`, `pref-signature`, `pref-border`; edit recipe v1 (`watermark`, `signatureRef`, `border`, `derivedRef`); rendering-v2 **revision 2** (§1, §7, `stages[watermark]` constants; `docs/v1/contract-fixes-2.md`).

Status: **progress, not accepted.** Built and tested; one phone cell (iPhone 17 portrait light default) captured and reviewed for the nine in-scope screens, plus one iPad 11 landscape check. Full-device coverage is pending (bulk capture paused by the owner).

## Commits

| Kind | Commit | What |
|---|---|---|
| Code | d69e9ad | Light leak per revision 2 (farthest-corner ray, uncovered corners), `requiredContractRevision` 2, the four `lightLeak` goldens |
| Docs | 2cff5a9 | CONTRACT GAP markers C1–C3 cite revision 2 |
| Code | 1e2d1d5 | Watermark tool, saved signatures, stage 12, Border follow-ups, Preferences › Saved signature, unit tests |
| Tooling | b98aba7 | Capture screens `wm-*`, `pref-signature` (driver opens More at a page); Watermark UI flow test replaces the stub test |
| Test | db68ef1 | `more-signature` snapshot re-recorded: the old baseline was the slice-1 empty stub (slice-1 mismatch #5) |
| Code | f520543 | "Signature on the margin" row 52 pt (was 44; found in this review); `wm-sig-draw` capture sample position |
| Code | 7bcef45 | Remove patches stored beside the edit by digest (`derivedRef`), kill-and-recover and corrupt-patch tests |
| Docs | 6512140 | Slice-5 iOS report (first version) |
| Code | 88973a6 | Session restore after the system ends the app (R1) |
| Code | daee977 | Draw / Import from Preferences replace the More page (were a nested sheet) |
| Test | 2e770cd | Share: the shared file is the saved copy's bytes; metadata policy in all four combinations on it |
| Tooling | fbffd33 | Restore and Draw-replaces-More UI tests; `share` capture screen |
| Docs | this file | Report update |

## What is built

**Watermark** (`Features/Watermark`, `ImageEngine/Watermark`), the approved `watermarkPanel`:
- Tabs None, Signature, Text, Logo. None: the approved note.
- Signature: a chip per saved signature (drawn: in the chip's ink; imported: its own ink, min-width 120), `+ Draw`, `Import`; the note ("…You can change the ink colour of a drawn signature." / "…An imported signature keeps its own ink."); the colour row only for a drawn signature.
- Text: the "Text" row with the value editable in place (1–80 characters), the four `.fontopt` chips in Allura, Cormorant Garamond 500, Inter 400, Caveat 500 (bundled from `shared/fonts`, read by URL, checked by family and `wght` in tests).
- Logo: the current logo (`span.opt.on`, the sample "AR" ring) and `Replace logo` (picks a photo; stored by SHA-256 as `assetRef` kind `file`).
- On photo / On border (segmented) when a border is set, else "Add a border to place the watermark on it."; the **Position · Bottom right ›** row cycles the nine anchors (the approved row, not a grid) and "Or drag the watermark on the photo." (the drag moves the anchor; the box keeps the prototype's 30 %/70 % alignment rule); Size 10–80, Opacity, Colour (#FFFFFF, #111111, #C9A27E, #8A8A8F).
- Every change is one undo step; sliders and drags preview. The tool's used dot follows `toolUsed`.

**Saved signatures** (`Domain/Signatures`): one drawn (vector strokes, canonical JSON) and one imported (PNG, paper removed: paper level = 90th luma percentile, ink un-mixed from the paper so it keeps its colour and texture) at a time. `signatureId` is stable per kind; `signatureVersion` = first 12 hex digits of SHA-256 of the stored bytes. Drawing or importing again keeps the id and changes the version; a recipe that used the earlier one, or a deleted one, renders **without** it (never substituted). Stored in Application Support/Signatures.
- Draw signature sheet (Cancel · Draw signature · Save, dashed pad with its baseline, Clear, note), Save → "Signature saved for reuse" toast, used at once.
- Import signature sheet (Cancel · Import signature · Use, `#F7F4EE` paper box, dashed selection, note), after the system photo picker.
- Preferences › Saved signature: the signature (54 pt), Draw a new signature, Import from a photo, Delete saved signature, the note. Changes re-render open editors.

**Stage 12 `watermark`** (`WatermarkStage.swift`), after Border, in preview and Save copy alike: heights from the bundled contract (text font 0.06225, signature 0.08995, logo 0.09415 of the photo's short edge at size 34, linear in size); anchors 6/50/94 % of the photo inside the border; on a border centred, box bottom 1 % (6 % polaroid) of the canvas above its bottom; #222222 ink on a polaroid margin; opacity as a group. The `.wm` box model was measured from the prototype (Playwright, fonts loaded): the 15 px SF strut keeps ≥ 13 CSS px above and 2 CSS px below the baseline (an inline SVG sits 2 px above the box bottom); text uses `line-height: 1` half-leading; `text-shadow 0 1px 2px rgba(0,0,0,.35)` on the photo for text and the logo's initials (not the signature path, not on a border).

**Border follow-ups**:
- "Signature on the margin" works as `polaroidSig`: with no watermark it chooses the saved signature and flips the placement; the DEFERRED marker is gone. Row height 52 pt (`.listrow`), fixed in f520543.
- Stage marks (crop frame, focus target, face rings, leak drag, Remove strokes) sit on the photo inside the border (`.imgbox`), clipped to it; the box is recovered exactly from the displayed canvas.
- Preferences › Preferred border as approved (None ✓ by default). Border opens on the preferred type's tab when the photo has no border; nothing is applied until a control on that tab changes. The None note names the preference (the prototype's `${'None'}` placeholder).

**Rendering-v2 revision 2 port**: light leak ray = farthest corner, no leak outside the rotated overlay, revision 2 required.

**Remove patches** (7bcef45): written atomically to Application Support/RemovePatches/`<sha256>.patch`, digest-checked on load; missing/corrupt → skipped, never recomputed; a new photo deletes them.

**Session restore (R1, 88973a6)**: there is no approved "resume" screen, so the session comes back the platform way, as on Android: while it has unsaved edits it is kept in Application Support/EditSession (a copy of the original's bytes; every undo entry as canonical edit-recipe-v1 JSON and the position; the Auto state; the model results: people and faces, subject matte, depth map, person matte). A SwiftUI scene-storage flag marks an editing scene; iOS drops it on a force-quit. After the system ends the app, the next launch reopens the editor exactly as it was, with no prompt; after a force-quit the stored session and its Remove patches are discarded. No model runs on restore (Auto, Vision, depth, Remove). The folder is excluded from backup; files are protected until first unlock. Save copy, Discard, close and a new photo clear it. Owner question **W9**: an explicit "Resume editing?" prompt would need a design.

**Share**: unchanged code. Saved › Share hands the system share sheet a file holding the saved copy's own bytes, so it is the same full-resolution committed render as Save copy with the same metadata policy; the original is never modified.

**Preferences › Saved signature › Draw / Import** (daee977): as the prototype's `overlay:sigDraw` / `overlay:sigImport`, they replace the More page; More closes and the approved sheet opens over the screen beneath (Import picks the photo first). Saving there only stores the signature.

## Tests

- Unit (targeted runs, Simulator iPhone 17): `WatermarkStageTests` 16, `SignatureStoreTests` 7, `WatermarkSessionTests` 5, `BorderStageTests` 4, `EditorSessionTests` + `EditEffectsSessionTests` 25, `EditEffectsStageTests` 13, `RenderingGoldenTests` 9, `RemovePatchPersistenceTests` 3, `AppStateTests` 5, `SliceOneSnapshotTests` 16 — 0 failures. The full unit suite was not run in this slice (pending).
- Restore and Share (test-ios-restore-share): `SessionRestoreTests` 4 — kill and recover from storage only with counting Auto, person and Remove models (none called), same history and position, identical preview bytes and export; Save clears; backup exclusion; force-quit discards, relaunch restores, leaving clears. `EditorSessionTests` metadata test now also checks the shared file's bytes in all four Keep photo metadata / Include location combinations.
- UI (verify-ios-restore-share-iphone17, build 2e770cd): `testTheSessionComesBackAfterTheSystemEndsTheApp` (background, kill, plain relaunch: editor with the edit and its history) and `testDrawFromPreferencesReplacesTheMorePage` pass; screenshots in `~/.codex/artifacts/lightly/v1/slice5/ios/verify-restore-share/iphone17__portrait__light__default/`.
- UI: `EditorFlowUITests` `testWatermarkTextPositionAndUndo` and `testEditAndEffectsShareTheSessionAndUndoStepByStep` pass (build f520543).
- Save copy: `WatermarkSessionTests.testSaveCopyCarriesTheBorderAndTheWatermarkAndTheSessionKeepsTheOriginal` renders the export path at full resolution: polaroid canvas = photo + insets, only the bottom margin changes, original bytes untouched. Inspected visually on `portrait_deep_03` (1067 × 1600 → 1185 × 1915, Caveat "A. Rivera" in #222222 centred in the margin): `~/.codex/artifacts/lightly/v1/slice5/ios/verify-watermark-f520543/export-polaroid-caveat-portrait_deep_03.jpg`.

## Visual check (focused; bulk capture paused)

`verify-ios-watermark-iphone17-f520543` (build f520543 clean, one launch, 9 screens) and `verify-ios-watermark-ipad11-landscape` (wm-signature, wm-sig-draw). Native PNG + JSON and reference|native pairs in `~/.codex/artifacts/lightly/v1/slice5/ios/verify-watermark-f520543/<cell>/`. References from `scripts/reference_cache.py` (variant `auto-unavailable` for editor screens).

| Screen | iPhone 17 portrait light default |
|---|---|
| wm-none, wm-sig-import, wm-on-border | V (plus D1/M3 as earlier slices: status bar, SF vs Inter metrics) |
| wm-signature, wm-sig-draw, wm-logo | W1 (watermark size) |
| wm-text | W1, W4 |
| bd-polaroid | W1 (after f520543; before it the panel was 8 pt short) |
| pref-signature | page content V; recorded slice-1 deviation 1 (phone More pages in the sheet) |

`saved` V (as slice 2). `share` (captures2, build fbffd33's DEBUG wait): the system share sheet with "Lightly copy · JPEG Image" and the saved copy's thumbnail. **S1**: the prototype draws its own mock of the system sheet (`data-system`); iOS shows the real iOS 26 share sheet (layout and actions are the system's).

iPad 11 landscape (side panel with title): layout matches; the watermark is about twice the prototype's size (W1, tablets).

## Deviations and owner questions

| Id | Screens | Expected (approved) | Observed (native) | Status |
|---|---|---|---|---|
| W1 | all wm-*, bd-polaroid; tablets most | fixed CSS px (18/26/30 × size/34) over the displayed photo | resolution-independent revision-2 medians; iPhone 17 ≈ 7 % smaller, iPads ≈ 2× | coordinator decision (contract-fixes-2 §5) |
| W2 | — | no approved notice for a missing or changed saved signature | rendered without it, nothing shown | owner question (proposal: the Develop "Look unavailable" notice pattern; not built) |
| W3 | pref-signature, wm-signature | Preferences shows one signature; the panel shows a drawn and an imported one | Preferences shows the one saved last; Delete removes it (the other is then shown); with none saved: "No saved signature", no Delete row | owner question |
| W4 | wm-text | the prototype's quoting defect (`style="font-family:"Cormorant Garamond"…"`) falls back to 15 px system font on the photo and in the chip | real Cormorant Garamond 500 at the calibrated size | owner decision |
| W5 | wm-text | default text "A. Rivera" (prototype sample) | same; it is a placeholder person's name | owner question |
| W6 | wm-sig-import | no design for a photo with no ink found | the sheet shows the empty paper box; Use does nothing | owner question |
| W7 | bd-polaroid | `polaroidSig` sets type signature even with nothing saved | no saved signature: Draw signature opens; the saved drawing goes on the margin | owner question (v3 differs, in code) |
| W8 | Border (preferred) | prototype never shows a non-None preferred tab | Border opens on the preferred tab; the first change there applies that type in the same step | owner question |
| R1 | — | Android restores an edit after process death | done in 88973a6 (silent restore, no new screen) | closed |
| W9 | — | no approved screen for resuming an interrupted edit | silent restore after a system kill; discarded after a force-quit | owner question |
| S1 | share | prototype's mock of the system share sheet | the real system share sheet | platform (system UI) |

## Pending

- Full-device matrix for the nine screens (23 cells), dark and large text: needs the owner's scheduling approval. `pref-border` (unchanged since slice 1) was not recaptured.
- Full unit and UI suites at the final revision.
- Device checks (dev devices only): export memory at 48 MP with a watermark.
- Owner decisions W1–W9.
- Restore on a device (dev devices only): memory and time to restore a 48 MP original.

## Update 2 (after 61605e8)

Correction: commits 003ac1a and f60c49b call the display-relative sizing and the as-is import an "owner ruling". They are a PROVISIONAL coordinator approach, pending the owner; only "wrong watermark size" (W1) and "dead Use" (W6) are owner-declared defects. Code comments say so (c892545).

| Kind | Commit | What |
|---|---|---|
| Code | 003ac1a | W1 (provisional): watermark 18/26/30 pt × size/34 and Focus & Blur R_max 27.57 pt × blur/100 on the displayed photo; Save/Share use the layout at save time |
| Code | f60c49b, a993c4d | W6: Use always works (as-is when no ink); paper ends at alpha 0 (local paper level, hard floor, 4 px ink proximity); blank and unreadable imports show the approved toast (W10 copy) |
| Code | 1e9a526, 2c955e8 | PrivacyInfo.xcprivacy (no tracking, no data; UserDefaults CA92.1, system boot time 35F9.1); legacy presets_photo.json / luts_video.json out of the app; Remove patches excluded from backup |
| Code | 980cac3, 46c8ce3 | Accessibility: Reduce Motion, VoiceOver names/values (effect switches, swatch colour names as Android, signature chips), contrast tests |
| Test | 76be0db | Release gates closed: Focus & Blur without depth shows "Couldn't separate the subject.", Remove fails, nothing changes |
| Test | 41b2340, 246e7b2 | Restore UI test waits; restore decision logged |

**Suites at 61605e8** (snapshot, verify_preflight): unit 330 tests, 0 failures, 4 skipped; UI 31 tests, 6 skipped, 1 failure (restore, below).

**Release configuration** (a993c4d, default gates): builds; 24 MB; no depth model and no LaMa in the bundle; Look pack (6.2 MB manifest) and privacy manifest bundled; app-icon check passes; no DEBUG launch arguments or stubs in the binary. Gate behaviour covered by `ReleaseGateTests`; a hands-on Release run in the Simulator is pending.

**Review build**: `~/.codex/artifacts/lightly/v1/review-builds/ios/lightly-ios-review-61605e8-sim.zip` (SHA-256 5ef977eef5c223cb100ccaab6364502ece44b3442ff2f1fa904ed3f682116e8c), README beside it. Not UX acceptance, not release.

**Sizing evidence** (`~/.codex/artifacts/lightly/v1/slice5/ios/sizing-evidence/`, `SizingEvidenceTests`, rendered images): the same edit saved from the iPhone 17 layout vs the iPad 13 landscape layout gives a watermark of 162 vs 73 px and a background σ of 23.5 vs 10.6 px on the same export (ratio 2.2 = the display ratio): **the saved file depends on the editing device** with the provisional approach. Preview vs export agree (54 vs 54 px; σ 11.77 vs 11.76 at half scale). On screen the watermark is 13.4–13.6 pt for an 18 pt Inter cap height (13.1 pt). Proposal for the owner (not built): store the resolved fraction in the recipe when the watermark or blur is set, so later saves reproduce it on any device. Focused UI check (`verify-sizing-a993c4d`): wm-text and bg-focus on iPhone 17 and iPad 13 landscape; the iPad watermark now matches the prototype's size.

**Restore UI test (open defect R2)**: passes alone; fails after `testSaveCopyShowsSavingThenSavedAndKeepEditing` (reproduced with that pair). The launch log shows the stored session present but "scene was editing false": the SwiftUI scene-storage flag did not survive the background-and-kill, so the restore was (correctly, by its rule) declined. The unit kill-and-recover tests pass. Next: replace the flag with UIKit scene state restoration (`stateRestorationActivity`) or the app's own lifecycle record; needs the coordinator's agreement because it decides force-quit vs system kill.

New owner question **W10**: copy for an import with nothing to use ("No signature found in that photo", "That photo can’t be opened").
