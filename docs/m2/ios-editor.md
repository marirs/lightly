# M2 — iOS editor

Project: `ios/` (XcodeGen `ios/project.yml`). Shared inputs read from the repository root: `shared/fixtures/edit-state/` (saved-edit contract), `experiments/presets/look_pack/out/` (Look pack, git-ignored).

This note records the audit of the agreed editor UX against the iOS app, the gaps closed in this milestone, how it was verified, and what is still open.

## 1. Audit (before this milestone's UX work)

Audited at `07d3a57` (saved-edit schema 2 and pack format 2 already landed). Status: **implemented**, **partial** or **missing**.

| # | Agreed behaviour | Status | Where / why |
|---|---|---|---|
| 1 | Photo-first: controls below the photo on narrow screens | implemented | `Features/Editor/EditorView.swift` (`VStack`: top bar, notices, photo, bottom panel capped at 35%) |
| 2 | Controls beside the photo (side panel 320–380 pt) when space permits: iPhone landscape, iPad, split view | missing | `EditorView` has a single vertical layout |
| 3 | Landscape on iPhone (not upside down), all orientations on iPad | missing | `ios/project.yml` `INFOPLIST_KEY_UISupportedInterfaceOrientations: UIInterfaceOrientationPortrait` (portrait only, all devices). `TARGETED_DEVICE_FAMILY` is already `1,2` (XcodeGen default) |
| 4 | Categories come from the catalogue (pack) | implemented | `ImageEngine/LUT/LookPackLoader.swift`, `LookControls.categoryChips` in `EditorPanelControls.swift`; no names in code |
| 5 | Discrete slider stops select named presets within the category | implemented | `SteppedLookSlider` (`Slider` with `step: 1`), `LUTEditorViewModel.previewStop/settleStop` |
| 6 | Stop 0 reads "Original" unless Auto was actually applied | implemented | `LUTEditorViewModel.noLookStopLabel` |
| 7 | Visible stop markers (a tick per stop) | missing | system `Slider` draws no detents |
| 8 | Selected preset's name **and position** ("Nordic Tone (10) · 3 of 5") | partial | name shown (`editor.lookStopName`); position only in the VoiceOver value |
| 9 | Optional Strength, secondary, only while a Look is applied; drag previews, release is one undo step | partial | model and view model added in `42580bb` (`setLookStrength`, `previewLookStrength`); no control on screen |
| 10 | Undo | implemented | `EditActions.undoAction` |
| 11 | Redo | partial | view model added in `42580bb`; no control on screen |
| 12 | Compare: press-and-hold and an accessible toggle | implemented | `EditorView.photograph` gesture, `EditActions.compareAction` |
| 13 | Compare: clear "Original" indicator on the photo | missing | only the VoiceOver label changes |
| 14 | Reset is undoable | implemented | `LUTEditSession.resetToAuto()` commits a step (Codex M2 finding 3) |
| 15 | Prominent Save copy | partial | one of four equal-weight buttons |
| 16 | Compact status notices that never push the photo off screen | partial | three full-sentence notices above the photo, capped at 14% and scrolled; wording of the "Look unavailable" notice ("Showing Auto instead") was wrong without an Auto model |
| 17 | Look unavailable / changed notices; "Use current version" as an undoable step | partial | resolution and the undoable step are in the view model (`42580bb`); no "changed" notice or button on screen |
| 18 | Retry / Continue for genuine Auto failures; no futile Retry when no model exists | partial | view model added in `42580bb` (`.autoFailed`, `retryAuto`, `continueWithoutAuto`); before that every failure was shown as "this build has no Auto model". The no-model path already went straight to editing |
| 19 | Large text: panel scrolls, names wrap | implemented | `cappedScrollable`, `SteppedLookSlider` name `fixedSize(vertical)` |
| 20 | Large text: photo keeps ≥ 40% of the height on phone portrait | missing | panel may take 50% at AX sizes; `EditorLayoutTests` only required 20% |
| 21 | The real 18-preset pack, names verbatim, both Mono presets | partial | names verbatim and order kept; but the real pack is format 2, which the app could not read until `07d3a57`, so the installed app showed "No Looks" |
| 22 | Saved edits: EditState schema 2, v1 migration, resolution rules | implemented | `Domain/Session/SavedEdit.swift` (`ba077da`), `LUTLookBook.resolve` and session restore (`42580bb`) |
| 23 | Relaunch restore of a saved session | missing (deferred) | no restore entry point; see §5 |

## 2. Gaps closed in this milestone

