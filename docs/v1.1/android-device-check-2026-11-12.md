# Android 1.1 device check (2026-11-11/12)

Device: Nothing A069 (Android 16, 1224×2720, 480 dpi), over Wi-Fi adb. Release builds (R8, depth and remove
models signed off as on iOS), signed with the debug key for installation only:

- 1.1.0 (261108001), from 2275972: Ink checks; found the Sunglasses Save copy failure.
- 1.1.0 (261112001), from 9a07bd6 on `release/1.1` (the fix): Sunglasses and Polaroid checks.

Driven by adb taps and screenshots; saved copies pulled from `Pictures/Lightly` and compared with the preview.
Fixture photos (`experiments/test-photos/glasses_black_front_01.jpg`, `group_three_01.jpg`) were pushed to
`Pictures/LightlyTest` on the phone.

| Check | Result |
|---|---|
| Launch, Welcome, picker, editor; More shows "Version 1.1.0 (261108001)" | verified |
| Ink: gallery, Size, Rotation, Paper colour strip, More colours sheet (preview, From your photo, Paper & ink, Earth, Custom, Recent), drag on the photo | verified, dark and light (261108001) |
| Ink: Undo steps back one change at a time; Redo restores all; Reset all (confirmation) and its Undo; section Reset menu | verified (261108001) |
| Ink: saved copy (3000×4500) matches the preview | verified (261108001) |
| Ink: pinch / two-finger turn on the photo | untested (adb has no multi-touch) |
| Sunglasses: pairs, lenses (Dark, Brown, Gradient), Darkness, Size, Undo/Redo | verified, light and dark |
| Sunglasses: Save copy on a close-up 12 MP portrait | failed on 261108001 (OutOfMemoryError, every attempt); verified on 261112001 (Pilot, Aviator; saved = preview) |
| Sunglasses: face with its own glasses ("Glasses found." note; own frames painted out; saved = preview) | verified, dark (261112001) |
| Polaroid: print clears Auto / Reset all (landscape group photo and portrait photo: print ends 37 px = 12 dp above the buttons; the portrait print shrinks) | verified, dark and light (261112001) |
| Polaroid: saved copy (3330×5385) matches the preview | verified |
| Photo without a person hides Portrait in the dock | verified |
| Leave without saving? on closing with edits | verified |

Open (performance, not correctness):

- Sunglasses preview: every change takes 1.9–2.2 s to appear (`preview committed`), so Darkness/Size dragging is not
  live. Ink commits in 2–17 ms.
- Sunglasses Save copy: 14 s at 12 MP (3 s at 3.2 MP); Ink and Polaroid save in about 1–2 s. iOS not timed.

Not covered: moto edge 60 (not connected), foldable/Duo, iOS (released separately).
