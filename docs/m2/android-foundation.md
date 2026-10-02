# M2 — Android foundation

Branch: `m2/android-foundation` (from `m1/spec-ux-lut-feasibility` @ `c6b1f98`, merged again with m1 @ `d293406`)
Project: `android/` (new Gradle multi-module project; `ios/Lightly/`, `experiments/` and other `docs/` are untouched)

This milestone builds the Android parts of spec §8 that can be verified **without a phone**:
- the edit model;
- the latest-wins preview scheduler;
- the CPU reference and a GLES port of the LUT renderer;
- model preprocessing, fusion and versioned basis resolution;
- the image decoder;
- the tiled export path and MediaStore writer;
- a Compose editor wired end to end (picker → Auto → Looks → preview → Save copy).

Everything in sections 1–7 was verified with JVM unit tests and Robolectric only. The follow-up in §8 (Codex findings 1 and 4, Looks, user-flow demo) also ran the debug APK on an **Android emulator** (Pixel 9 Pro AVD, API 36, arm64). **No physical device was used.** Every hardware-dependent claim below is marked **PENDING**, and emulator results are labelled emulator-only.

## 1. Build and test

Toolchain: Gradle 9.7.1, AGP 9.4.1, Kotlin 2.4.20 (one Kotlin Gradle plugin for the JVM and Android modules), bytecode target 17. `compileSdk 36`, `minSdk 29` (U6), `targetSdk 36`.

Tests must run on **JDK ≤ 25**. Robolectric cannot instrument JDK 26 class files, and the build stops with instructions if it is started on a newer JDK. Use Android Studio's bundled JDK:

```bash
cd android
echo "sdk.dir=$HOME/Library/Android/sdk" > local.properties   # once
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
./gradlew test                     # all JVM + Robolectric unit tests
./gradlew :app:assembleDebug       # builds the shell APK (not installed anywhere in M2)
```

**Golden fixtures and research basis LUTs are read in place and never copied into `android/`.** By default the build looks in `experiments/lut3d/golden` and `experiments/lut3d/models` next to `android/`. Both are git-ignored (about 600 MB, research-only weights), so they are missing in fresh clones and git worktrees. In that case point the build at an existing copy:

```bash
./gradlew test -PlightlyGoldenDir=/abs/path/experiments/lut3d/golden \
               -PlightlyModelsDir=/abs/path/experiments/lut3d/models
# or LIGHTLY_GOLDEN_DIR / LIGHTLY_MODELS_DIR
```

If either folder is missing, the golden tests **fail** with these instructions. They do not skip.

## 2. What exists

| Module | Kind | Contents |
|---|---|---|
| `core-session` | Kotlin/JVM | `EditState` v1 (§3) with init-time validation; `SourceFingerprint`; `UndoStack` (immutable, cursor, cap 50 dropping the oldest, redo cleared on commit); `EditSession` (one step per committed change, no-op changes are not steps, Look *replaces*, Reset is undoable, monotonic commit revision); `SessionJson`; `RecoverySnapshot` + `RecoverySnapshotStore` (atomic write; corrupt or fingerprint-mismatched snapshots are discarded). |
| `core-render` | Kotlin/JVM | `RenderScheduler` (§5.2: one in-flight slot plus one conflated pending slot, request IDs issued under a lock, publish only if latest, not cancelled and session open, `cancel(through)` leaves newer requests alone). CPU LUT maths: `Lut3D`, strength blend, `CpuLutRenderer`. **`LutPassPlan` + `LutPassRenderer`**: Auto (O1) and Look (O2) as two passes (§4.1 revised); `CpuLutPassRenderer` is the oracle. GPU-neutral GLES support: `LutShaderSource` (GLSL generation), `LutTexturePacking` (RGBA32F 3D-texture layout), `TilePlan`/`TileCopy` (≤ 4096² tiles). `LutComposition.bake` is kept only for the exhaustive pair check; it is not a render path. |
| `core-render-gl` | Android library | `GlLutPassRenderer`: the EGL/GLES 3.0 port of LUTBench `GlLut.kt` (`rgba32f_manual`). Pbuffer context owned by one thread; one program per pass count; LUT textures cached by identity; tiles uploaded from RGBA8 buffers and read back per tile. **Compiles; has never run on a GPU.** |
| `core-model` | Kotlin/JVM | `CanonicalAnalysisInput` (§4.6 pinned antialiased resize); `BasisLuts.fuse`; `endpoint-v1` guardrail. **`BasisRegistry`**: basis files keyed by (modelId, modelVersion), each sha256-verified against its manifest before it is parsed. **`RegistryAutoLutResolver`**: AutoResult → `Ready(lut)` or `AutoUnavailable(modelId, modelVersion, reason)`, with no fallback to another version. `AutoEnhancer.develop` → `DevelopOutcome` (Developed or Unavailable). `AutoModel` is an interface with a fake only. |
| `core-decode` | Android library | `DecodeTargets`: the analysis decode has a long edge of exactly 1024 (or the Original if smaller) and does not depend on the screen; the display proxy is capped at min(screen, 2732); headers above 100 MP are rejected. `ProxyDecoder`: ImageDecoder with target size, software allocation and `setTargetColorSpace(sRGB)`, plus a Canvas redraw for anything still not 8-bit sRGB. EXIF orientation comes from ImageDecoder. Gain maps are ignored (U5). |
| `core-export` | Android library | `SaveCopyExporter` (insert `IS_PENDING=1` → encode **once** → `IS_PENDING=0`; the pending row is deleted on failure; the source is never opened). `ContentResolverGateway`. **`ExportCoordinator`**: export path separate from the preview scheduler, single flight, slot held until the write completes, state guarded by export ID. **`TiledExportRenderer`**: ≤ 4096² tiles, LUT passes per tile, written straight into the encode target (`ExportFrame`: `BitmapExportFrame` + `BitmapFrameJpegEncoder` on Android). **`ExportBufferLedger`**: documented buffer budget (§3.1). |
| `app` | Android app | `EditorViewModel` wired end to end through an injected `EditorEnvironment` (§3.2). `EditorScreen`: Photo Picker, preview image, hold-to-compare, category chips, stepped slider, strength, undo/redo/reset, Save copy. `AndroidEditorEnvironment` is the production wiring (`ContentResolverPhotoLoader`, `ContentResolverPhotoAccessGrants`). `BundledLookBook`: provisional procedural Looks in **debug builds only**, none in release (§8.3). The app ships **no inference engine and no basis**: develop reports `NoModelInThisBuild`, so the photo opens straight into editing with Auto off and the notice "Auto is unavailable: this build has no Auto model. Looks apply to your original photo." (same wording as iOS). DevelopFailed with [Retry] is kept for real model failures. Tests inject a fake model and a test basis. |