| # | Behaviour | Now | Where |
|---|---|---|---|
| 2, 3 | Side panel when there is room; landscape and iPad | implemented | `EditorLayoutPolicy` in `EditorView.swift`, chosen by **displayed photo area** (review fix, below): side panel 36% of the width clamped to 320–380 pt, only when the photo column keeps ≥ 320 pt. `ios/project.yml`: iPhone portrait + both landscapes, iPad all four, `TARGETED_DEVICE_FAMILY 1,2` |
| 7 | A visible marker per stop | implemented | `SteppedTrack` (custom; detent per stop, thumb on the selected one). Drags move relative to the stop where they began and clamp at the ends; a tap selects the stop under the finger; a vertical drag scrolls the panel and changes nothing |
| 8 | Name and position | implemented | `SteppedLookSlider.nameAndPosition`: "Nordic Tone (10) · 3 of 5", wraps at large text |
| 9 | Strength | implemented | `StrengthControl`: caption-sized, secondary colour, small control, only while a Look renders; disabled (not removed) while another preset is being dragged in, so the panel does not jump under the finger. Drag previews, release is one step; VoiceOver adjusts in 10% steps |
| 11 | Redo | implemented | `EditActions.redoAction` |
| 13 | "Original" state on the photo | implemented | badge in the photo's corner while Compare (hold or toggle) shows the original |
| 15 | Prominent Save copy | implemented | `SaveCopyButton`: filled capsule in the top bar, always visible; the outcome line sits with the notices |
| 16 | Compact notices | implemented | one short line each; capped (18% of the height) and scrolled beyond that; `cappedScrollable` now measures its content (`CappedHeightLayout`) instead of `ViewThatFits`, which filled the whole cap |
| 17 | Look unavailable / changed | implemented | `EditorNotices`: unavailable notice; changed notice with **Use current version** (an undoable step). The saved `LookRef` is kept in the edit and in history and written back unchanged |
| 18 | Retry / Continue | implemented | `AutoFailureRow` for genuine failures only (`AutoUnavailableReason.isRetryableFailure`); "no model in this build" goes straight to editing with the notice |
| 20 | Photo ≥ 40% at AX sizes on a phone in portrait | implemented | panel share 45% at AX sizes plus a photo minimum height of 40%; category chips wrap (`EqualWidthRowLayout`) instead of truncating |
| 21 | The real pack loads | implemented | `07d3a57` (format 2). Verified in the installed app: 5 categories, 18 Looks, names verbatim, both Mono presets ("03 Black and White 03", "11 Black and White 11") |

Saved edits (`ba077da`, `42580bb`): `Domain/Session/SavedEdit.swift` reads and writes EditState schema 2 byte-for-byte like the shared fixtures, migrates schema 1 to `legacy-v1-<n>`, rejects unknown keys, unknown schemas and out-of-range values; `LUTLookBook.resolve` gives available / unavailable / changed; only "available" renders, and preview and Save copy use the same passes, so what is shown is what is written.

## 2a. Codex review d5690dd fixes

| Finding | Before | Now | Where |
|---|---|---|---|
| 2. Successful Auto never applied | With a non-identity enhancer Auto succeeded but only stored its LUT: Auto strength 0, no Auto pass, stop 0 read "Original" | A successful develop starts the session at the **Auto baseline** (Auto strength 1, one entry, revision 0), rendered; stop 0 reads "Auto". It is the initial committed state, not an undo step (Android `EditSession.start`) | `LUTEditSession.startAtAutoBaseline()`, `LUTEditorViewModel.finishDeveloping()` |
| 2. Retry | — | **Decision:** a successful Retry also *starts* at the Auto baseline instead of adding an undoable "apply Auto" step. Android's Retry re-runs `develop`, which calls `EditSession.start`; and nothing can be edited behind the failure row, so there is no earlier edit to undo to | same |
| 2. Restore | A restored session re-ran the model | Never re-developed: no model run, Ready at once, each entry's Auto strength kept, and the saved Auto block kept (`LUTEditSession.restoredAuto`) so a re-save writes it back byte for byte. With no basis on iOS a restored Auto is reported unavailable, never claimed as applied (`// DEFERRED:`) | `LUTEditSession.restore`, `LUTEditorViewModel.init` |
| 3. Returning to the same preset | Look A at 40% → preview B → settle on A: Strength 100%, history 3 → 4 | **Agreed Strength rule** (both platforms): settling on the committed stop is a no-op (Strength, history, revision unchanged; the preview ends and the committed state re-renders), and dragging back over it previews the committed Strength. A different preset is previewed and committed at 100% as one step. Undo/Redo restore Strength exactly; Reset is one undoable step; Strength commits on release only. A changed/unavailable Look's stop is not "committed" (the slider shows stop 0), so settling there applies the pack's version | `LUTEditorViewModel.settleStop/previewStop/isCommittedStop` |
| Design pass: iPad portrait wasted photo space | Side panel whenever wider than tall or ≥ 700 pt wide, so a landscape photo on iPad portrait got a 514 pt column | For the container and the photo's aspect ratio the policy computes the fitted photo area with (a) controls below (panel at its 35% / 45% AX cap) and (b) a 320–380 pt side panel, and picks the larger (ties: below). Minimums kept: panel only if the photo column keeps ≥ 320 pt; photo ≥ 40% of the height on phone portrait at AX sizes; Save copy stays in the top bar. Results: iPad portrait + landscape photo → below; iPad landscape and iPhone landscape → side panel; iPhone portrait → below. A 3:4 photo on iPad portrait is within a few percent either way and follows the window's exact (safe-area) size | `EditorLayoutPolicy.arrangement(for:photoAspectRatio:isAccessibilitySize:)` |

