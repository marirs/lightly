# Device acceptance pass: checkpoint 482261d, build 1.0.0 (261007059)

Packaged 2026-10-07 (`~/.codex/artifacts/lightly/v1/review-builds/{ios,android}/482261d/`). Installed and read back:
iPhone 11 Pro Max 261007059, review simulator D75D820D; review emulator 5554. Review builds are optimised as Release
(iOS: Release compiler settings with diagnostics kept; Android: the benchmark build), so device times are the shipped
app's.

The iPhone holds your unsaved edit from 5 Oct (17 steps, source photo SHA-256 0a9b1285…). Backup with checksums:
`~/.codex/artifacts/lightly/v1/iphone-session-backup-2026-10-07/`. Checked on 7 Oct, before and after every install:
the original and analysis files match the backup and the recipe lines are unchanged. `--restore-stored-session` was run
once (16:33) and restored it from source 0a9b1285…; that rebound the history header's scene line, nothing else.

## Release acceptance session (iPhone 11 Pro Max), about 15 minutes
**Installed and running: Lightly 1.0.0 (261007080), Release configuration, both models included** (internal check
build, `archives/66f6e21-gates-open/`; not a submission build). Verified from the binaries, 2026-10-07: the archive's
executable (SHA-256 0f3128f8…, Mach-O UUID 47E83B97; the review build of the same commit is 40A2822E) has build
261007080 and both model switches YES; it was installed from that path, and the running process executes from the
bundle that install created (…/Application/7C67940E…/Lightly.app/Lightly). Release builds take no test commands.

**Your edit is backed up and its restoration verified:** `~/.codex/artifacts/lightly/v1/iphone-session-backup-2026-10-07-b/`
(SHA256SUMS: history feb8fbd5…, original 0a9b1285…, analysis 5b3abb75…). Verified on the phone by copying the backup
into a separate store and reopening it: 17 steps, at step 16, source 0a9b1285, same-scene restore. It has been replaced
on the phone by a **disposable edit** (a portrait, one exposure step) that Lightly reopens at launch. After the
session I copy your backup back and confirm it reopens.

**Route (on the disposable edit; Save copy writes one new photo to your library):**
1. **Focus & Blur:** tap Background → Focus & Blur → drag Blur to about 60. Expect the background to soften within a
   few seconds ("Finding the subject…" / "Estimating depth…" briefly).
2. **Remove:** Edit → Remove → brush over a small object. Expect "Removing…", then the area filled.
3. **Undo:** tap Undo once. Expect the Remove fill to go.
4. **Save copy:** tap Save copy. Expect "Saved as a new photo"; allow Photos access if asked. Tap Keep editing.
5. **VoiceOver (spoken):** turn VoiceOver on; swipe through the top bar, Develop, the tools, Edit › Remove and
   Background; then Close → Leave without saving? → Welcome; turn VoiceOver off. Expected speech: list below.

| Step | Result (pass / fail, what you saw) |
|---|---|
| 1 Focus & Blur | |
| 2 Remove | |
| 3 Undo | |
| 4 Save copy | |
| 5 VoiceOver | |

**Expected VoiceOver speech** (from the app's accessibility tree, recorded in the simulator by `VoiceOverRouteUITests`;
only listening confirms it): top bar "Close" · "Undo" (dimmed when nothing to undo) · "Redo" · "Save copy" · "More" ·
"Photo"; Develop "Automatic correction, On" · categories "Favourites … Black & White" (current one "Selected") ·
"Favourite" · preset name · position "n / total" · "Amount 100" · "Presets, <name>, n of total" (adjustable: swipe up or
down); tools "Develop … Border" (current one "Selected", "Edited" when used); Edit › Remove "Crop · Rotate · Straighten
· Perspective · Adjust · Remove", "Brush over anything you want removed.", "Brush size", "Undo stroke"; Background
"Focus & Blur · Change background", "Blur", "Focus depth", "Refine edges", "Tap the photo to set focus."; Saved "Saved
as a new photo" · "Share" · "Keep editing" · "Choose another photo"; Welcome "More" · "Lightly" · "See it as you
remember it." · "Choose a photo" · "Camera" · "Your photos stay on your device by default." · "Privacy Policy".

## Android dev phone (Nothing A069 or motorola edge 60, USB debugging): about 20 minutes
Earlier builds were tested on the Android dev phones; the current implementation (memory, model release, demand-driven depth, Background states) has not been validated on Android hardware. Not possible until a phone is connected. Then: I install the benchmark APK; you run iPhone steps 2–7 (TalkBack instead
of VoiceOver), and once: edit, press Home, open other apps until Lightly is closed in the background (or I end it from
the Mac), then tap Lightly's icon: the edit should come back and Save copy should work. I run the 48 MP Save copy and a
48 MP Remove stroke and read whole-process peak memory. Emulator figures (no XNNPACK there, so not the phone's;
07af12d, repeated twice): Develop Save copy 464–476 MB PSS, a Remove stroke 742–938 MB, idle after the cycles 102 MB.

## Not covered by this pass (still open, not accepted)
Hair edges (A4) and no-subject detection (A5) stay open whatever this pass shows; the hair review page records your
visual judgement separately (`docs/v1/review/a4-blind/README.md`).