### Decisions taken while implementing

- **Two kinds of revision.** `EditState.revision` counts commits and stays monotonic after undo-then-commit. The render scheduler issues its own request IDs. This is now spec §5.2 (`d293406`).
- **Saved Auto results resolve only to their own model version** (Codex M2 finding 4). A missing or tampered basis gives `AutoUnavailable`. The stored `AutoResult` is never rewritten, so the edit renders correctly again once that version is installed.
- **Two LUT passes in one fragment shader.** The value between O1 and O2 stays float. Two draws through an RGBA8 framebuffer would clip and quantise it, which the CPU oracle does not do. The shader does manual trilinear with `texelFetch` on RGBA32F and uses no hardware filtering.
- **Export is not a scheduler request kind.** `ExportCoordinator` has its own job and its own single-flight slot. It is not a child of the preview scheduler or the session, so preview submits, `cancel(through)` and `close()` cannot drop it. Cancel works until encoding starts. Encode and write are NonCancellable. The MediaStore row is created only after rendering, so a cancelled export leaves nothing behind.
- **Export slot (Codex M2 review).** The export slot is released only when the export's Job has *completed*, not when it is cancelled. `Job.isActive` turns false at cancel() while the NonCancellable write is still running, and the earlier code let a second save start then. An export cancelled before it ever ran is finalised as Cancelled by the completion handler; it previously stayed at DECODING. Every state write is guarded by the export ID.
- **Export memory.** Tiles are written straight into the buffer the encoder reads, and the decoded source is released before encoding. The earlier code held three full frames during encode (source, rendered copy, Bitmap copy); it now holds one.
- **Preview renderer in the shell.** The app previews with the CPU reference renderer on the display proxy. `GlLutPassRenderer` is not wired until it has been validated on a GPU. Swapping it in changes only `EditorEnvironment.previewRenderer` and the render thread.
- **Analysis decode size.** Spec §4.6 says the analysis source needs a long edge ≥ 1024; the M2 brief said ≤ 1024. Decoding to exactly 1024 (or the Original if smaller) satisfies both. Note that spec §5.3 still says "Analysis and model input come from the Proxy", which contradicts §4.6 ("the display Proxy is never the model input"). Android follows §4.6. The §5.3 sentence should be corrected.

## 3. Test results (`./gradlew test`, JVM + Robolectric, JDK 25)

**162 tests, 0 failures, 0 skipped** (138 before §8). Run with the golden set from the main checkout.

| Module | Task | Tests | Notes |
|---|---|---|---|
| core-session | `test` | 24 | EditSession 8, UndoStack 4, serialization 6 (golden JSON), recovery + fingerprint 6 |
| core-render | `test` | 43 | RenderScheduler 13, LUT unit 10, golden 4, shader source 6, shader-math twin 2, tiling/packing/pass plan 8 |
| core-model | `test` | 17 | preprocessing golden 3, fusion/guardrail 5, AutoEnhancer 5, basis versioning 4 |
| core-decode | `testDebugUnitTest` | 12 | sizing 6 (JVM), ImageDecoder 6 (Robolectric API 34, native graphics) |
| core-export | `testDebugUnitTest` | 28 | save flow 9 (JVM fake), ContentResolver 3 (Robolectric API 29), ExportCoordinator 10 (incl. 3 cancellation/slot regressions), tiled export 4, BitmapExportFrame 2 (Robolectric native graphics) |
| app | `testDebugUnitTest` | 36 | the full editor flow (§3.2) 14; stale photo work 4 (§8.1); photo access 6 VM + 8 grants (Robolectric API 29 and 34) + 2 loader (§8.2); look-book 2 (§8.3) |

Measured against the 23 golden cases:

| Check | Bound | Result |
|---|---|---|
| CPU LUT apply vs `reference.png` | ≤ 1/255 | **0/255 on all 23** (bit-exact) |
| Float32 twin of the generated shader vs `reference.png` (a1629, portrait_deep_03, night_03) | ≤ 1/255 | 0, 1, 1 |
| Shader twin, two passes (portrait_deep_03 Auto 0.8 + strong Look 0.9) vs CPU oracle | ≤ 1/255 | 1/255 |
| Canonical analysis input vs `input256.f32` | ≤ 1e-5 | max 6.6e-7 |
| Fusion through the registry (sha256 from MODEL_CARD.json) vs `fused_lut.f32` | ≤ 1e-5 | max 2.4e-7 |
| Baked vs two-stage, every 8-bit input | ≤ 2/255 | 21/23 pass; a1629 3/255, portrait_deep_03 6/255. This led to the spec change to two passes; the test pins both cases |

The shader-math twin checks the *algorithm* the GPU will run, in float32 on the JVM. It does not show that a real GPU executes it within tolerance.

### 3.1 Export buffer budget (JVM-accounted; real peaks PENDING)

`ExportBufferLedger` counts the pipeline's own large buffers:
- at most 2 full RGBA8 frames: the decoded source and the encode target;
- at most 2 tile buffers: the input and the rendered tile, each ≤ 4096² × 4 B;
- 1 full frame while encoding, because the source is released first.

At 48 MP (8064×6048) that is 2 × 195,084,288 B + 2 × 67,108,864 B ≈ 524 MB. That is under the 600 MB spec target, but it **excludes** the GL driver's buffers, the readback buffer inside `GlLutPassRenderer`, ImageDecoder's working memory and the JPEG encoder's. Device measurement is required (PENDING).

Tests check:
- seams: the rows and columns on both sides of every tile boundary, and the whole frame, are identical to an untiled render;
- the ledger peaks;
- buffers are released after a cancel mid-render.

### 3.2 Editor flow tests (`EditorViewModelTest`, virtual time)

- Pick → develop uses the 1024 analysis decode, never the display proxy. The preview equals the CPU render of the two-pass Auto plan on the proxy.
- With no basis for the model version, Auto shows unavailable and the preview is the Original; Looks still apply.
- DevelopFailed offers [Retry] (one more model run) and [Use original] (Auto strength 0 plus a notice).
- Stepped slider:
  - moving previews and commits nothing;
  - settling commits exactly one step;
  - changing category is not a step;
  - the stop index follows the displayed Look.
