# Lightly 1.0 implementation checklist

Generated from the frozen prototype (design/app/screens.js, revision ff5c5ae). One row per approved screen or state.
Status values: **missing**, **partial** (exists but differs from the approved UX or lacks real processing), **reuse** (existing code matches and is reused), **done** (implemented, compared side by side with the prototype at the reference sizes, behaviour tested), **blocked** (needs the dependency named in Notes).
Slice: delivery order (1 entry/More/Preferences · 2 session/Develop/pack · 3 Background/Portrait · 4 Edit/Effects · 5 Watermark/Border/export · 6 recovery/accessibility/devices/release).

Every row applies to all supported layouts: phones and folded foldables (portrait), unfolded foldables and 11"/13" tablets (portrait and landscape), light and dark, default and large text.

## Start and photo choice

| Screen / state | id | Slice | iOS | Android | Notes |
|---|---|---|---|---|---|
| Launch | `launch` | 1 | missing | missing |  |
| Welcome | `welcome` | 1 | missing | missing |  |
| Welcome · More (⋮) | `welcome-more` | 1 | missing | missing |  |
| Choose a photo · system photo picker | `picker` | 1 | missing | missing |  |
| Picker cancelled · back to Welcome, nothing changed | `picker-cancelled` | 1 | missing | missing |  |
| Camera · system permission request | `camera-permission` | 1 | missing | missing |  |
| Camera · permission denied | `camera-denied` | 1 | missing | missing |  |
| Camera · system capture | `camera` | 1 | missing | missing |  |
| Camera · retake or use photo | `camera-review` | 1 | missing | missing |  |
| Photo can’t be opened (unsupported or unavailable) | `load-failed` | 1 | missing | missing |  |

## Opening and automatic Develop

| Screen / state | id | Slice | iOS | Android | Notes |
|---|---|---|---|---|---|
| Opening the photo (photo stays visible) | `loading` | 2 | missing | missing |  |
| Automatic Develop in progress | `developing` | 2 | missing | missing |  |
| Developed · Auto applied | `developed` | 2 | missing | missing |  |
| Automatic Develop failed · Retry or continue with original | `develop-failed` | 2 | missing | missing |  |
| Automatic correction unavailable · presets still work | `model-unavailable` | 2 | missing | missing |  |

## Develop

| Screen / state | id | Slice | iOS | Android | Notes |
|---|---|---|---|---|---|
| Preset applied (landscape photo, no Portrait tool) | `dev-preset` | 2 | missing | missing |  |
| Auto off · stop zero reads Original | `dev-original` | 2 | missing | missing |  |
| Dragging · preview before release, fine control | `dev-dragging` | 2 | missing | missing |  |
| Browsing another category · applied preset unchanged | `dev-browse` | 2 | missing | missing |  |
| Largest category: Cinematic, last of 564 | `dev-large` | 2 | missing | missing |  |
| Long preset name | `dev-long-name` | 2 | missing | missing |  |
| Amount (secondary control) | `dev-amount` | 2 | missing | missing |  |
| Preset starred as a favourite | `dev-starred` | 2 | missing | missing |  |
| Favourites shortcut (up to five) | `dev-favourites` | 2 | missing | missing |  |
| Favourites full · sixth star | `dev-fav-full` | 2 | missing | missing |  |
| Replace a favourite | `dev-fav-replace` | 2 | missing | missing |  |
| Black & White preset | `dev-bw` | 2 | missing | missing |  |
| Landscape-orientation photograph | `dev-landscape-photo` | 2 | missing | missing |  |
| Portrait photo · Portrait tool offered | `dev-portrait-photo` | 2 | missing | missing |  |

## Background