Tests: `EditorBehaviourTests` (Auto applied / Retry / no-model; each Strength rule), `SavedEditRestoreTests` (no model run on restore, Auto block and strength untouched, changed Look's stop), `EditorLayoutTests` (policy cases, "chosen area is the larger" property, laid-out phone/pad × portrait/landscape photo), new snapshot `editor-lut-pad-portrait-landscape-photo`, UI step "same stop keeps Strength". Failing-first output: `~/.codex/artifacts/lightly/review-d5690dd-fixes/ios/`.

Verified after the fixes (simulators only): 358 unit/snapshot/layout tests, 0 failures (was 341); UI suite on iPhone 17: 6 passed, 1 skipped (orientation, rotation lock), plus the orientation test passing on iPad Pro 11-inch (M5) (portrait with a landscape library photo → controls below; landscape → side panel). `scripts/check_app_icon.sh` passed and the bundled `LookPack/` is identical to `experiments/presets/look_pack/out` (format 2, 18 LUTs). No Auto-applied screenshot of the app: the shipped build has only the "no model" enhancer and there is no DEBUG enhancer that produces a LUT, so Auto applied is evidenced by the unit tests' pixels only.

## 3. Verification

Simulators only (no physical device). Snapshots on iPhone 17 / iOS 26.5 / Large text; the simulator's own text size was restored to extra-extra-extra-large afterwards.

- **Unit, snapshot and layout tests:** 341 tests, 0 failures (was 292). New: `SavedEditFormatTests` (reads `shared/fixtures/edit-state/`), `SavedEditRestoreTests`, `EditorBehaviourTests`, layout tests for narrow / wide / split view / AX5 portrait and landscape / chip wrapping, 7 new snapshots (Strength + Redo, Look changed, Look unavailable, Auto failed, phone landscape, iPad portrait, iPad landscape comparing).
- **UI tests (iPhone 17):** 7 tests, 6 passed, 1 skipped, 0 failures. The full flow: photo → Auto unavailable notice (no Retry) → two presets in one category → Strength → a preset in a second category → Compare (toggle and hold) → Undo → Redo → Reset → Undo → Save copy. The orientation test is skipped on this iPhone 17 simulator because it has rotation lock on (Safari does not rotate either). It passes on iPhone 17 Pro (landscape side panel) and iPad Pro 11-inch (M5) (side panel in portrait and landscape).
- **Installed app:** `scripts/check_app_icon.sh` passed. `Lightly.app/LookPack/manifest.json` is format 2 with 18 LUTs, every sha256 matching, identical to `experiments/presets/look_pack/out` (the rebuilt pack from `6f6b66f`). The Home Screen shows the Lightly icon.
- **Photos library:** before and after the UI suite, all 15 existing photos have the same sha256; two new 4032×3024 JPEGs were added (one per Save copy).
- **Evidence:** `~/.codex/artifacts/lightly/editor-milestone-20261002/ios/` (screenshots per step, screen recording of the UI suite, xcresult summaries, before/after hashes, snapshot before/after images, failing-first test output).

## 4. Deferred

- **Relaunch restore.** `LUTEditorViewModel(restoringSession:)` and `LUTEditSession.savedSession(source:auto:)` are tested end to end, but the app has no entry point that restores a session after relaunch. Reopening the Original needs Photos read access or a private copy of the photo; both are product decisions for the recovery snapshot (spec §5.5, M4). Marked `// DEFERRED:` at the call site.
- **Auto block of a saved edit.** iOS writes `SavedAutoResult.noModelInBuild` (zero weights, strength 0, `no-model-in-build`) because no Auto model ships. Real weights come with a production model.
- **Float text below 1e-3.** Swift writes `0.0001` where Kotlin writes `1.0E-4`; both read back to the same value, but such edits would not be byte-identical across platforms. No fixture covers it.
- **Category labels and Look names** are pack data shown verbatim (localisation and product names: spec U8).

## 5. Hardware-only limitations (not verifiable on a simulator)

- GPU render time and memory of the Metal LUT pass on 48 MP originals (preview latency while dragging, tiled export time); the simulator's GPU is the Mac's.
- The real Photos library on a device: picker behaviour with iCloud originals, HEIC/ProRAW inputs, add-only permission prompts, and that the saved copy appears in the user's library.
- Display: P3 panels, True Tone and HDR gain maps (dropped in V1 export) as seen on a device.
- Rotation and split view on a physical iPad (Stage Manager window sizes), and touch precision of the stepped track and Strength control with a finger.
- Thermal and memory pressure during long editing sessions.