- 31 rapid slider requests produce ≤ 2 renders, and the last state wins.
- Strength previews while dragging and commits on release.
- Compare shows the Original; Reset and Undo update the preview.
- Save copy exports the committed state, never the transient preview, exactly once. A second Save while the first runs is refused.
- Process death: the photo is decoded again, the model is not re-run, and the history, cursor, redo, compare and category are restored; the preview is re-rendered. The transient preview is not persisted.
- A restored edit from an unavailable model version: Auto off with a notice, and the stored AutoResult is untouched.
- An unknown Look: "Look unavailable", and it is not rendered.
- An undecodable saved session: the photo is developed again.

### 3.3 Failing-before evidence and mutation checks

| Change | Evidence |
|---|---|
| Codex M2 finding 4 (basis by version) | A regression test written against the old API failed. With a "v2" basis installed and an edit saved with "v1", `lutFor()` returned a LUT instead of refusing: "Expected an exception to be thrown, but was completed successfully". |
| Scheduler `cancel(through)` | Clearing the pending slot unconditionally fails "cancel through revision 1 leaves revision 2 alive". |
| Two-pass shader | Clamping between passes in `main()` fails two shader tests: "single O4 clamp in main expected:<1> but was:<3>" and "intermediate must not be clamped/quantised". |
| Decoder colour conversion | Removing `setTargetColorSpace` and the sRGB check fails the P3 test: got `[204, 77, 51]` (P3 values passed through), expected `[221, 64, 37]`. |
| Export not cancellable during encode | Replacing `withContext(NonCancellable)` around save fails the "cancel once encoding has started" test: the state became Cancelled although the asset had been written. |
| Codex M2 review: export slot and cancellation | Three tests failed before the fix. (1) Cancel during encode, then Save: "expected:<[AlreadyRunning]> but was:<[Started(exportId=2)]>". With the hook re-arming on every encode, the old code saved copies in a loop until OutOfMemoryError. (2) Cancel before start: "expected:<Cancelled(exportId=1)> but was:<Running(exportId=1, phase=DECODING)>". (3) A stale export wrote state over the next one: "... Running(exportId=2, phase=DECODING), Cancelled(exportId=1), Running(exportId=2, ...)". |
| Export memory | Keeping the decoded source alive until after save fails the budget test: "the decoded source is released before encoding expected:<1> but was:<2>". |
| Editor exports the committed state | Exporting the transient preview's plan instead of the committed state fails the Save test: "Array elements differ at index 0". |

## 4. Contract finding: baking (resolved in spec)

Baking O1+O2 into one 33³ LUT exceeds the 2/255 tolerance on 2 of the 23 golden Auto LUTs: portrait_deep_03 reaches 6/255 and a1629 3/255. When Auto overshoots 1 inside a grid cell, the clamp kink falls between grid points and one LUT cannot represent it. Spec §4.1 was revised in `941ff9d`: two LUT passes, with baking allowed only for a pair that passes the exhaustive check. Android now renders with `LutPassPlan` (two passes). `GoldenLutTest` keeps pinning the two violations.

## 5. PENDING on physical hardware (phones disconnected — nothing here is claimed)

| Item | Status | What is needed |
|---|---|---|
| ONNX Runtime inference | **PENDING.** Not implemented; `AutoModel` has a fake only. In M1, ORT raised SIGILL on the x86_64 emulator. | ORT-backed `AutoModel` (CPU/XNNPACK, fp32). Weight parity ≤ 1e-3 on `input256.f32`, and end-to-end Auto ≤ 2/255, on the Nothing SM7635 and moto edge 60 |
| `GlLutPassRenderer` on Adreno / Mali | **PENDING.** Compiles only. Shader compile/link, RGBA32F 3D upload, FBO completeness, readback orientation and accuracy are unverified on any GPU | Instrumented test: GL vs `CpuLutPassRenderer` and golden references (≤ 1/255 expected, contract ≤ 2/255), one and two passes, tiled 48 MP |
| A faster RGBA16F + `GL_LINEAR` variant | **PENDING** (not implemented) | Enable per GPU only after it is measured within tolerance |
| Decoder on device | **PENDING.** Robolectric runs host Skia codecs | HEIF, 10-bit / F16, Ultra HDR, vendor JPEG, P3 camera files; orientation on real files |
| Timings and memory (proxy decode, preprocess, inference, preview, 48 MP export peak ≤ 600 MB) | **PENDING** | Release build on both phones |
| MediaStore and JPEG on device | **PENDING.** Robolectric checks the ContentResolver contract only, and JPEG SOI/EOI from host Skia | Instrumented save test, original-unchanged hash test (§10), device `Bitmap.compress` output (sRGB ICC, quality 92) |
| Editor on device | **PENDING.** Ran on an API 36 emulator only (§8.4) | Picker flow, preview latency with the CPU renderer vs GL, rotation and process-death restore, TalkBack |
| Persisted picker grant across a real restart | **PENDING.** Emulator showed `persisted=0x1` and a process-death restore (§8.4) | Real Photo Picker on both phones: pick, reboot / force-stop, relaunch, photo reopens; API 29 fallback (non-persistable URI) reaches PhotoAccessLost, not a crash |

## 6. Deliberate deferrals (M3 unless noted)

- **App wiring still missing:**
  - swapping `GlLutPassRenderer` in on the render thread (after device validation);
  - an ONNX Runtime `AutoDeveloper` and a packaged licensed basis (U1);
  - writing the recovery snapshot on every commit and the "Continue editing?" UX (M4);
  - the "Discard edits?" dialog;
  - thumbnails;
  - crossfade and full accessibility (adaptive layout and haptic detents landed in §9).
- **Source orientation:** `SourceRef.orientation` is recorded as 1 because ImageDecoder returns upright frames. Recording the file's EXIF value is M3.
- **Export metadata:** sRGB ICC embedding, EXIF orientation 1, safe-metadata copy and the location setting (U7).
- **Spatial operators (O3):** grain, vignette and local contrast. `TilePlan` has no apron; O3 must extend it.
- **Other modules and tooling:**
  - `core-looks` (look-book, sha256-checked Look LUTs, ID migrations);
  - the `feature-editor` module;
  - Hilt;
  - the `contracts/` directory (M2.1, shared with iOS).
- **Instrumented tests.** None yet. (Robolectric Compose UI tests exist since §9: `EditorScreenTest`.) The §8.4 emulator run is a manual, scripted check, not a test in the build.

## 7. Notes

