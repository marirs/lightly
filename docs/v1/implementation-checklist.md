# Lightly 1.0 implementation checklist

Generated from the frozen prototype (docs/ui/app/screens.js, revision ff5c5ae). One row per approved screen or state.
Status values (**updated 2026-10-05 from recorded evidence only**; no new audit or matrix):
- **verified**: compared side by side with the reference at the captured cell(s) and behaviour-tested; only system-drawn chrome differs. Unless noted, the cells are iPhone 17 portrait light default (iOS; the slice-3 matrix covers all 24 cells) and Pixel 9 Pro portrait light default (Android; the slice-2 matrix covers 28 cells). Every other device, theme and text cell is **unverified** (bulk capture paused).
- **decision**: built, but differs from the approved design in a recorded way that awaits the owner's ruling (ids in Notes; see the slice reviews). Not accepted.
- **defective**: an open defect in our implementation.
- **implemented**: built and tested, without valid visual evidence (no capture, or a stale one).
- **blocked**: needs something outside the code (model D1, legal text D2, a physical device, owner input).
- **missing**: not built. **n/a**: not applicable on that platform.
Evidence: docs/v1/slice1-review.md, slice2-review.md, slice3-review.md, slice3-ios.md, slice4-ios.md, slice4-android.md, slice5-ios.md, checks-2026-10-04.md, android-vision-evaluation.md §5, experiments/depth/results/portrait-edges-2026-10-05/.
Slice: delivery order (1 entry/More/Preferences · 2 session/Develop/pack · 3 Background/Portrait · 4 Edit/Effects · 5 Watermark/Border/export · 6 recovery/accessibility/devices/release).

Every row applies to all supported layouts: phones and folded foldables (portrait), unfolded foldables and 11"/13" tablets (portrait and landscape), light and dark, default and large text.

## Start and photo choice