| Screen / state | id | Slice | iOS | Android | Notes |
|---|---|---|---|---|---|
| Focus & Blur · target, Lens style, bokeh | `bg-focus` | 3 | missing | missing |  |
| Focus & Blur · Soft | `bg-soft` | 3 | missing | missing |  |
| Focus & Blur · Swirl | `bg-swirl` | 3 | missing | missing |  |
| Focus & Blur · Motion | `bg-motion` | 3 | missing | missing |  |
| Refine edges (brush) | `bg-refine` | 3 | missing | missing |  |
| Change background · image, position, scale | `bg-change-image` | 3 | missing | missing |  |
| Change background · solid colour | `bg-change-colour` | 3 | missing | missing |  |
| Change background · gradient | `bg-change-gradient` | 3 | missing | missing |  |
| After replacement, the same Focus & Blur still works | `bg-replaced-blur` | 3 | missing | missing |  |
| Finding the subject · cancellable | `bg-separating` | 3 | missing | missing |  |
| Subject separation failed · edits kept | `bg-failed` | 3 | missing | missing |  |
| No clear subject | `bg-no-subject` | 3 | missing | missing |  |

## Portrait

| Screen / state | id | Slice | iOS | Android | Notes |
|---|---|---|---|---|---|
| Skin · single face selected automatically | `pt-skin` | 3 | missing | missing |  |
| Under-eye | `pt-under` | 3 | missing | missing |  |
| Eyes | `pt-eyes` | 3 | missing | missing |  |
| Teeth | `pt-teeth` | 3 | missing | missing |  |
| Hair & Beard | `pt-hair` | 3 | missing | missing |  |
| Portrait on a landscape-orientation photograph | `pt-landscape-photo` | 3 | missing | missing |  |
| Several faces · choose a face, separate adjustments | `pt-multi` | 3 | missing | missing | Design gap: No licensed multi-person photograph is available locally. The face picker is implemented (one chip and ring per face) but only a one-face photo can be shown. |
| People found, but no usable face | `pt-no-usable-face` | 3 | missing | missing |  |
| No person · Portrait tool hidden | `pt-hidden` | 3 | missing | missing |  |

## Edit

| Screen / state | id | Slice | iOS | Android | Notes |
|---|---|---|---|---|---|
| Crop · aspect ratios | `ed-crop` | 4 | missing | missing |  |
| Rotate and flip | `ed-rotate` | 4 | missing | missing |  |
| Straighten | `ed-straighten` | 4 | missing | missing |  |
| Perspective | `ed-perspective` | 4 | missing | missing |  |
| Adjust · Light (exposure, contrast, highlights, shadows) | `ed-adjust-light` | 4 | missing | missing |  |
| Adjust · Colour (white balance, saturation) | `ed-adjust-colour` | 4 | missing | missing |  |
| Adjust · Detail | `ed-adjust-detail` | 4 | missing | missing |  |
| Remove · brush over unwanted objects | `ed-remove` | 4 | missing | missing |  |
| Removing · cancellable | `ed-removing` | 4 | missing | missing |  |
| Remove failed · edits kept | `ed-remove-failed` | 4 | missing | missing |  |

## Effects

| Screen / state | id | Slice | iOS | Android | Notes |
|---|---|---|---|---|---|
| Light Leaks · style, intensity, position, rotation | `fx-leak` | 4 | missing | missing |  |
| Grain · style, amount, size, roughness | `fx-grain` | 4 | missing | missing |  |
| Vignette · amount, size, softness | `fx-vignette` | 4 | missing | missing |  |
| Combined effects | `fx-combined` | 4 | missing | missing |  |
| Preset already contains grain · shown, not doubled silently | `fx-preset-conflict` | 4 | missing | missing |  |

## Watermark

| Screen / state | id | Slice | iOS | Android | Notes |
|---|---|---|---|---|---|
| Watermark · None | `wm-none` | 5 | missing | missing |  |
| Signature · saved, drawn and imported | `wm-signature` | 5 | missing | missing |  |
| Draw and save a signature | `wm-sig-draw` | 5 | missing | missing |  |
| Import a signature (keeps its own appearance) | `wm-sig-import` | 5 | missing | missing |  |
| Text · Allura, Cormorant Garamond, Inter, Caveat | `wm-text` | 5 | missing | missing |  |
| Logo · position, size, opacity | `wm-logo` | 5 | missing | missing |  |
| Watermark placed on the border | `wm-on-border` | 5 | missing | missing |  |

