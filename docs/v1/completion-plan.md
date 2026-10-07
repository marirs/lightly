# Lightly 1.0: completion plan (single plan, 2026-10-06)

Built from existing records only (`remaining-work.md`, `implementation-checklist.md`, `dependencies.md`, the
2026-10-06 measurements). No new audit. This plan replaces ad-hoc checkpoints: every update reports blockers closed,
blockers remaining, and whether the estimate changed and why. New findings join the same list.

**Finish line:** every agreed 1.0 feature works on iOS and Android, matches the approved UX plus the owner's
amendments, and works in the actual Release configuration. The owner tests the final builds; submission only after the
owner's approval. Eraser alone is 1.1. Store review time is not part of engineering completion.

**Time units:** elapsed working days of this session's inline work (one engineer, no agents). Confidence: H ≥ 80 %,
M ≈ 50–80 %, L < 50 %. Items marked **unknown solution** have a bounded diagnostic and no completion date until it
returns.

## A. Engineering blockers

### A1. Android rendering work package (correctness + responsiveness + memory, one package)
Requirements, all at once (no alternating fast-wrong / correct-slow builds):
- **Correct:** every preview frame, drag or settled, is the edit the controls show, in pipeline order (Look, then
  Background); a drag frame differs from the settled frame only by resolution (background mean ΔE ≤ 1, edge ≤ 2.5).
- **Responsive:** drag frames with Background active ≥ 4 per second on the Android dev phones (Nothing A069,
  motorola edge 60); first drag frame ≤ 300 ms. Emulator numbers are secondary.
- **Memory:** settled Background frame and Save copy on a 13.5 MP photo leave ≥ 40 MB of the 192 MB heap free after
  GC; 0 app-visible allocation failures across the stress (edit, sweeps, Save copy) in 3 runs.
- **Failure visible:** a preview that cannot render after its retry shows the approved notice (decision O1); never a
  stale frame presented as current.

Current: correct order (007edea) but 3.7–7.2 s per drag frame on the emulator; heap 186–191 MB of 192 during settled
frames; notice not shown.

Next steps, in order:
1. Profile the stages already timed (LightlyBgTime): `applyRegion` takes 0.7–6.5 s for 0.27–1.1 MP, far above its
   arithmetic; `renderWorking` 2–10 s at 640–1024 px. Find the per-pixel overheads (allocation, boxing, bilinear
   sampling, single thread). 0.5 d.
2. Make both stages allocation-free and row-parallel across cores (results must stay byte-identical: the existing
   `:core-background:test` goldens and the drag-order comparison). 1–2 d.
3. Precompute per Background setting what does not depend on the Look (layer weights, masks, positioned replacement)
   so a drag frame only grades and convolves. 0.5–1 d.
4. Working set: one owner per large buffer, reuse across frames, release the analysis-size replacement after the
   working copy is made, manifest text as UTF-8 byte offsets (−6 MB). Measure peak after GC. 1 d.
5. Show the failure notice once O1 is decided. 0.25 d.
6. Measure on a dev phone (dependency D-1). If the phone misses the frame-rate target after steps 1–4, the remaining
   option is a GPU (GL) path for the Background stage: 3–5 d, M.

Estimate: steps 1–5 3–5 d (M); plus 3–5 d (M) only if step 6 requires the GPU path.

### A2. Android depth variation between runs — CLOSED 2026-10-06
Result: preprocessing input (display proxy 853×1280 vs 1067×1600 from a resized emulator screen in my test setup);
inference deterministic for identical input (two fresh processes, identical statistics); one analysis per session,
shared by preview and Save copy. No code change. Original entry:
Outcome: the source is named (inference, preprocessing or state reuse) and the requirement is set: within one unchanged
editing session the same analysis is reused for every preview and Save copy (verify, fix if not); across fresh
inference runs, byte-identity is required only if the diagnostic shows the variation is ours (preprocessing/state), not
the inference runtime.
Next step: a debug check that hashes (a) the decoded proxy, (b) the model input tensor, (c) the raw output, for
two inferences in one process on the same input and for two fresh processes; plus a log of which analysis object each
preview and the export used. 0.5–1 d (H). Fix if preprocessing/state: 0.5 d (M).

### A3. Android Auto (agreed 1.0 feature; Release shows "unavailable")
Outcome: Auto works in the Android Release build, with the same behaviour class as iOS (global, guarded corrections,
baked into the stage-1 LUT, identical in preview and Save copy).
Next step: decision O2 (port the iOS guarded analytic correction to Kotlin; Android has no Core Image). Then
implement: tone curve, vibrance, cast balance and the iOS guards; evaluate on the same 12 photos and degradations.
2–4 d (M). Depends on O2.

