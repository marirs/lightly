# Android 1.1 device check (2026-11-11/12)

## Release state

1.1 is live on both stores: Android 1.1.0 (261108001) in Production, full rollout since 2026-11-09 (Play Console,
owner 2026-11-12); iOS 1.1.0 (261102001). `master` carries the 1.2 work (Eraser). The fixes below are on
`release/1.1` (from 2275972, the commit of the live Android build) for a 1.1.x store update; its
`version.properties` still says 1.1.0 and needs a marketing-version bump before upload.

**The live Android build has the Sunglasses Save copy failure below** (every save of a pair on a close-up 12 MP
portrait on a 256 MB-heap phone).

## Method

Device: Nothing A069 (Android 16, 1224×2720, 480 dpi), over Wi-Fi adb. Release builds (R8, depth and remove models
signed off as on iOS), signed with the debug key for installation only:

| Build | From | Used for |
|---|---|---|
| 1.1.0 (261108001) | 2275972 (= the live build's commit) | Ink checks; found the Sunglasses save failure |
| 1.1.0 (261112001) | 9a07bd6 | Sunglasses (save fix), own glasses, Polaroid |
| 1.1.0-dev (261112002) | d019615's code, uncommitted | Speed, Reset dialog and link, haptics |
| 1.1.0 (261112006) | d019615 (`release/1.1`) | Installed release candidate; same code as the row above, not re-checked |

Driven by adb taps and screenshots; saved copies pulled from `Pictures/Lightly` and compared with the preview;
preview times from the app log (`preview committed`); haptics from `dumpsys vibrator_manager`. Fixture photos
(`experiments/test-photos/glasses_black_front_01.jpg`, `group_three_01.jpg`) were pushed to `Pictures/LightlyTest`.

## Results

| Check | Result |
|---|---|
| Launch, Welcome, picker, editor; More shows the version | verified |
| Ink: gallery, Size, Rotation, Paper colour strip, More colours sheet, drag on the photo | verified, dark and light (261108001) |
| Ink: Undo one step at a time, Redo, Reset all (confirmation) and its Undo, section Reset menu | verified (261108001) |
| Ink: saved copy (3000×4500) matches the preview | verified (261108001) |
| Ink: pinch / two-finger turn on the photo | untested (adb has no multi-touch) |
| Sunglasses: pairs, lenses (Dark, Brown, Gradient), Darkness, Size, Undo/Redo | verified, light and dark |
| Sunglasses: Save copy on a close-up 12 MP portrait | **failed on 261108001** (OutOfMemoryError, every attempt, "Couldn’t save the copy"); verified from 261112001 (Pilot, Aviator, Club; saved = preview) |
| Sunglasses: face with its own glasses ("Glasses found." note; own frames painted out; saved = preview) | verified, dark |
| Polaroid: print clears Auto / Reset all (landscape and portrait photos: 37 px = 12 dp gap; portrait print shrinks) | verified, dark and light |
| Polaroid: saved copy (3330×5385) matches the preview | verified |
| Photo without a person hides Portrait in the dock; "Leave without saving?" on closing with edits | verified |
| Section Reset choice dims the whole screen; Undo behind it does nothing; Reset sunglasses works | failed on 261108001 (dialog drawn inside the panel, Undo live behind it); verified after ee1bd36 |
| Section "Reset" link appears with the first edit | failed on 261108001 (appeared only after an unrelated recomposition); verified after f19440e |
| Haptics: Confirm on "Saved as a new photo"; tick when a bipolar slider crosses 0 | verified (vibrator log: CONFIRM after the save, one TICK per crossing, none leaving 0) |
| Haptics: Reject on save failure / storage full | untested on device (no failure to trigger); unit-tested mapping on iOS only |

## Sunglasses speed (close-up portrait, preview 1600 px)

| | 261108001 | after 45141b8 |
|---|---|---|
| Choosing a pair | ~2.0 s | 0.67 s |
| Darkness / lens drag, per frame | ~2.0 s | ~0.18 s |
| Size drag, per frame | ~2.0 s | 0.42–0.56 s |
| Save copy, 12 MP | 14 s (after the memory fix) | 4 s |

Size dragging is still not live; a faster rasteriser would be needed.

## Not covered

moto edge 60 (not connected), foldable/Duo, iOS (iOS haptics db84ce6 on `master` are unit-tested only; simulators have
no haptics).
