# Device acceptance pass: checkpoint 482261d, build 1.0.0 (261007059)

Packaged 2026-10-07 (`~/.codex/artifacts/lightly/v1/review-builds/{ios,android}/482261d/`). Installed and read back:
iPhone 11 Pro Max 261007059, review simulator D75D820D; review emulator 5554. Review builds are optimised as Release
(iOS: Release compiler settings with diagnostics kept; Android: the benchmark build), so device times are the shipped
app's.

The iPhone holds your unsaved edit from 5 Oct (17 steps, source photo SHA-256 0a9b1285…). Backup with checksums:
`~/.codex/artifacts/lightly/v1/iphone-session-backup-2026-10-07/`. Checked on 7 Oct, before and after every install:
the original and analysis files match the backup and the recipe lines are unchanged. `--restore-stored-session` was run
once (16:33) and restored it from source 0a9b1285…; that rebound the history header's scene line, nothing else.

## Final assisted iPhone session (iPhone 11 Pro Max), about 20 minutes
**Installed now: Lightly 1.0.0 (261007080), Release configuration, both models included** (internal check build from
`archives/66f6e21-gates-open/`; the model gates are open only in this build, not in a submission build). Confirmed
2026-10-07: the build number from the archive, and a launch wrote no debug trace (a review build always does). Release
builds take no test commands; that is expected. Your stored edit is intact (all three files' SHA-256 unchanged after
installing and launching) and Lightly reopens it at launch.

**To keep your edit:** do not tap Close, Discard or Save copy on it (Save copy and Discard end the stored edit), and do
not open another photo until Part C. Undo puts back anything you try.

**Part A: Focus & Blur and Remove (on your edit), 3 minutes**
1. Open Lightly: your edit appears.
2. Tap **Background** in the bottom tools → **Focus & Blur** is selected. Expect "Finding the subject…" briefly,
   then the controls (if your photo has no clear subject: "No clear subject found." with a Blur slider).
3. Drag **Blur** to about 60 → the background softens within a second or two; "Estimating depth…" may show first.
4. Tap **Undo**.
5. Tap **Edit** → **Remove** → brush over a small object → "Removing…" then the area is filled.
6. Tap **Undo stroke** (or Undo).

**Part B: VoiceOver on your edit (spoken), 10 minutes.** Turn VoiceOver on (Settings › Accessibility › VoiceOver, or
triple-click the side button if you set that shortcut). Swipe right through each screen and note anything missed,
misread, or out of this order. Expected (from the app's accessibility tree, recorded in the simulator; only your
listening confirms it):
- Top bar: "Close, button" · "Undo, button" (dimmed when nothing to undo) · "Redo, button" · "Save copy, button" ·
  "More, button" · "Photo".
- Develop: "Automatic correction, On" · categories "Favourites … Black & White" (the current one "Selected") ·
  "Favourite, button" · preset name (e.g. "Hiking 5") · position (e.g. "37 / 518") · "Amount 100, button" ·
  "Presets, Hiking 5, 37 of 518, adjustable" (swipe up or down to change preset).
- Tools: "Tools" · "Develop, Edited, Selected" · "Background" · "Portrait" · "Edit" · "Effects" · "Watermark" ·
  "Border".
- Edit › Remove: "Crop · Rotate · Straighten · Perspective · Adjust · Remove, Selected" · "Brush over anything you
  want removed." · "Brush size" · while removing: "Removing…" and "Cancel".
- Background › Focus & Blur: "Focus & Blur · Change background" · the style tabs · "Blur" · "Focus depth" ·
  "Refine edges" · "Tap the photo to set focus."
Turn VoiceOver off.

**Part C: only when you are ready to let your edit go (it is backed up on the Mac)** — VoiceOver over Welcome,
Choose a photo and Save copy:
7. With VoiceOver on: Close → (Leave without saving?) → Welcome: "More" · "Lightly" · "See it as you remember it." ·
   "Choose a photo, button" · "Camera, button" · "Your photos stay on your device by default." · "Privacy Policy".
8. Choose a photo → open one → Save copy → "Saved as a new photo" · "Share" · "Keep editing" · "Choose another photo".

**Afterwards (me):** reinstall the review build (261007080 review, data kept) and read the session files again.

## Android dev phone (Nothing A069 or motorola edge 60, USB debugging): about 20 minutes
Not possible until a phone is connected. Then: I install the benchmark APK; you run iPhone steps 2–7 (TalkBack instead
of VoiceOver), and once: edit, press Home, open other apps until Lightly is closed in the background (or I end it from
the Mac), then tap Lightly's icon: the edit should come back and Save copy should work. I run the 48 MP Save copy and a
48 MP Remove stroke and read whole-process peak memory. Emulator figures (no XNNPACK there, so not the phone's;
07af12d, repeated twice): Develop Save copy 464–476 MB PSS, a Remove stroke 742–938 MB, idle after the cycles 102 MB.

## Not covered by this pass (still open, not accepted)
Hair edges (A4) and no-subject detection (A5) stay open whatever this pass shows; the hair review page records your
visual judgement separately (`docs/v1/review/a4-blind/README.md`).