- Compose BOM is pinned to `2026.06.01` and lifecycle to `2.10.0`. The newer releases require `compileSdk 37`.
- `org.gradle.vfs.watch=false`: file-system watching missed edits in this git worktree and reported stale `UP-TO-DATE` results.
- Reused from the M1 harness: the antialiased resize (`ImageUtil.kt`) and the GLES structure and shader (`GlLut.kt`). The CPU trilinear weights were changed to float64 to match NumPy exactly.

## 8. Follow-up: Codex findings 1 and 4, Looks, user-flow demo

### 8.1 Finding 1 — stale Auto completion replaced the current photo's session

Opening photo B cancelled A's job, but a model runtime or decoder that ignores cancellation could still return. A's Auto result then replaced B's session and the saved session JSON, and A's LoadFailed / DevelopFailed replaced B's Ready phase.

Fix: the photo generation is carried through load, develop and retry, and re-checked after every suspension point (success, Developing, Developed, Failed, LoadFailed). The loaded photo is stored with its generation, so Retry, "Use original" and Save copy only act on the photo on screen.

Regression tests use a non-cancellable suspension (`suspendCoroutine`) for A, open B, wait for Ready, then let A finish. They assert that B's phase, session, Auto status, preview and SavedStateHandle (`KEY_ASSET`, `KEY_SESSION`) are unchanged. Failing before the fix:

| Case | Before (expected B, got) |
|---|---|
| stale Auto success | session asset `…/42` (A), weights `0.1, 0.2, 0.7` (A), preview hash changed |
| stale Auto failure | phase `DevelopFailed(model crashed on A)` |
| stale load failure | phase `LoadFailed(A was deleted)` |
| stale retry | session asset `…/42` (A), weights `0.1, 0.2, 0.7`, preview hash changed |

### 8.2 Finding 4 — the picked URI lost read access across restart

The picker result was stored as a URI string only. Picker URIs are readable until the process ends, so a restore after process death reopened a URI the app could no longer read.

Fix:
- `PhotoAccessGrants` (production: `ContentResolverPhotoAccessGrants`). `openPhoto` takes a persistable READ grant while the picker's temporary grant is still valid, then releases the previous photo's grant so grants do not build up against the per-app cap. The new grant is taken first. A grant that cannot be persisted (seen with some API 29 fallbacks) returns false and the photo still opens for this process.
- `ContentResolverPhotoLoader` reports `SecurityException` / `FileNotFoundException` anywhere in the cause chain as `PhotoAccessLostException`.
- New phase **PhotoAccessLost**: the saved asset and session are dropped (a later restart does not retry the dead URI), the dead grant is released, and the screen offers **"Choose the photo again"**, which relaunches the picker. It never crashes and is never a dead end.
- DEFERRED: re-attaching the dropped edit when the same photo is picked again (match by fingerprint, rebase onto the new URI). For now the photo develops anew.

Failing before the fix (against the API skeleton): grant on pick `expected:<[retain …/42]> but was:<[]>`; release on switch `but was:<[]>`; revoked restore `expected:<PhotoAccessLost> but was:<LoadFailed(…)>`; Robolectric `retain` did not persist a grant; the loader threw a raw `SecurityException` / `FileNotFoundException` instead of `PhotoAccessLostException`. Restore with retained access, a non-persistable grant and a non-access LoadFailed are covered too.

### 8.3 Looks: where they come from

Looks come from the **Look pack** built from the curated preset collection (`experiments/presets/look_pack/`, spec D5, D6, §4.5). The procedural `PlaceholderLookBook` and the debug/release `BundledLookBook` split are gone; formula LUTs survive only as a test fixture (`app/src/test/.../FixtureLookPack.kt`) that writes tiny packs in the real format.