## Border

| Screen / state | id | Slice | iOS | Android | Notes |
|---|---|---|---|---|---|
| Border · None (preferred border is None) | `bd-none` | 5 | missing | missing |  |
| Solid · colour, width | `bd-solid` | 5 | missing | missing |  |
| Photo Frame · frame, mat, spacing | `bd-frame` | 5 | missing | missing |  |
| Polaroid · larger bottom margin, signature on margin | `bd-polaroid` | 5 | missing | missing |  |

## Compare, save and leaving

| Screen / state | id | Slice | iOS | Android | Notes |
|---|---|---|---|---|---|
| Compare · hold to see the original | `compare` | 5 | missing | missing |  |
| Leaving with unsaved changes | `leave-unsaved` | 5 | missing | missing |  |
| First save · system Photos permission (iOS) | `save-permission` | 5 | missing | missing |  |
| Photos permission denied · edits kept (iOS) | `save-permission-denied` | 5 | missing | missing |  |
| Saving a new JPEG | `saving` | 5 | missing | missing |  |
| Saved · share, keep editing, another photo | `saved` | 5 | missing | missing |  |
| Share the saved copy (system share) | `share` | 5 | missing | missing |  |
| Choose another photo after saving | `another-photo` | 5 | missing | missing |  |
| Storage full · edits kept | `storage-full` | 5 | missing | missing |  |
| Export failed · edits kept | `export-failed` | 5 | missing | missing |  |

## More, preferences, legal and about

| Screen / state | id | Slice | iOS | Android | Notes |
|---|---|---|---|---|---|
| More (from the editor) | `more` | 1 | missing | missing |  |
| Preferences | `preferences` | 1 | missing | missing |  |
| Manage favourites · reorder up to five | `pref-favourites` | 1 | missing | missing |  |
| Saved signature | `pref-signature` | 1 | missing | missing |  |
| Preferred border · None by default | `pref-border` | 1 | missing | missing |  |
| Legal | `legal` | 1 | missing | missing |  |
| Privacy Policy (draft placeholder) | `privacy` | 1 | missing | missing |  |
| Terms of Use (draft placeholder) | `terms` | 1 | missing | missing |  |
| About · version and build | `about` | 1 | missing | missing |  |
| Support | `support` | 1 | missing | missing |  |

## Recovery states

| Screen / state | id | Slice | iOS | Android | Notes |
|---|---|---|---|---|---|
| Camera · permission denied | `camera-denied` | 6 | missing | missing |  |
| Photo can’t be opened (unsupported or unavailable) | `load-failed` | 6 | missing | missing |  |
| Automatic Develop failed · Retry or continue with original | `develop-failed` | 6 | missing | missing |  |
| Automatic correction unavailable · presets still work | `model-unavailable` | 6 | missing | missing |  |
| Finding the subject · cancellable | `bg-separating` | 6 | missing | missing |  |
| Subject separation failed · edits kept | `bg-failed` | 6 | missing | missing |  |
| No clear subject | `bg-no-subject` | 6 | missing | missing |  |
| People found, but no usable face | `pt-no-usable-face` | 6 | missing | missing |  |
| Removing · cancellable | `ed-removing` | 6 | missing | missing |  |
| Remove failed · edits kept | `ed-remove-failed` | 6 | missing | missing |  |
| Leaving with unsaved changes | `leave-unsaved` | 6 | missing | missing |  |
| Photos permission denied · edits kept (iOS) | `save-permission-denied` | 6 | missing | missing |  |
| Storage full · edits kept | `storage-full` | 6 | missing | missing |  |
| Export failed · edits kept | `export-failed` | 6 | missing | missing |  |

## Combined edit, one session

