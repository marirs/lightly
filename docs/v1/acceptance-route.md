# Device acceptance pass: checkpoint 482261d, build 1.0.0 (261007059)

Packaged 2026-10-07 (`~/.codex/artifacts/lightly/v1/review-builds/{ios,android}/482261d/`). Installed and read back:
iPhone 11 Pro Max 261007059, review simulator D75D820D; review emulator 5554. Review builds are optimised as Release
(iOS: Release compiler settings with diagnostics kept; Android: the benchmark build), so device times are the shipped
app's.

The iPhone holds your unsaved edit from 5 Oct (17 steps, source photo SHA-256 0a9b1285…). Backup with checksums:
`~/.codex/artifacts/lightly/v1/iphone-session-backup-2026-10-07/`. Checked on 7 Oct, before and after every install:
the original and analysis files match the backup and the recipe lines are unchanged. `--restore-stored-session` was run
once (16:33) and restored it from source 0a9b1285…; that rebound the history header's scene line, nothing else.

## iPhone 11 Pro Max: one session, about 30 minutes. Keep the phone unlocked and on the cable throughout.
**Before you start (me):** re-read the session files against the backup (nothing written).

**Measured 7 Oct, 261007059, 48 MP fixture, `--keep-stored-session` (stored edit unchanged, SHA-256 checked):**
Develop Save copy 1.6 s (bytes 0.37 s, render 0.97 s, encode 0.24 s), peak footprint 840 MB; one Remove stroke done
8 s after launch, peak footprint 533 MB. **Open device failure:** Background on the same photo (no camera depth):
the Depth Anything model load did not finish in two runs (5 and 10 minutes; no "ready" or "unavailable" line; no
crash or jetsam report). The phone may have auto-locked during the wait, which suspends the app, so this is not yet
a diagnosis. First step of the session: `bg-focus` with the phone unlocked and watched. Evidence: `/Users/sg/.codex/artifacts/lightly/v1/iphone-memory/20261007-165953`.

**You (in this order):**
1. Your restored edit is on screen: check it is the one you left (then keep editing it or not, as you like).
2. **Background:** a portrait → Change background with a colour (look at the hair edge) → Focus & Blur → drag the preset
   ruler once with Background on.
3. **Live preset dragging:** slowly across about 10 stops, then fast, then release; Undo once returns one step.
4. **Auto:** off and on once.
5. **Remove:** one stroke on a photo of yours.
6. **Save copy**, then Keep editing.
7. **VoiceOver (spoken):** turn it on; from Welcome, Choose a photo, open one, move to Save copy and save; turn it off.
   Tell me anything you could not reach or that was read wrongly.
8. Tell me when done.

**Then me (your edit is not replaced):**
- C. `scripts/iphone_memory_check.sh`: 48 MP Develop Save copy, one Remove stroke (now drawn from bands of the photo,
  7cfa473) and Background Save copy, each in a fresh process with `--keep-stored-session`, so the stored edit is
  neither written nor cleared; its SHA-256 are compared before and after. Peak footprint and stage times from the
  trace.
- D. (Only if C reports a changed session.) Restore from the backup. Writing files back with devicectl failed twice
  on 7 Oct (connection dropped), so this route is not verified and C avoids needing it.
- E. Install the gates-open **Release** build (the actual shipping configuration with both models), over the review
  build, data kept.

**You, on the Release build (2 minutes):** a portrait → Background › Focus & Blur (blur appears behind the subject);
Edit › Remove, one stroke (the area is filled). The Simulator cannot check Focus & Blur (Vision does not run there).
**Me:** reinstall the review build.

## Android dev phone (Nothing A069 or motorola edge 60, USB debugging): about 20 minutes
Not possible until a phone is connected. Then: I install the benchmark APK; you run iPhone steps 2–7 (TalkBack instead
of VoiceOver), and once: edit, press Home, open other apps until Lightly is closed in the background (or I end it from
the Mac), then tap Lightly's icon: the edit should come back and Save copy should work. I run the 48 MP Save copy and a
48 MP Remove stroke and read whole-process peak memory. Emulator figures (no XNNPACK there, so not the phone's;
07af12d, repeated twice): Develop Save copy 464–476 MB PSS, a Remove stroke 742–938 MB, idle after the cycles 102 MB.

## Not covered by this pass (still open, not accepted)
Hair edges (A4) and no-subject detection (A5) stay open whatever this pass shows; the hair review page records your
visual judgement separately (`docs/v1/review/a4-blind/README.md`).