| Screen / state | id | Slice | iOS | Android | Notes |
|---|---|---|---|---|---|
| Launch | `launch` | 1 | verified | decision | Android: splash mark ≈24 dp higher (slice-1 #8, system splash geometry) |
| Welcome | `welcome` | 1 | verified | decision | Android Fold inner: content centred, not near the top (slice-1 #6); recapture pending |
| Welcome · More (⋮) | `welcome-more` | 1 | verified | verified |  |
| Choose a photo · system photo picker | `picker` | 1 | implemented | implemented | System UI: real flows only (Pixel 9 Pro); not capturable on the iOS Simulator |
| Picker cancelled · back to Welcome, nothing changed | `picker-cancelled` | 1 | implemented | implemented | Behaviour tested; system UI |
| Camera · system permission request | `camera-permission` | 1 | blocked | implemented | iOS: Simulator has no camera, needs the iPhone. Android: real flow on Pixel 9 Pro emulator |
| Camera · permission denied | `camera-denied` | 1 | blocked | implemented | iOS: needs the iPhone |
| Camera · system capture | `camera` | 1 | blocked | implemented | iOS: needs the iPhone |
| Camera · retake or use photo | `camera-review` | 1 | blocked | implemented | iOS: needs the iPhone |
| Photo can’t be opened (unsupported or unavailable) | `load-failed` | 1 | verified | verified | Message-screen icon at the leading edge as drawn (slice-1 #11, confirm) |

## Opening and automatic Develop

| Screen / state | id | Slice | iOS | Android | Notes |
|---|---|---|---|---|---|
| Opening the photo (photo stays visible) | `loading` | 2 | verified | verified | iOS slice-2 captures STALE for photo area (grain port); Android 28-cell matrix ea45916 (agent review) |
| Automatic Develop in progress | `developing` | 2 | blocked | blocked | D1: no Auto model ships; shown only as an injected state |
| Developed · Auto applied | `developed` | 2 | blocked | blocked | D1 |
| Automatic Develop failed · Retry or continue with original | `develop-failed` | 2 | blocked | blocked | D1 (injected state only) |
| Automatic correction unavailable · presets still work | `model-unavailable` | 2 | verified | verified | The shipping state while D1 is open |

## Develop

| Screen / state | id | Slice | iOS | Android | Notes |
|---|---|---|---|---|---|
| Preset applied (landscape photo, no Portrait tool) | `dev-preset` | 2 | decision | decision | M9/S8 grain uncalibrated on grain presets (Lightroom references needed); iOS recapture after grain port pending |
| Auto off · stop zero reads Original | `dev-original` | 2 | verified | verified |  |
| Dragging · preview before release, fine control | `dev-dragging` | 2 | verified | verified |  |
| Browsing another category · applied preset unchanged | `dev-browse` | 2 | verified | verified |  |
| Largest category: Cinematic, last of 564 | `dev-large` | 2 | verified | verified |  |
| Long preset name | `dev-long-name` | 2 | decision | verified | iOS M4: SF text metrics wrap differently |
| Amount (secondary control) | `dev-amount` | 2 | verified | verified |  |
| Preset starred as a favourite | `dev-starred` | 2 | verified | verified |  |
| Favourites shortcut (up to five) | `dev-favourites` | 2 | decision | decision | M9 grain |
| Favourites full · sixth star | `dev-fav-full` | 2 | verified | verified |  |
| Replace a favourite | `dev-fav-replace` | 2 | verified | verified |  |
| Black & White preset | `dev-bw` | 2 | verified | verified |  |
| Landscape-orientation photograph | `dev-landscape-photo` | 2 | verified | verified |  |
| Portrait photo · Portrait tool offered | `dev-portrait-photo` | 2 | decision | decision | M9 grain |

## Background

| Screen / state | id | Slice | iOS | Android | Notes |
|---|---|---|---|---|---|
| Focus & Blur · target, Lens style, bokeh | `bg-focus` | 3 | decision | decision | S1 blur strength (≈19 % weaker on iPhone, stronger on tablets; provisional display-relative sizing); S3 default focus on the face; Android: focused check only |
| Focus & Blur · Soft | `bg-soft` | 3 | decision | decision | S1 |
| Focus & Blur · Swirl | `bg-swirl` | 3 | decision | decision | S1 |
| Focus & Blur · Motion | `bg-motion` | 3 | decision | decision | S1 |
| Refine edges (brush) | `bg-refine` | 3 | verified | implemented | Android: implemented, no valid capture since D3 |
| Change background · image, position, scale | `bg-change-image` | 3 | implemented | defective | iOS reported hair-fringe defect FIXED on live iPhone (2026-10-08); see ios-hair-fix-2026-10-08.md. Full visual matrix remains unverified. Android: teal/grey hair cast and object halos remain open. |
| Change background · solid colour | `bg-change-colour` | 3 | implemented | defective | iOS reported hair-fringe defect FIXED on live iPhone (2026-10-08); see ios-hair-fix-2026-10-08.md. Full visual matrix remains unverified. Android: teal/grey hair cast and object halos remain open. |
| Change background · gradient | `bg-change-gradient` | 3 | implemented | defective | iOS reported hair-fringe defect FIXED on live iPhone (2026-10-08); see ios-hair-fix-2026-10-08.md. Full visual matrix remains unverified. Android: teal/grey hair cast and object halos remain open. |
| After replacement, the same Focus & Blur still works | `bg-replaced-blur` | 3 | defective | defective | Replacement edge defects below. (The Android 768 px blur glow of checks-2026-10-04 was fixed in e56b907; goldens pass 2026-10-06.) |
| Finding the subject · cancellable | `bg-separating` | 3 | decision | verified | iOS M4 (SF line height); Android: cancel + retry run with real models (2026-10-05) |
| Subject separation failed · edits kept | `bg-failed` | 3 | decision | decision | M9/S8 (its setup applies Glow) |
| No clear subject | `bg-no-subject` | 3 | verified | verified | Android: U²-Netp decides (experimental, debug/gated; held-out check fails on 4 of 9 scenes, release blocker); lake shows the approved state (2026-10-05) |

## Portrait

| Screen / state | id | Slice | iOS | Android | Notes |
|---|---|---|---|---|---|
| Skin · single face selected automatically | `pt-skin` | 3 | verified | implemented | iOS: matrix 5c3a3ee with fixture mattes; Android: focused Pixel 9 Pro check 60c8b22 only |
| Under-eye | `pt-under` | 3 | verified | implemented |  |
| Eyes | `pt-eyes` | 3 | verified | implemented |  |
| Teeth | `pt-teeth` | 3 | decision | implemented | iOS P1 ring proportion residual |
| Hair & Beard | `pt-hair` | 3 | verified | implemented |  |
| Portrait on a landscape-orientation photograph | `pt-landscape-photo` | 3 | decision | implemented | iOS P1 |
| Several faces · choose a face, separate adjustments | `pt-multi` | 3 | decision | implemented | P2: licensed group photo instead of the approved one-face screen. Design gap: No licensed multi-person photograph is available locally. The face picker is implemented (one chip and ring per face) but only a one-face photo can be shown. |
| People found, but no usable face | `pt-no-usable-face` | 3 | blocked | defective | iOS P3: Vision in the Simulator finds no person in the bar photo, needs the iPhone. Android: approved notice shown; the disco-ball ring was fixed in 0904c81 (re-checked 2026-10-06), but one dim ring sits beside the middle person's head, over the shelf |
| No person · Portrait tool hidden | `pt-hidden` | 3 | verified | verified | Android: boat and swan hide Portrait with real models (2026-10-05) |

## Edit

| Screen / state | id | Slice | iOS | Android | Notes |
|---|---|---|---|---|---|
| Crop · aspect ratios | `ed-crop` | 4 | verified | verified | iPhone 17 / Pixel 9 Pro light-default only |
| Rotate and flip | `ed-rotate` | 4 | verified | verified |  |
| Straighten | `ed-straighten` | 4 | decision | decision | E1 contract zoom 1.077 vs fixed 1.12 |
| Perspective | `ed-perspective` | 4 | decision | decision | E2 keystone applied; Q1 Edit dot rule |
| Adjust · Light (exposure, contrast, highlights, shadows) | `ed-adjust-light` | 4 | verified | verified |  |
| Adjust · Colour (white balance, saturation) | `ed-adjust-colour` | 4 | verified | verified |  |
| Adjust · Detail | `ed-adjust-detail` | 4 | verified | verified |  |
| Remove · brush over unwanted objects | `ed-remove` | 4 | verified | verified | LaMa behind the Remove release gate (Places2 legal) |
| Removing · cancellable | `ed-removing` | 4 | decision | verified | iOS M4 |
| Remove failed · edits kept | `ed-remove-failed` | 4 | verified | verified |  |

## Effects

| Screen / state | id | Slice | iOS | Android | Notes |
|---|---|---|---|---|---|
| Light Leaks · style, intensity, position, rotation | `fx-leak` | 4 | verified | verified |  |
| Grain · style, amount, size, roughness | `fx-grain` | 4 | decision | decision | M9 grain uncalibrated |
| Vignette · amount, size, softness | `fx-vignette` | 4 | decision | decision | G2 vignette uncalibrated |
| Combined effects | `fx-combined` | 4 | decision | decision | M9, G2 |
| Preset already contains grain · shown, not doubled silently | `fx-preset-conflict` | 4 | decision | decision | F1 substitute Film preset; M9 |

**Requested addition (owner, 2026-10-04): Effects › Selective Colour.** Reference: `docs/ui/proposals/selective-colour` at `330cf5b`; what was accepted, and what is still open, is in its README "Status". Not visually accepted in the apps yet.

| Screen / state | id | Slice | iOS | Android | Notes |
|---|---|---|---|---|---|
| Nothing kept: "Tap a colour in the photo to keep it." | `fx-selective-empty` | 4 | implemented | implemented | fd8f657, 980d8b1; awaiting the owner's visual acceptance; defaults provisional |
| Kept colours, (+), Clear; × per colour when more than one; Range, Strength | `fx-selective-picked`, `fx-selective-multi` | 4 | implemented | implemented | Up to 8 colours; Range and Strength shared by all colours (open decision); pick race fixed (4d6c436, f1a1dd5) |
| Temporary overlay of what stays coloured | (proposal only) | 4 | missing | missing | Open decision |

## Watermark

| Screen / state | id | Slice | iOS | Android | Notes |
|---|---|---|---|---|---|
| Watermark · None | `wm-none` | 5 | verified | verified |  |
| Signature · saved, drawn and imported | `wm-signature` | 5 | decision | decision | W1 sizing: provisional display-relative approach, owner policy pending; saved size depends on the editing device |
| Draw and save a signature | `wm-sig-draw` | 5 | decision | verified | iOS W1 |
| Import a signature (keeps its own appearance) | `wm-sig-import` | 5 | verified | verified | W6 fixed (Use always works); W10 copy provisional |
| Text · Allura, Cormorant Garamond, Inter, Caveat | `wm-text` | 5 | decision | decision | W1, W4 (real Cormorant Garamond), W5 sample name |
| Logo · position, size, opacity | `wm-logo` | 5 | decision | verified | iOS W1 |
| Watermark placed on the border | `wm-on-border` | 5 | verified | verified |  |

## Border

| Screen / state | id | Slice | iOS | Android | Notes |
|---|---|---|---|---|---|
| Border · None (preferred border is None) | `bd-none` | 5 | implemented | verified | iOS: not recaptured since slice 1 |
| Solid · colour, width | `bd-solid` | 5 | implemented | verified |  |
| Photo Frame · frame, mat, spacing | `bd-frame` | 5 | implemented | verified |  |
| Polaroid · larger bottom margin, signature on margin | `bd-polaroid` | 5 | decision | verified | iOS W1; W7 with no saved signature |

## Compare, save and leaving

| Screen / state | id | Slice | iOS | Android | Notes |
|---|---|---|---|---|---|
| Compare · hold to see the original | `compare` | 5 | verified | verified | M5 closed |
| Leaving with unsaved changes | `leave-unsaved` | 5 | implemented | implemented | Recapture pending (stale since slice 4) |
| First save · system Photos permission (iOS) | `save-permission` | 5 | blocked | n/a | iOS: system dialog, needs the iPhone / a fresh Simulator; Android: not applicable |
| Photos permission denied · edits kept (iOS) | `save-permission-denied` | 5 | implemented | n/a | iOS: unit-tested; Android: not applicable |
| Saving a new JPEG | `saving` | 5 | decision | decision | G2 under the scrim |
| Saved · share, keep editing, another photo | `saved` | 5 | decision | decision | G2 |
| Share the saved copy (system share) | `share` | 5 | decision | implemented | S1: the real system share sheet, not the prototype mock |
| Choose another photo after saving | `another-photo` | 5 | implemented | implemented | Behaviour tested; Android U²-Netp flows used separate launches, not this path |
| Storage full · edits kept | `storage-full` | 5 | implemented | implemented | Alert implemented; no capture or forced-condition run |
| Export failed · edits kept | `export-failed` | 5 | implemented | implemented | Alert implemented; no capture or forced-condition run |

## More, preferences, legal and about

| Screen / state | id | Slice | iOS | Android | Notes |
|---|---|---|---|---|---|
| More (from the editor) | `more` | 1 | verified | verified |  |
| Preferences | `preferences` | 1 | verified | verified |  |
| Manage favourites · reorder up to five | `pref-favourites` | 1 | verified | verified | iOS reorder defect fixed in 9df579b/476ab35; testFavouritesCanBeRemovedAndReordered passes (2026-10-05 at 0904c81) |
| Saved signature | `pref-signature` | 1 | decision | verified | iOS: slice-1 #1 phone pages inside the More sheet; W3 |
| Preferred border · None by default | `pref-border` | 1 | verified | verified |  |
| Legal | `legal` | 1 | decision | decision | Slice-1 #1 (sheet vs full page) awaits decision |
| Privacy Policy (draft placeholder) | `privacy` | 1 | blocked | blocked | D2: no approved text (owner) |
| Terms of Use (draft placeholder) | `terms` | 1 | blocked | blocked | D2 |
| About · version and build | `about` | 1 | decision | decision | Real version values; scheme proposed (release README) |
| Support | `support` | 1 | blocked | blocked | D2: no destination |

## Recovery states

| Screen / state | id | Slice | iOS | Android | Notes |
|---|---|---|---|---|---|
| Camera · permission denied | `camera-denied` | 6 | blocked | implemented | iOS: needs the iPhone |
| Photo can’t be opened (unsupported or unavailable) | `load-failed` | 6 | verified | verified | Message-screen icon at the leading edge as drawn (slice-1 #11, confirm) |
| Automatic Develop failed · Retry or continue with original | `develop-failed` | 6 | blocked | blocked | D1 (injected state only) |
| Automatic correction unavailable · presets still work | `model-unavailable` | 6 | verified | verified | The shipping state while D1 is open |
| Finding the subject · cancellable | `bg-separating` | 6 | decision | verified | iOS M4 (SF line height); Android: cancel + retry run with real models (2026-10-05) |
| Subject separation failed · edits kept | `bg-failed` | 6 | decision | decision | M9/S8 (its setup applies Glow) |
| No clear subject | `bg-no-subject` | 6 | verified | verified | Android: U²-Netp decides (experimental, debug/gated; held-out check fails on 4 of 9 scenes, release blocker); lake shows the approved state (2026-10-05) |
| People found, but no usable face | `pt-no-usable-face` | 6 | blocked | defective | iOS P3: Vision in the Simulator finds no person in the bar photo, needs the iPhone. Android: approved notice shown; the disco-ball ring was fixed in 0904c81 (re-checked 2026-10-06), but one dim ring sits beside the middle person's head, over the shelf |
| Removing · cancellable | `ed-removing` | 6 | decision | verified | iOS M4 |
| Remove failed · edits kept | `ed-remove-failed` | 6 | verified | verified |  |
| Leaving with unsaved changes | `leave-unsaved` | 6 | implemented | implemented | Recapture pending (stale since slice 4) |
| Photos permission denied · edits kept (iOS) | `save-permission-denied` | 6 | implemented | n/a | iOS: unit-tested; Android: not applicable |
| Storage full · edits kept | `storage-full` | 6 | implemented | implemented | Alert implemented; no capture or forced-condition run |
| Export failed · edits kept | `export-failed` | 6 | implemented | implemented | Alert implemented; no capture or forced-condition run |

## Combined edit, one session

| Screen / state | id | Slice | iOS | Android | Notes |
|---|---|---|---|---|---|
| 1. Develop preset | `demo-1` | 5 | implemented | implemented | No combined-session capture yet |
| 2. Background replaced | `demo-2` | 5 | defective | defective | Replacement edge defects |
| 3. Focus and blur on the new background | `demo-3` | 5 | defective | defective |  |
| 4. Portrait adjustment | `demo-4` | 5 | implemented | implemented |  |
| 5. Effect | `demo-5` | 5 | decision | decision | M9/G2 |
| 6. Signature | `demo-6` | 5 | decision | decision | W1 |
| 7. Polaroid border, signature on the margin | `demo-7` | 5 | decision | decision | W1/W7 |
| 8. Saving the new JPEG | `demo-8` | 5 | implemented | implemented |  |
| 9. Saved · original unchanged | `demo-9` | 5 | implemented | implemented |  |

## Interactions and behaviours (not screens)

| Behaviour | Slice | iOS | Android | Notes |
|---|---|---|---|---|
| Launch → Welcome; Privacy Policy link on Welcome returns to Welcome | 1 | verified | verified | Privacy text is D2 (no approved text) |
| More (⋮): Preferences, Legal, About; pages on phones, form sheets on tablets | 1 | decision | decision | Slice-1 #1: iOS keeps pages in the sheet on phones, Android full pages |
| Appearance System/Light/Dark persists across launches | 1 | implemented | implemented | Unit-tested; persistence across launches not captured |
| Keep photo metadata (default on) and Include location (default off) are independent and persist | 1 | implemented | decision | Android: LensModel not copied (needs androidx.exifinterface), GPS of picked photos needs ACCESS_MEDIA_LOCATION (owner decision) |
| Native picker, camera, permission flows; cancellation returns unchanged | 1 | blocked | implemented | iOS camera needs the iPhone; Android real flows on the emulator |
| One session per photo; switching photos invalidates all work for the previous photo | 2 | implemented | implemented | Unit-tested; Android U²-Netp flows used separate launches |
| Undo/Redo restore the complete combined edit across every tool | 2 | implemented | implemented | Unit-tested; Android Background replace → Undo → Redo with real models (2026-10-05) |
| Ruler: one stop per preset, preview while dragging, one undo step on release, no interpolation, no prev/next arrows | 2 | decision | decision | Fine-mode timing/speed not specified by the design (slice-2 conflict 2) |
| Category change alone never changes the applied Look; a new Look replaces only the Develop Look | 2 | implemented | implemented | Unit-tested |
| Stop zero reads Auto only when Auto correction is applied; otherwise Original | 2 | blocked | blocked | D1: no Auto model, so stop zero always reads Original |
| Amount secondary; re-selecting the applied preset keeps its Amount | 2 | implemented | implemented | Unit-tested |
| Favourites: up to five shortcuts, manage/reorder in Preferences, replace when full | 2 | implemented | implemented | iOS reorder UI test passes (2026-10-05) |
| Hold-to-compare shows the original; accessible toggle | 2 | verified | verified |  |
| Preview and export evaluate the same committed recipe; latest-request-wins previews | 2 | decision | decision | Preview and export agree on one device; with the provisional W1 sizing the saved watermark/blur size depends on the editing device (owner sizing policy pending) |
| Auto is real image-adaptive correction, or the approved unavailable state | 2 | blocked | blocked | D1: the approved unavailable state ships |
| Background: real subject/depth processing; Focus & Blur usable after replacement | 3 | defective | defective | Replacement edge quality (release blocker); Android object cut-out experimental, its no-subject rule fails held-out scenes; depth model behind the legal gate |
| Portrait: hidden without a person; auto-select one usable face; choose among faces; per-face settings | 3 | implemented | defective | iOS: live-device check of the bar photo and face-quality threshold pending (needs the iPhone). Android: ring drawn on a false face (bar disco ball) |
| Edit: crop/aspect, rotate/flip, straighten, perspective, adjust, remove brush with real processing | 4 | decision | decision | E1, E2, Q1; Remove behind the Places2 legal gate |
| Effects: light leaks, grain, vignette combine; preset grain/vignette composed as approved, never silently doubled or dropped | 4 | decision | decision | M9 grain, G2 vignette uncalibrated (Lightroom references), F1 |
| Watermark: signature draw/import/save/reuse, text in Allura/Cormorant Garamond/Inter/Caveat, logo; on photo or border | 5 | decision | decision | W1–W10 (W1 sizing policy, W6 fixed) |
| Border: None/Solid/Photo Frame/Polaroid with larger bottom margin and margin signature | 5 | implemented | verified | iOS Border screens not recaptured since slice 1 |
| Save copy: new JPEG, original unchanged, bounded memory, no duplicate on cancel; same metadata policy for Share | 5 | implemented | implemented | Original unchanged and cancel tested; device memory at 48 MP unverified (needs dev devices) |
| Metadata: four switch combinations verified on saved files; colour profile kept; no stale dimensions/orientation/thumbnail | 5 | implemented | decision | iOS unit-tested on saved files; Android LensModel and picked-photo GPS (above) |
| Recovery: load failure, permissions, storage full, export failure, lost access, unavailable models, cancelled tools; edits preserved | 6 | implemented | implemented | iOS restore after a system kill fixed (c230f28): Save → restore and close → restore UI pairs pass; force-quit on a device unverified |
| Accessibility: large text, VoiceOver/TalkBack, contrast, 44 pt targets | 6 | implemented | implemented | One large-text cell per platform checked (2026-10-04); VoiceOver/TalkBack not run end to end |
| Layouts: hinge/posture aware, safe areas, gesture areas, all reference sizes | 6 | decision | decision | iOS iPad: content 8 pt lower = the iPadOS status bar (M2, owner decision; the separate "4 pt" offset was a measurement error, 2026-10-05); Android system-bar offset S1 (decision); most cells unverified |
| Icon and preset-pack packaging verified before every install | 6 | verified | verified | Build-time checks on every assemble / release config (a993c4d) |

## What remains

Moved to the single remaining-work list, `docs/v1/remaining-work.md` (per platform: defects, unverified device
behaviour, unfinished features, owner decisions).
