# Device acceptance pass: build 1.0.0 (261007047), checkpoint 84588d4

Installed 2026-10-07, data kept, build read back on each: iPhone 11 Pro Max, review simulator D75D820D and review emulator
5554. Both review builds are optimised as Release (iOS: Release compiler settings with the diagnostics kept; Android:
the benchmark build), so times on the devices are the shipped app's. The iPhone still holds an unsaved edit
session from 5 Oct; Lightly may offer it when it opens.

## iPhone 11 Pro Max: about 20 minutes, in this order
1. **Launch Lightly once and tell me.** I confirm `launch: Lightly 1.0.0 (261007042)` in the trace first.
2. **Background:** a portrait → Change background with a colour (look at the hair edge) → Focus & Blur → drag the preset
   ruler once with Background on.
3. **Live preset dragging:** drag slowly across about 10 stops, then fast, then release; Undo once returns one step.
4. **Auto:** off and on once.
5. **Save copy**, then Keep editing.
6. **VoiceOver (spoken):** turn it on; from Welcome, Choose a photo, open one, move to Save copy and save; turn it off.
   Tell me anything you could not reach or that was read wrongly.
7. **Tell me when done.** I pull the trace and evidence (timings, saved bytes), then, with your OK (it replaces any
   unsaved edit on the phone), I run one 48 MP Save copy myself from the Mac and read its stage times (SaveTiming) and
   memory. Simulator reference: 9.2 s at 48 MP, 2.5 s at 13.5 MP.

## Android dev phone (Nothing A069 or motorola edge 60, USB debugging): about 20 minutes
Not possible until a phone is connected. Then: I install the benchmark APK; you run steps 2–5, a spoken TalkBack pass
(step 6), and once: edit, press Home, open other apps until Lightly is closed in the background (or I end it from the
Mac), then tap Lightly's icon: the edit should come back and Save copy should work. I run the 48 MP Save copy and read
drag-frame timing, Save copy time and whole-process peak memory (emulator: 637 MB Develop, 954 MB with Background,
above the 600 MB target).

## Not covered by this pass (still open, not accepted)
Hair edges (A4) and no-subject detection (A5) stay open whatever this pass shows; the hair review page records your
visual judgement separately (`docs/v1/review/a4-blind/README.md`).