- **Loader** (`LookPackLoader`): reads `lookpack/manifest.json` from app assets. Format `lightly-look-pack` v1 at the time (v2 since §9.2), `lutDimension` 33 and `lutEncoding` `rgba-float32-red-fastest` are required; anything else, a missing manifest or bad JSON gives an empty `LookBook` with `unavailableReason`. Each Look's LUT must exist, be 574,992 bytes and match its `lutSha256`; a failing Look is dropped and listed in `LookBook.problems` (logged under `LightlyLooks`), and a category left empty is dropped too. Unsafe `lutFile` paths (absolute, `..`) are refused.
- **Order and labels**: categories and stops keep manifest order (the catalog's browse order). Labels are pack data; the editor keys categories by the opaque `id` and has no category names of its own. The default category is the pack's first; a saved `editor.category` the pack no longer has falls back to it.
- **Slider**: stop 0, then one stop per preset, labelled with the preset's `name` verbatim. It picks a preset and is never an intensity control: moving between presets keeps the committed Look's strength (100% only when coming from no Look). The separate Strength slider is unchanged. TalkBack: "Warm, Nordic Tone (10), 3 of 5".
- **Stop 0 name**: "Auto" only while an Auto correction is applied (`AutoStatus.Applied` and Auto strength > 0); otherwise "Original" (no model in the build, model unavailable, Use original, Auto strength 0). Visible label and TalkBack use the same name ("Warm, Original, 1 of 5").
- **Honest status** (format 1 wording; §9.2 drives it from the format 2 `status`): while any Look is `lr-model-approximation` or not `validated` (all 18 today), the editor shows "Looks are approximate conversions, not yet checked against Lightroom." (iOS wording). Pack LUTs omit spatial operators (clarity, texture, vignette, grain) by design; nothing here claims Lightroom fidelity.
- **Persistence**: `LookRef(lookId, lookVersion: String, strength)`. `lookVersion` is the pack's version string (changes with the LUT), so `EditState.CURRENT_SCHEMA` is now **2**. (Superseded in §9.1: a schema 1 edit is now migrated, not dropped.) Pack IDs depend only on the preset, so relabelling, reordering or regrouping categories does not affect a restored edit (tested with two fixture manifests). An unknown (id, version) showed "Look unavailable; showing Auto." (superseded by the unavailable / changed rules in §9.1).
- **No pack**: the build succeeds and the editor shows "No Looks are available in this build."
- DEFERRED: loading the pack off the main thread with lazy LUT decode (today ~10 MB of floats are read and hashed when the editor environment is created); the `{oldId → newId}` migration table.

#### Bundling (app/build.gradle.kts)

The pack is git-ignored and derived from the private presets, so it is never committed; each variant's generated assets get `lookpack/manifest.json` + `lookpack/luts/*.f32` from task `bundle<Variant>LookPack` (`variant.sources.assets.addGeneratedSourceDirectory`). The pack directory is, first match wins:
1. `-PlightlyLookPackDir=/abs/path` or `LIGHTLY_LOOK_PACK_DIR` (a path without `manifest.json` fails the build);
2. `<repo>/experiments/presets/look_pack/out` (`<repo>` = parent of `android/`);
3. in a `<main>/.claude/worktrees/<name>` worktree, `<main>/experiments/presets/look_pack/out` (derived from the path).

None found: a configuration warning, no assets, and the app has no Looks. Checked: the debug APK built in this worktree contains `assets/lookpack/manifest.json` and 18 LUTs; a throwaway checkout outside `.claude/worktrees` built with no `lookpack/` assets and succeeded.

### 8.3a Launcher icon packaging check

Task `verify<Variant>LauncherIcon` (debug and release; every `assemble<Variant>` depends on it) inspects the **built apk** with `aapt2` from `build-tools/<android.buildToolsVersion>`: `dump badging` must report an application icon, every icon path must be in the apk, and an adaptive-icon XML must have a foreground and background that resolve through `dump resources` (the foreground drawable file must be in the apk). Report: `app/build/reports/launcher-icon/<variant>.txt`.

Regression proof: in a throwaway worktree at the pre-icon commit plus this check, `assembleDebug` failed with "Launcher icon check failed for app-debug.apk: aapt2 dump badging reports no application icon"; at the current head it passed (debug `res/mipmap-anydpi-v26/ic_launcher.xml`, release `res/BW.xml` after resource-name shortening). Emulator: the installed debug APK showed the Lightly icon in the Pixel 9 Pro (API 36) app drawer, not the default robot.

### 8.4 User flow on the emulator (emulator-only)

Debug APK on the `Pixel_9_Pro` AVD (API 36, arm64, started `-read-only`, so nothing persists on the AVD). The test photo is an Unsplash image from `experiments/lut3d/photos` (`landscape_03.jpg`, 3000×2000) pushed to MediaStore. Screenshots, a screen recording (first 180 s) and logs are in the session scratchpad (`demo/android/`), not in the repo.

| Step | Result on the emulator |
|---|---|
| Choose photo (Photo Picker) | Opens; read grant persisted (`dumpsys activity permissions`: `persistable=0x1 persisted=0x1`) |
| Developing | Too fast to capture on the emulator; covered by unit tests |
| Auto unavailable | Emulator run used the earlier build: DevelopFailed → [Continue with original]. Since the follow-up commit, a build without a model opens straight into editing with the Auto-unavailable notice (unit-tested; not re-captured on the emulator). |
| Category + stepped slider, two stops | Film → Fade (stop 1) → Punch (stop 2), each one undo step |
| Compare | Shows the Original ("Photo, original") |
| Undo / Reset | Undo returns to Fade; Reset returns to Auto |
| Save copy | New MediaStore item `Lightly_….jpg`, 3000×2000, `is_pending=0`; the original's sha256 on the device equals the host file |
| Process death (`am kill` in background) + relaunch | Session restored (Film / Fade, Undo available) through SavedStateHandle and the persisted grant |
| Source item deleted, then kill + relaunch | PhotoAccessLost with "Choose the photo again"; the dead grant was released (`persisted=0x0`); picking again opens the photo |

Gaps found on the emulator and fixed:
- edge-to-edge (targetSdk 36): the photo drew under the status bar and the buttons under the gesture handle → `WindowInsets.safeDrawing` padding;
- "Save copy" was off screen in the horizontally scrolling action row → the row wraps;
- a drag starting on the slider thumb at stop 0 lands in the back-gesture zone → `systemGestureExclusion()` on both sliders;
- the photo area announced "No photo" while it showed the Original before a session existed → "Photo, original".

Not shown by the emulator run, and still **PENDING** or unverified:
- a force-stop or reboot restore: SavedStateHandle survives only system process death; the recovery snapshot and "Continue editing?" UX are M4;
- GPU rendering (the app previews with the CPU renderer), device performance and memory;
- spatial operators (grain, vignette, local contrast) and their export fidelity;
- Auto: unavailable in the app, because no production basis and no inference engine are bundled. Research (FiveK-derived) weights are never bundled.

## 9. Editor milestone (2026-10-02): saved-edit contract, pack format 2, agreed UX

Worked directly on `master`. Commits are listed in the milestone report. Evidence (screenshots, screen recordings, logs, APK checks, failing-before logs) is outside the repo in `~/.codex/artifacts/lightly/editor-milestone-20261002/android/`.

### 9.1 Saved-edit compatibility (`shared/fixtures/edit-state/`, spec §4.5)

- **Shared fixtures, no private copies.** `core-session` and `app` tests read `shared/fixtures/edit-state/*.json` through the `lightly.editStateFixturesDir` test system property, which `android/build.gradle.kts` sets for every module. The directory is a hashed task input, so editing a fixture re-runs the tests. `v2-*` encodes are byte-exact against the files.
- **Schema 1 is migrated, not dropped** (v3 differs from M2). `SavedEdits` is the only decode path, for SavedStateHandle, recovery snapshots and the fixtures. It turns a schema 1 `look.lookVersion` integer `n` into `"legacy-v1-<n>"`, migrates every history entry of a session, and leaves everything else unchanged. Decoding stays strict otherwise: unknown keys, schema 3, an out-of-range strength and a non-integer schema 1 version are rejected. The old test "a schema 1 edit … is rejected" was replaced.
- **Resolution** (`LookBook.resolve`, `LookIssue`):
  - an unknown `lookId` makes the Look *unavailable*;
  - a known id with another version (every `legacy-v1-*`) makes it *changed*;
  - in both cases the photo renders without the Look, the `LookRef` and the history are kept, and a notice is shown. Strength is hidden;
  - "Use current version" (changed only) is an explicit, undoable step that keeps the Look and its strength;
  - nothing is substituted, and Save copy writes what is shown, so the notice stays after saving.
  Tests cover re-saving (compare, category change, Save copy, a new Look then Undo, process death), which writes the original `LookRef` back unchanged, and Undo after "Use current version", which returns to the unrendered changed state with the old version recorded.

### 9.2 Look pack format 2

`LookPackLoader` reads `formatVersion` 2 only. A format 1 pack is refused as a whole, with a reason that names the format. Each Look keeps `conversion`, `globalColour {status, evidence}`, `fullRecipe {status, evidence}` and `status` verbatim. A stop that lacks any of them is dropped and reported.

The status is re-checked with the builder's `promoted_status` rule. A claim that its own evidence does not back (for example a model-derived LUT marked `validated`) is demoted and reported, and an unknown status reads as `approximate`. The notice follows status:
- any `approximate` Look → "Looks are approximate conversions, not yet checked against Lightroom.";
- only `global-colour-validated` → a separate notice that effects may be missing;
- all `validated` → none.

A test loads the real bundled pack when present: format 2, 18 Looks, no problems, names verbatim, both Mono black-and-white presets.

### 9.3 UX audit (before this milestone's UX work, at `e8ddfd9`)

Status: **implemented**, **partial** or **missing**. File references are under `android/app/src/main/kotlin/com/lightlylabs/lightly/editor/` unless noted.

| # | Agreed behaviour | Before | Where / why | After (this milestone) |
|---|---|---|---|---|
| 1 | Photo-first: controls below the photo on compact width | partial | `EditorScreen.kt`: one `Column`, photo `weight(1f)`, but the controls were not capped or scrolled and could squeeze the photo | `EditorLayoutPolicy` `Stacked`: panel ≤ 40% (58% from 1.3× font scale), always scrolls |
| 2 | Side panel 320–380 dp on expanded width / landscape / tablet / unfolded foldable | missing | single vertical layout; `// DEFERRED (M3/M4): adaptive layout` | `SideBySide` from WindowSizeClass (`BREAKPOINTS_V1`, medium+) or landscape; panel `clamp(0.32·w, 320, 380)` |
| 3 | Foldable book / tabletop: never place the photo across the hinge | missing | no WindowManager dependency | `WindowInfoTracker` → `FoldingFeature` in `MainActivity`; separating or half-opened vertical hinge: photo pane ends at the hinge; horizontal: photo above it |
| 4 | Categories from the pack | implemented | `LookBook`, `LookPackLoader`, chips keyed by opaque id | unchanged |
| 5 | Discrete stops select named presets; stop 0 "Original" unless Auto applied | implemented | `SteppedLookSlider` (Material `Slider` with `steps`), `EditorViewModel.baseStopName` | custom `SteppedLookSlider.kt` (same contract) |
| 6 | Visible stop markers | partial | Material step ticks only, faint and version-dependent | one marker node per stop, thumb snaps to markers, haptic tick per detent |
| 7 | Selected name **and position** ("Nordic Tone (10) · 3 of 5") | partial | name only; position only in TalkBack `stateDescription` | `EditorViewModel.stopCaption`, shown above the slider |
| 8 | Strength secondary, only with a Look; drag previews, release commits one step | partial | behaviour implemented; shown for any committed Look, including unrendered ones | shown only for a Look that renders; smaller label |
| 9 | Undo / Redo | implemented | `EditActions` row | unchanged |
| 10 | Compare: hold and toggle | partial | both called `setCompare`, so releasing a hold switched the toggle off | `holdCompare` (transient) separate from the persisted toggle |
| 11 | Compare: clear "Original" indicator on the photo | missing | only the TalkBack label changed | "Original" pill on the photo area whenever it shows the Original |
| 12 | Reset undoable | implemented | `EditSession.resetToAuto` | unchanged; disabled when there is no Look |
| 13 | Prominent Save copy | partial | one filled button among six in a `FlowRow` | full-width filled button; "Choose another photo" demoted to a text button |
| 14 | Compact status notices | partial | up to four full-width texts in error colour | one compact notice block (Look issue + action, Auto status, pack status, save result with Cancel) |
| 15 | Retry / Continue only for genuine Auto failures | implemented | `DevelopFailed` only; the no-model path goes straight to Ready | unchanged |
| 16 | Large text: panel scrolls, photo stays visible, names wrap | partial | names wrapped; the panel did not scroll | panel always scrolls; the photo keeps > 40% |
| 17 | Real 18-preset pack, names verbatim, both Mono presets | partial | names verbatim, but the loader read format 1 only, so the format 2 pack loaded **no Looks** | format 2 loader; real-pack test |
| 18 | Unavailable / changed Look notices and "Use current version" | missing | one "Look unavailable; showing Auto." for both cases | §9.1 |

Not closed (deferred): stop names under every marker when they fit (only the current name is shown), the "Discard edits?" dialog, crossfade, thumbnails. The "Original" pill sits at the photo area's corner, which on a letterboxed photo is outside the image.

v3 differs from the spec's 35% compact-panel cap. On the Pixel 9 Pro AVD the Ready panel is ~1050 px of 2628 px (40%): notices, chips, caption, slider, actions and Save copy. At 35% (920 px), Save copy would need scrolling. The panel scrolls in any case.

### 9.4 Tests

- `EditorViewModelTest`: added tests for resolution, preservation, compare hold vs toggle, the caption, and Reset / Redo.
- `EditorLayoutPolicyTest` (JVM, 9 tests).
- `EditorScreenTest` (Robolectric Compose, 10 tests) with a catalog-shaped pack: the real 5 categories, 18 names and lookIds, with fixture LUTs. It covers portrait, landscape, tablet, book posture, a flat fold, 2× font, markers and the caption, Strength, the Compare label, and the no-model notices.
- `LookPackLoaderTest`: format 2 and the real pack.
- Core-session tests read the shared fixtures.

Failing-before logs are in `failing-before/`:
- core-session migration: 5 failed;
- app resolution: 4 failed;
- format 2: 39 failed;
- compare, caption and reset: 4 failed;
- a mutation that forces the stacked layout: 11 failed.

Full run: see §9.5.

### 9.5 Installed app on emulators (emulator-only; evidence in `~/.codex/artifacts/lightly/editor-milestone-20261002/android/`)

**Before installing** (`apk-checks/`):
- `verify{Debug,Release}LauncherIcon` passed (debug `res/mipmap-anydpi-v26/ic_launcher.xml`, release `res/BW.xml`);
- both APKs contain `assets/lookpack/manifest.json` with `formatVersion` 2 and 18 LUTs, all `status: approximate`;
- no model, basis or ONNX file is in either APK.

**Pixel_9_Pro AVD** (API 36, arm64, `-read-only`, debug APK):

| Step | Result | Evidence |
|---|---|---|
| Launcher | Lightly icon in the app drawer (not the default robot) | `screens/00-launcher-app-drawer.png` |
| Empty → Photo Picker | "Choose a photo" opens the system picker; `landscape_03.jpg` (3000×2000) picked | `01-empty.png`, `02-photo-picker.png`, `recordings/flow1-launch-pick.mp4` |
| Ready, no model | Straight to editing, no Retry. One compact notice block (Auto unavailable + approximate Looks), 5 pack categories, "Original · 1 of 5", 5 visible markers, prominent Save copy. Panel 1051 of 2628 px (40%) | `03-ready-portrait.png` |
| Preset, category 1 | Warm → tap marker 3: "Nordic Tone (10) · 3 of 5", Strength appears | `04-warm-nordic-stop3.png` |
| Preset, category 2, by drag | Mono: a real drag from stop 1 to stop 3 gives "03 Black and White 03 · 3 of 4" | `05-mono-03bw-stop3-dragged.png`, `recordings/flow2-…mp4` |
| Strength | Drag to 46%: partial desaturation | `06-strength-46.png` |
| Compare | Toggle shows the Original with an "Original" label on the photo area | `07-compare-original-label.png` |
| Undo / Redo | Undo → Strength 100% (full B&W), Redo enabled; Redo → 46% | `08-…png`, `09-…png`, `recordings/flow3-…mp4` |
| Reset | "Original · 1 of 4", Strength hidden, Reset disabled, Undo enabled | `10-reset-original.png` |
| Save copy | Film → Retro Wedding Tone (15), Save copy → "Saved as a new photo. Original unchanged." New MediaStore row `Lightly_1790931317083.jpg`, 3000×2000, `is_pending=0`, `Pictures/Lightly/`, owner `com.lightlylabs.lightly`, JPEG SOI `ff d8`. The original's sha256 on the device is `f424094c…be52` before and after, equal to the host file | `11-…png`, `12-saved-notice.png`, `13-saved-copy-….jpg`, `logs/save-copy-mediastore.txt`, `recordings/flow4-…mp4` |
| Phone landscape | Rotation keeps the session. Side panel 1896–2856 px = 320 dp, photo 156–1896 px | `20-layout-phone-landscape.png` |
| Font scale 2.0 | Photo ≈ 42% of the height. The panel scrolls (it keeps its scroll position). "Retro Wedding Tone (15) · 2 of 5" wraps | `21-layout-phone-portrait-font-2.0.png` |

**Lightly_Pixel_Tablet AVD** (`pixel_tablet` profile, created from the installed `android-36.1` image, 2560×1600 at 320 dpi):

| Layout | Result | Evidence |
|---|---|---|
| Tablet landscape | Panel 1800–2560 px = 380 dp beside the photo; "Adventure Tone (3) · 4 of 5" | `22-layout-tablet-landscape.png` |
| Tablet portrait | Panel 960–1600 px = 320 dp beside the photo (800 dp is medium width). A landscape photo leaves empty space above and below it; acceptable under the agreed rule, worth a design review | `23-layout-tablet-portrait.png` |

**Lightly_Pixel_9_Pro_Fold AVD** (`pixel_9_pro_fold` profile, inner display 2076×2152 at 390 dpi; screenshots need `screencap -d <display id>`):

| Posture | Result | Evidence |
|---|---|---|
| Unfolded, flat | The fold does not separate, so the normal rule applies: a 320 dp side panel (1296–2076 px) | `24-layout-foldable-unfolded-flat.png` |
| Book posture (`adb emu posture 2`, `HALF_OPENED`) | FoldingFeature is a vertical hinge at x = 1038 px. Photo 0–1038 px, panel 1038–2076 px: the photo stays wholly in the left pane. The edit survived the posture change | `25-layout-foldable-book-posture.png` |

Not captured on an emulator: tabletop posture (covered by `EditorLayoutPolicyTest` only) and press-and-hold Compare (unit-tested; `adb input` cannot hold while taking a screenshot reliably on this host). The `FATAL EXCEPTION` lines in `logs/foldable-logcat-app.txt` come from the `uiautomator dump` tool timing out under host load, not from the app. A "System UI isn't responding" dialog appeared once on the foldable for the same reason.

Findings on the emulator:
- **Pack defect (outside `android/`, reported, not fixed):** `nordic-tone-10-7b6a3a.f32` maps the r = g = 0 axis (inputs (0, 0, b), b = 1…8 of 32) to bright blue (0.017, 0.158, 0.877). On `landscape_03.jpg` this shows as blue blotches in the darkest foliage. A scan of all 18 LUTs (`logs/lut-dark-blue-defect-scan.txt`) finds it only in Nordic Tone (10). The large shifts in the Mono LUTs are expected desaturation. The fix belongs in `experiments/presets/look_pack/` (the model-approximation LUT for that preset).
- **CPU preview latency:** the app still previews with `CpuLutPassRenderer` (debug build, full display proxy). On this heavily loaded host (load average ~38), a Look change took 10–25 s to appear. Saving 3000×2000 took about 1 minute. This is not a device measurement; GL rendering is still PENDING (§5).

### 9.6 Test totals

`./gradlew test assembleDebug assembleRelease` with JDK 25: **225 tests, 0 failures**. Before this milestone there were 185.

| Module | Tests |
|---|---|
| app | 94 |
| core-render | 43 |
| core-session | 31 |
| core-export | 28 |
| core-model | 17 |
| core-decode | 12 |

Both APKs built, and both launcher-icon checks passed. Log: `logs/final-gradle-run.txt`.

### 9.7 Hardware-only limitations (still PENDING, phones disconnected)

- **GPU renderer on Adreno / Mali:** `GlLutPassRenderer` is still not wired or validated. The app previews and exports with the CPU reference renderer, which is what made the emulator preview slow (§9.5).
- **ONNX Runtime:** no inference engine and no licensed basis ship, so Auto stays unavailable. No research weights are bundled (APK checked). Nothing in the UI calls an unchanged original or a fixed filter "Auto".
- **Real Photo Picker and restart:** the persisted grant across a force-stop or a reboot, and the API 29 fallback, need the real phones.
- **Performance and memory:** preview latency with the GL path, 48 MP export peak (≤ 600 MB target), and haptic detent feel. Emulator timings on a loaded host are not evidence.
- **Physical foldables:** hinge occlusion (`OcclusionType.FULL`) and the real posture sensors. The emulator hinge has zero width.

### 9.8 Deferred and blockers

- **Blocker (outside `android/`):** the `nordic-tone-10` LUT maps near-black blue-axis inputs to bright blue (§9.5). It needs a fix in the pack builder or that preset's conversion, then a pack rebuild. The app renders the LUT as shipped.
- **DEFERRED:**
  - stop names under the markers when they fit;
  - an "Original" label anchored to the image bounds rather than the photo area;
  - the "Discard edits?" dialog;
  - crossfade and thumbnails;
  - the recovery snapshot written on every commit, with its "Continue editing?" UX (M4);
  - loading the pack off the main thread.
- The created AVDs `Lightly_Pixel_Tablet` and `Lightly_Pixel_9_Pro_Fold` are kept for re-runs. Delete them with `avdmanager delete avd -n <name>`.

### 9.9 Codex review of `d5690dd`: Strength rule, Save copy, layout by photo area

Worked directly on `master`. Evidence is in `~/.codex/artifacts/lightly/review-d5690dd-fixes/android/` (`failing-before/`, `apk-checks/`, `logs/`, `screens/`).

**Strength (agreed rule, both platforms; replaces "strength carries over", v3 differs).** `EditorViewModel.lookAtStop`:
- settling on the stop that is already committed returns the committed `LookRef`, so `EditSession` records nothing: Strength, history and redo stay, only the transient preview ends;
- any other preset, previewed or committed, is its designed look at 100%, one undo step;
- Undo / Redo restore Strength as committed, Reset is one undoable step, Strength commits on release only.
"Already committed" is the same `lookId` **and** `lookVersion`. A changed Look (older version) does not render and the slider shows stop 0 for it, so picking its stop applies the pack's current version at 100%, as an explicit choice. Review repro test: A → Strength 40% → preview B (shown at 100%) → settle on A ⇒ 40%, session unchanged. Failing before: 4 of 7 new tests (`failing-before/strength-rule.txt`).

**Save copy is pinned.** The panel is a scrolling area (`weight(1f, fill = false)`) followed by Save copy, so Strength or extra notices can no longer push it below the visible panel. `EditorScreenTest` asserts it lies wholly inside the panel and the window, without scrolling, with Strength and every notice shown: compact portrait at font 1.0 and 2.0, phone landscape at 2.0, tablet portrait at 2.0, tablet landscape, book posture at 2.0. Failing before: compact portrait 1.0 and phone landscape 2.0 (`failing-before/save-copy-visible.txt`).

**Layout by displayed photo area (replaces the size-class rule of §9.3 #2, v3 differs).** `EditorLayoutPolicy.decide(…, photoAspectRatio)` fits the photo (aspect from the upright preview; 4:3 until it decodes) into the box each placement leaves and takes the larger area; ties go to controls below. The stacked panel is counted at its cap, which is conservative. Minimums:
- a stacked panel under 280 dp (phone landscape) is not offered;
- a portrait window under 533 dp never gets a side panel (320 dp panel and 40% photo);
- the stacked photo keeps ≥ 40% at large text;
- a separating hinge decides first (book: photo in one pane; tabletop: photo above), so the photo never crosses it.

| Window (dp) | Landscape 3:2 photo | Portrait 2:3 photo |
|---|---|---|
| Phone portrait 412×860 | below | below |
| Phone landscape 860×412 | side | side |
| Tablet portrait 800×1230 | below | below (492×738 vs 480×720); a 9:21 photo goes side |
| Tablet landscape 1280×750 | side | side; a 4:1 panorama goes below |
| Foldable flat 852×860 | below (may span the flat fold) | side |
| Foldable book posture | side, photo in the left pane | same |

Failing before (old rule behind the new API): 4 policy tests (`failing-before/layout-by-photo-area.txt`). The now unused `window-core` dependency was removed.

**Tests:** 246, 0 failures (app 115, core-render 43, core-session 31, core-export 28, core-model 17, core-decode 12). Both APKs built and both launcher-icon checks passed. Both APKs carry `assets/lookpack/manifest.json` format 2 with 18 LUTs, byte-identical to `experiments/presets/look_pack/out`, and no model, basis or ONNX file (`apk-checks/`).

**Emulators** (emulator-only, debug APK, `-read-only` AVDs, `landscape_03.jpg` 3000×2000; one AVD at a time; UI dumps in `logs/`, crash buffers empty):

| Device / state | Result | Evidence (`screens/`) |
|---|---|---|
| Pixel_9_Pro portrait, font 1.0, Warm → Earthy Wedding Tone (6), Strength 40% | Save copy 2604–2748 px inside the panel (1733–2784), visible without scrolling | `01-…png` |
| Same, drag stop 1 → stop 2 (finger down) | Photo: "Nordic Tone (10) at 100 percent" | `02a-…png` |
| Drag back to stop 1, release | "Earthy Wedding Tone (6) at 40 percent". One Undo returns to the same preset at 100% (the step before Strength), so the return added no step; Redo → 40% | `02b-…png`, `02c-…png` |
| Pixel_9_Pro portrait, font 2.0 | Photo 156–1260 px (42% of the height); Save copy 2588–2748 visible | `03-…png` |
| Lightly_Pixel_Tablet landscape | Side panel 1800–2560 px (380 dp) | `04-…png` |
| Lightly_Pixel_Tablet portrait, landscape photo | Controls below; photo full width (1600 px), panel 1548–2496 | `05-…png` |
| Lightly_Pixel_9_Pro_Fold unfolded flat, landscape photo | Controls below; photo 0–2076 × 136–1299 px | `06-…png` |
| Same, book posture (`adb emu posture 2`) | Photo 0–1038 px, panel 1038–2076 px: photo stays left of the hinge | `07-…png` |

While a different preset is previewed during a drag, the Strength label still shows the committed value (40%) rather than the preview's 100%. The photo shows the preview correctly; the label follows the committed Look by design (Strength belongs to it), noted for the design review.


## 9.10 First run on the physical dev phones (2026-10-02, after 9b1fcd8)

| Phone | SoC / GPU | Android | Result |
|---|---|---|---|
| Nothing A069 (002843623001047) | Qualcomm SM7635 / Adreno | 16 | Pass |
| motorola edge 60 (ZY22MQNLBJ) | MediaTek MT6878 / Mali | 15 | Pass |

The same steps ran on both phones:
- Before install, the launcher-icon check and the Look-pack check passed. The launcher shows the Lightly icon.
- The real system photo picker opened, and the editor started on "Original · 1 of 5" with the Auto-unavailable notice.
- Warm > Nordic Tone (10) applied.
- Strength went to 44% while Save copy stayed visible.
- Compare, Undo, Redo, Reset and an Undo of the Reset all gave the expected states.
- Save copy wrote a new 3000×2000 JPEG. The original's sha256 was unchanged.
- logcat showed no crashes and no ANRs.

Evidence: `~/.codex/artifacts/lightly/review-d5690dd-fixes/devices/`.

**Still pending on hardware:**
- the GLES renderer, because the app still renders on the CPU;
- on-device Auto inference, because no model ships;
- picker access across a reboot or force-stop;
- timing and memory measurements. The roughly 11 s Save copy time is wall-clock time with the CPU renderer, not a benchmark;
- foldable hinge behaviour.
