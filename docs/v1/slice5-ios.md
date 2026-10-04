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
| Docs | this file | Slice-5 iOS report |

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

## Tests

- Unit (targeted runs, Simulator iPhone 17): `WatermarkStageTests` 16, `SignatureStoreTests` 7, `WatermarkSessionTests` 5, `BorderStageTests` 4, `EditorSessionTests` + `EditEffectsSessionTests` 25, `EditEffectsStageTests` 13, `RenderingGoldenTests` 9, `RemovePatchPersistenceTests` 3, `AppStateTests` 5, `SliceOneSnapshotTests` 16 — 0 failures. The full unit suite was not run in this slice (pending).
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
| R1 | — | Android restores an edit after process death | iOS stores Remove patches but has no recipe restore after a kill yet | gap reported |

## Pending

- Full-device matrix for the nine screens (23 cells), dark and large text: needs the owner's scheduling approval. `pref-border` (unchanged since slice 1) was not recaptured.
- Full unit and UI suites at the final revision.
- Device checks (dev devices only): export memory at 48 MP with a watermark.
- Owner decisions W1–W8; iOS process-death restore (R1).
