# Acceptance route: build 1.0.0 (261007036), checkpoint 66b0f5e

Installed 2026-10-07 on the review devices (data kept, build read back): iPhone 11 Pro Max 261007036, review simulator
D75D820D 261007036, review emulator 5554 261007036 (A11 fixes on both platforms; replaces 261007013 of 6f4462c;
Android Background faster and lighter). The review emulator runs the benchmark build since 09:24 (Release rendering code and
optimisation settings, models packaged; android-benchmark-build.md), updated in place with data kept.

## iPhone 11 Pro Max (in this order)
1. **Launch Lightly once, then tell me.** I pull the trace (`scripts/iphone_evidence.sh 261007036`) and confirm the line
   `launch: Lightly 1.0.0 (261007036)` before anything else.
2. **Auto:** open a portrait (Choose photo). Auto applies by itself; tap Auto off and on once.
3. **Live preset dragging:** drag the ruler slowly across ~10 stops, then fast, then release. The photo should follow
   while dragging; release is one step (Undo once returns to the previous preset).
4. **Background:** open Background on the same portrait; after "Finding the subject…", pick Change background with a
   colour, then Focus & Blur, and drag the preset ruler once more with Background on.
5. **Save copy:** Save copy, then Keep editing. Tell me when done; I pull the trace and the evidence files (mattes and
   the saved bytes) and check them before asking for anything else.

## Android (separate; needs a dev phone over USB)
Not possible yet: no Android dev phone is connected. When one is (Nothing A069 or motorola edge 60), the same steps 2–5
run there, and I record the Background drag-frame timing, which on the CPU emulator is 1.2–2.1 s per frame (not yet
live-preview quality).