### A4. Android Change background hair edges: teal cast and grey haze (**unknown solution**)
Outcome: no visible teal/grey fringe on the approved portraits, light and dark replacements, without the red fringe
returning.
Bounded diagnostic: 1 d. Compare the Android foreground-colour estimate with iOS's on the same recorded stages and mattes
(iOS shows only a faint dark-teal tint on a few wisps): identify the differing step. Completion date only after it.

### A5. Android object cut-out (U²-Netp): no-subject rule fails held-out photos (**unknown solution**)
Outcome: the agreed behaviour for a photo without a clear subject on held-out photos (currently fails 4/9 and 10/29).
Bounded diagnostic: 1 d on the held-out set: is the failure the threshold (tunable, validated on a separate set) or
the model's saliency itself (then decision O5).

### A6. Android Portrait ring beside the head (bar photo)
Outcome: rings sit on detected people only. Next step: log face box vs ring position for that photo; fix the mapping.
0.5–1 d (M).

### A7. Grain (M9) and vignette (G2) calibration, both platforms
Outcome: grain and vignette match the approved reference renders within the recorded tolerance. Next step: re-measure
against the reference set with the current renderers. 1–2 d (M).

### A8. iOS hair edges (red spill), Background stall, Save copy to Photos, crop on the phone
Outcome: verified on the iPhone 11 Pro Max with the trace and evidence files; any failure fixed.
Next step: the owner's launch (D-2) → confirm the build-labelled launch line → the shortest Background + Save copy run
with evidence. 0.5 d per round of owner testing; fixes 0–3 d (L: depends on what the phone shows). The DEBUG
save-to-Documents run that produced no file (273c5e6) is diagnosed from the same trace.

### A9. Release builds with the gated models, both platforms
Outcome: Release builds where every row of the Release table works (Focus & Blur with estimated depth, Remove, Android
Change background, Portrait, Auto). Engineering is prepared (bundling scripts, pinned hashes, gates). Next step after
D-3: flip gates, add notices/licences, build Release, verify each feature in Release. 1–2 d (H). Depends on D-3/D-4.

### A10. Hardware verification of Android (never run on hardware since 9b1fcd8)
Outcome: the full v1 tool set, models, tiled Save copy and restore run on both Android dev phones without crash/ANR,
with correct outputs. Next step: install the Debug build on the two dev phones (D-1), run the focused flows. 1 d (M) +
fixes (L).

### A11. Unverified on both platforms (forced conditions and accessibility)
Storage full / export failed, lost photo access, model unavailable mid-session, large text, screen readers, 44 pt
targets, saved-file metadata on Android, 48 MP memory/time, tablet/Fold cells. Outcome: each run once in the final
acceptance pass; failures fixed. Next step: one checklist pass on simulator/emulator for the forced conditions (1 d, M);
device items join the owner's acceptance pass.

### A12. Release candidates and acceptance
Matching iOS and Android release candidates (same version/build), focused evidence for each closed blocker, the Release
feature table re-verified, one consolidated acceptance pass by the owner. 1–2 d (H) after everything above.

## B. Owner decisions (consolidated once; each with a recommendation)
Unresolved decisions do not permit misleading behaviour, and engineering not depending on them continues.

| # | Decision | Recommendation |
|---|---|---|
| O1 | Preview that cannot render: notice copy and placement | Approve "Couldn't update the preview." with one action "Try again", over the photo, until a frame renders. |
| O2 | Android Auto without Core Image | Approve porting the iOS guarded analytic correction (tone curve, vibrance, cast balance, same guards) to Kotlin; no model. |
| O3 | Depth-failure message | Choose the candidate "Couldn't estimate depth. Try again to use Focus & Blur." (states the cause and the action). |
| O4 | Preset names (`release/preset-name-proposal.md`) | Approve as proposed (variant numbers bound to ids; category line in Favourites). |
| O5 | Android object cut-out if A5 shows the model cannot decide "no subject" reliably | Keep person cut-out; for other subjects show the approved "no clear subject" state rather than a wrong cut-out. |
| O6 | Android vision models (D3): MediaPipe (faces, landmarks, pose, selfie/portrait segmenter) vs MODNet/U²-Netp | Split the gate: clear the MediaPipe models (published model cards, Apache-2.0) on their own; MODNet/U²-Netp follow counsel. |
| O7 | Legal texts (`release/legal-proposals.md`): Terms clause, Licences row (A) or Terms notices (B), operator, minimum age, pricing, bundled background photos | Option A (Licences row); decide operator, minimum age and pricing so the store listing can be prepared. |
| O8 | W1 watermark/blur sizing, S1 blur strength, S3 default focus, E1 straighten zoom, E2/Q1 perspective, P2 multi-face, F1 Film substitute, Selective Colour overlay, ruler fine-mode timing, About version scheme | Keep the current implemented behaviour where it matches the prototype; I list per item in one table for a single sitting. |
| O9 | iOS M2 iPad status-bar offset, M4 SF metrics, P1 ring proportion, More pages in sheet; Android splash +24 dp, Fold Welcome centred, LensModel/GPS (ACCESS_MEDIA_LOCATION) | Accept M2/M4 as platform rendering; fix P1, splash and Fold to the prototype; do not request media location (privacy). |
| O10 | Restore after force-quit (W9) | Keep the platform behaviour (discard on force-quit; restore after system termination). |

