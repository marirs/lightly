# Device acceptance pass: checkpoint 8998b1a, build 1.0.0 (261007053)

Packaged 2026-10-07 (`~/.codex/artifacts/lightly/v1/review-builds/{ios,android}/8998b1a/`). Installed and read back:
review emulator 5554 (261007053), review simulator D75D820D. iPhone 11 Pro Max: install of 8998b1a not confirmed (the
phone was locked); last confirmed build 261007051, which has no iOS change since (iOS code is unchanged after 5a4eaf4).
Review builds are optimised as Release (iOS: Release compiler settings with diagnostics kept; Android: the benchmark
build), so device times are the shipped app's.

The iPhone holds your unsaved edit from 5 Oct. Backup with checksums:
`~/.codex/artifacts/lightly/v1/iphone-session-backup-2026-10-07/` (history a98a7571…, original 0a9b1285…). On 7 Oct
the phone's history still matched it; the original could not be re-read (the connection dropped).

## iPhone 11 Pro Max: one session, about 30 minutes. Keep the phone unlocked and on the cable throughout.
**Before you start (me, from the Mac, nothing replaced):**
- A. Re-read the session files and compare with the backup.
- B. Launch with `--restore-stored-session`: the trace must show your edit restored from source 0a9b1285…, and only the
  history header's scene line may change. This proves the recovery route (backup files + forced restore).

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

**Then me (replaces the edit on the phone, restored afterwards by the route checked in B):**
- C. 48 MP fixture: Save copy (stage times, SaveTiming, peak footprint) and one Remove stroke (iOS copies the whole
  photo for each stroke: 192 MB at 48 MP; not yet measured on a phone).
- D. Copy the backup files back and relaunch with `--restore-stored-session`; confirm source 0a9b1285….
- E. Install the gates-open **Release** build (the actual shipping configuration with both models), over the review
  build, data kept.

**You, on the Release build (2 minutes):** a portrait → Background › Focus & Blur (blur appears behind the subject);
Edit › Remove, one stroke (the area is filled). The Simulator cannot check Focus & Blur (Vision does not run there).
**Me:** reinstall the review build.

## Android dev phone (Nothing A069 or motorola edge 60, USB debugging): about 20 minutes
Not possible until a phone is connected. Then: I install the benchmark APK; you run iPhone steps 2–7 (TalkBack instead
of VoiceOver), and once: edit, press Home, open other apps until Lightly is closed in the background (or I end it from
the Mac), then tap Lightly's icon: the edit should come back and Save copy should work. I run the 48 MP Save copy and a
48 MP Remove stroke and read whole-process peak memory. Emulator figures (no XNNPACK there, so not the phone's): Develop
Save copy 494–637 MB PSS, Background Save copy 511–522 MB, a Remove stroke 932–985 MB.

## Not covered by this pass (still open, not accepted)
Hair edges (A4) and no-subject detection (A5) stay open whatever this pass shows; the hair review page records your
visual judgement separately (`docs/v1/review/a4-blind/README.md`).
