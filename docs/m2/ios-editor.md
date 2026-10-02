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

Filled in as each gap lands; commit IDs are in the final report.