## C. Dependencies on the owner
- **D-1:** connect one Android dev phone (Nothing A069 or motorola edge 60) with USB debugging — needed for A1 step 6
  and A10. Without it, Android responsiveness and hardware behaviour remain unverified, and Android cannot be accepted.
- **D-2:** launch Lightly once on the iPhone 11 Pro Max, then tell me (A8); later, the acceptance pass.
- **D-3:** counsel's answer on the three legal questions for Depth Anything V2 Small and LaMa (and MODNet/U²-Netp);
  nothing ships with a gated model before it. **No engineering estimate covers counsel's time.**
- **D-4:** O1–O10 above.

## D. Remaining time (updated 2026-10-07; replaces the original total; not a release date)
"13–22 working days" was the **original total** written on 2026-10-06, not time still required. Done since: A1 steps 1–4
(rendering correctness, speed, memory, benchmark build, on the emulator), A2, A6, A3's implementation, the A4 and A5
diagnostics, M4, the Favourites snapshot. **Physical-phone performance is still pending (A1 step 6):** the emulator
results close implementation steps, not hardware acceptance.

### Engineering time still required (my work, sequential)
| Work | Days |
|---|---|
| A11 forced conditions and accessibility, simulator/emulator pass | 1 |
| M2 iPad top bar to the approved 24 pt | 0.25 |
| A4 hair: port the chromaticity candidate to Kotlin with emulator saved copies, only if it passes the blind review | 0 or 1 |
| A5 no subject: only if the detector-as-support trade-off is approved: validation 1, Kotlin/LiteRT 0.5, emulator 0.25 | 0 or 1.75 |
| A7 grain/vignette fit, once the exports exist | 1–2 |
| A1 step 5 notice, once D1 is decided | 0.25 |
| A3 Auto adjustments after the owner's visual review | 0–1 |
| Hardware rounds once phones are available (A1 step 6, A8, A10), engineering part | 2–5 |
| Release builds and acceptance support (A9, A12) | 2–4 |
| **Total engineering** | **7.5–16.25** |

Not included, listed rather than assumed: the GPU path (3–5 d) only if a phone misses the drag-frame target; any further
approach if A4's candidate fails the review or A5's trade-off is declined (no replacement model is queued; each would be
a separate decision with its own licence and counsel question).

### External waiting (not engineering time; durations unknown to me)
- D-1 an Android dev phone; D-2 the iPhone launch and acceptance passes.
- Lightroom exports (A7); decisions D1–D3 and the individual differences (owner-decisions.md); the A4 blind review;
  whether A5's detector is worth its download for recall alone.
- D-3 counsel (training data of the gated models). No estimate covers counsel.

The release date is the later of the engineering above and these external items; it is not predictable from this table.

## E. Execution order
A2 diagnostic (small, informs A1) → A1 steps 1–4 → A6 → A4/A5 diagnostics → A7 → A11 (simulator) → A3 (after O2) →
hardware rounds as D-1/D-2 arrive → A9/A12 after D-3.

## Status log
- 2026-10-06: plan created. Closed: none. Remaining: A1–A12. Estimate: 13–22 d (+3–5 d conditional) — first estimate.
- 2026-10-06: A2 closed (existing logs: identical depth for identical proxies across fresh processes; the variation
  was a resized test screen). Remaining: A1, A3–A12. Estimate unchanged at 13–22 d: A2's 0.5–1 d was inside the range.