| Screen / state | id | Slice | iOS | Android | Notes |
|---|---|---|---|---|---|
| 1. Develop preset | `demo-1` | 5 | missing | missing |  |
| 2. Background replaced | `demo-2` | 5 | missing | missing |  |
| 3. Focus and blur on the new background | `demo-3` | 5 | missing | missing |  |
| 4. Portrait adjustment | `demo-4` | 5 | missing | missing |  |
| 5. Effect | `demo-5` | 5 | missing | missing |  |
| 6. Signature | `demo-6` | 5 | missing | missing |  |
| 7. Polaroid border, signature on the margin | `demo-7` | 5 | missing | missing |  |
| 8. Saving the new JPEG | `demo-8` | 5 | missing | missing |  |
| 9. Saved · original unchanged | `demo-9` | 5 | missing | missing |  |

## Interactions and behaviours (not screens)

| Behaviour | Slice | iOS | Android | Notes |
|---|---|---|---|---|
| Launch → Welcome; Privacy Policy link on Welcome returns to Welcome | 1 | missing | missing | |
| More (⋮): Preferences, Legal, About; pages on phones, form sheets on tablets | 1 | missing | missing | |
| Appearance System/Light/Dark persists across launches | 1 | missing | missing | |
| Keep photo metadata (default on) and Include location (default off) are independent and persist | 1 | missing | missing | |
| Native picker, camera, permission flows; cancellation returns unchanged | 1 | missing | missing | |
| One session per photo; switching photos invalidates all work for the previous photo | 2 | missing | missing | |
| Undo/Redo restore the complete combined edit across every tool | 2 | missing | missing | |
| Ruler: one stop per preset, preview while dragging, one undo step on release, no interpolation, no prev/next arrows | 2 | missing | missing | |
| Category change alone never changes the applied Look; a new Look replaces only the Develop Look | 2 | missing | missing | |
| Stop zero reads Auto only when Auto correction is applied; otherwise Original | 2 | missing | missing | |
| Amount secondary; re-selecting the applied preset keeps its Amount | 2 | missing | missing | |
| Favourites: up to five shortcuts, manage/reorder in Preferences, replace when full | 2 | missing | missing | |
| Hold-to-compare shows the original; accessible toggle | 2 | missing | missing | |
| Preview and export evaluate the same committed recipe; latest-request-wins previews | 2 | missing | missing | |
| Auto is real image-adaptive correction, or the approved unavailable state | 2 | missing | missing | |
| Background: real subject/depth processing; Focus & Blur usable after replacement | 3 | missing | missing | |
| Portrait: hidden without a person; auto-select one usable face; choose among faces; per-face settings | 3 | missing | missing | |
| Edit: crop/aspect, rotate/flip, straighten, perspective, adjust, remove brush with real processing | 4 | missing | missing | |
| Effects: light leaks, grain, vignette combine; preset grain/vignette composed as approved, never silently doubled or dropped | 4 | missing | missing | |
| Watermark: signature draw/import/save/reuse, text in Allura/Cormorant Garamond/Inter/Caveat, logo; on photo or border | 5 | missing | missing | |
| Border: None/Solid/Photo Frame/Polaroid with larger bottom margin and margin signature | 5 | missing | missing | |
| Save copy: new JPEG, original unchanged, bounded memory, no duplicate on cancel; same metadata policy for Share | 5 | missing | missing | |
| Metadata: four switch combinations verified on saved files; colour profile kept; no stale dimensions/orientation/thumbnail | 5 | missing | missing | |
| Recovery: load failure, permissions, storage full, export failure, lost access, unavailable models, cancelled tools; edits preserved | 6 | missing | missing | |
| Accessibility: large text, VoiceOver/TalkBack, contrast, 44 pt targets | 6 | missing | missing | |
| Layouts: hinge/posture aware, safe areas, gesture areas, all reference sizes | 6 | missing | missing | |
| Icon and preset-pack packaging verified before every install | 6 | missing | missing | |
