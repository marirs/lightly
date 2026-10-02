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
  - adaptive layout, haptic detents, crossfade and full accessibility.
- **Source orientation:** `SourceRef.orientation` is recorded as 1 because ImageDecoder returns upright frames. Recording the file's EXIF value is M3.
- **Export metadata:** sRGB ICC embedding, EXIF orientation 1, safe-metadata copy and the location setting (U7).
- **Spatial operators (O3):** grain, vignette and local contrast. `TilePlan` has no apron; O3 must extend it.
- **Other modules and tooling:**
  - `core-looks` (look-book, sha256-checked Look LUTs, ID migrations);
  - the `feature-editor` module;
  - Hilt;
  - the `contracts/` directory (M2.1, shared with iOS).
- **Compose UI tests and instrumented tests.** None yet. The §8.4 emulator run is a manual, scripted check, not a test in the build.

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

- **Loader** (`LookPackLoader`): reads `lookpack/manifest.json` from app assets. Format `lightly-look-pack` v1, `lutDimension` 33 and `lutEncoding` `rgba-float32-red-fastest` are required; anything else, a missing manifest or bad JSON gives an empty `LookBook` with `unavailableReason`. Each Look's LUT must exist, be 574,992 bytes and match its `lutSha256`; a failing Look is dropped and listed in `LookBook.problems` (logged under `LightlyLooks`), and a category left empty is dropped too. Unsafe `lutFile` paths (absolute, `..`) are refused.
- **Order and labels**: categories and stops keep manifest order (the catalog's browse order). Labels are pack data; the editor keys categories by the opaque `id` and has no category names of its own. The default category is the pack's first; a saved `editor.category` the pack no longer has falls back to it.
- **Slider**: stop 0, then one stop per preset, labelled with the preset's `name` verbatim. It picks a preset and is never an intensity control: moving between presets keeps the committed Look's strength (100% only when coming from no Look). The separate Strength slider is unchanged. TalkBack: "Warm, Nordic Tone (10), 3 of 5".
- **Stop 0 name**: "Auto" only while an Auto correction is applied (`AutoStatus.Applied` and Auto strength > 0); otherwise "Original" (no model in the build, model unavailable, Use original, Auto strength 0). Visible label and TalkBack use the same name ("Warm, Original, 1 of 5").
- **Honest status**: while any Look is `lr-model-approximation` or not `validated` (all 18 today), the editor shows "Looks are approximate conversions, not yet checked against Lightroom." (iOS wording). Pack LUTs omit spatial operators (clarity, texture, vignette, grain) by design; nothing here claims Lightroom fidelity.
- **Persistence**: `LookRef(lookId, lookVersion: String, strength)`. `lookVersion` is the pack's version string (changes with the LUT), so `EditState.CURRENT_SCHEMA` is now **2**; a schema 1 edit is dropped and the photo develops again. Pack IDs depend only on the preset, so relabelling, reordering or regrouping categories does not affect a restored edit (tested with two fixture manifests). An unknown (id, version) still shows "Look unavailable; showing Auto." iOS must make the same `lookVersion` change.
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