- 2026-10-06 (A1 in progress): exact speedups (sRGB tables, one bilinear position per pixel, reflect tables, parallel
  proxy resize; every output byte-identical: goldens, exhaustive encode check, 13.5 MP Save copy sha d0f8bcec…
  unchanged); drag frames composite at the half-size proxy with the blurred scene at DRAG_CAP 320 (to the settled
  frame: background mean ΔE 0.26, soft edge 2.24, within the A1 bounds; subject = the half-size proxy every drag
  frame uses); replacement graded with the drag plan; the settled develop stops between row chunks when preempted;
  working analysis and positioned replacement cached per size. Emulator: settled Background frame 13–18 s → 4–6 s;
  drag frame best 0.73 s, but emulator timings vary 5–10× for identical work under host load, so they cannot verify
  the ≥ 4 frames/s target; JVM (10 cores): drag-frame Background stage 100 ms, settled 220 ms. Heap during the stress:
  77–112 MB used after GC (was 186–191). Closed: none yet (A1 needs the phone measurement, D-1, and O1).
  Remaining: A1, A3–A12. Estimate unchanged at 13–22 d: A1 steps 1–4 took less than planned, but the frame-rate
  target cannot be confirmed without D-1, which keeps the conditional GPU path (+3–5 d) open.
- 2026-10-06 (later): **A6 closed** (87c8199: dim rings from the person matte; bar photo shows two rings on the middle
  and right-hand heads, as the prototype). **A4 fixed except a residual** (663d0f6: closed-form matting of MODNet's
  matte; emulator Save copies: haze about halved, red gone, light-background teal 2,355 → 322 px; a reduced dark-teal
  cast remains on pm02's left curls over the dark replacement; device time pending). **A5 diagnosed** (f491b45: depth
  step along the mask boundary leaves 2 of 37 scenes misread vs 14 by area; not validated on new photos; needs the
  depth model; decision O5). A3 established: Android needs its own Auto analysis (no Core Image), see O2.
  Remaining: A1 (phone timing, O1 notice), A3, A4 residual, A5, A7–A12. Estimate unchanged at 13–22 d: A4 and A6 took
  about their planned time; A4's residual and A5's validation are not yet sized.
- 2026-10-06 (night): **A3 implemented** (23f97e3, Android Auto; eval 20/3/1, originals up to ΔE 7.9; UI and device
  runs pending). **A5 validated on a fresh set: not solved** (9/12 subjects, 3/82 false; labels before the run).
  **M4 fixed** (1ef2c0d, iOS preset name line breaks). **A7 blocked** on Lightroom exports (owner). A11: forced storage
  full not reachable on the emulator. Matting refinement confirmed once per photo (separation only, cached by pixels).
  Decisions sheet: `owner-decisions.md`. Remaining: A1 (phone, D1), A4 residual, A5, A7, A8–A12, M2 (match). Estimate
  unchanged at 13–22 d; A5 now needs a new approach (not sized) and A7 waits for the exports.
- 2026-10-07: **9bc1ea9 (261007003) installed** on the review devices (data kept, build read back). Same code used on
  the spare devices: Android 13.5 MP Background stress 0 app-visible failures, Auto at open 1.8 s, matte once 3.8 s,
  drag frames 1.2–2.1 s (not live-preview quality; phone pending); iOS flow tests (Auto, ruler drag, Background pass,
  Save copy) pass. Settled-preview memory fixed (peak in use before GC 155 MB of 192; was failing). A1 open (drag-frame
  speed, phone, D1). A3 open (originals moved: visual review with the owner). A5 open (failed validation). A7 waits for
  the Lightroom exports (brief: release/lightroom-export-brief.md). Estimate unchanged at 13–22 d.
- 2026-10-07 (A1): **Measurement corrected:** every earlier Android drag timing came from the debuggable APK, which ART
  runs unoptimised; a `benchmark` build type (release-like, profileable, scripted scenarios) is now used. **Memory:**
  Save copy of the 13.5 MP Background edit keeps ≥ 53 MB of the 192 MB heap free (live set 123–139 MB in heap dumps
  during the tiles; caches the export never reads freed, Look manifest as UTF-8, 512 px tiles); 0 app-visible
  allocation failures (ART still logs a footprint-growth line that the allocation then passes). **Speed:** the drag
  frame's Background stage is 2.2× faster with bit-identical output (A/B 132–171 → 63–75 ms, JVM, 4 threads; profile
  with simpleperf). Spare emulator, benchmark build: drag frames median 139–149 ms, 15–21 of 18–22 within 250 ms, first
  drag frames 140–251 ms; host load moves these figures by up to 2×. Remaining for A1: the phone measurement (D-1)
  and the D1 notice. Favourites snapshot baseline updated (every difference traced to the authorised names and note
  component). Estimate unchanged at 13–22 d: A1 steps 1–4 are done; the conditional GPU path is less likely but
  stays open until a phone is measured.
