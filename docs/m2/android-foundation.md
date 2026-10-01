# M2 — Android foundation

Branch: `m2/android-foundation` (from `m1/spec-ux-lut-feasibility` @ `c6b1f98`, merged again with m1 @ `d293406`)
Project: `android/` (new Gradle multi-module project; `Lightly/`, `experiments/` and other `docs/` are untouched)

This milestone builds the Android parts of spec §8 that can be verified **without a phone**:
- the edit model;
- the latest-wins preview scheduler;
- the CPU reference and a GLES port of the LUT renderer;
- model preprocessing, fusion and versioned basis resolution;
- the image decoder;
- the export path and MediaStore writer;
- a thin Compose shell.

Everything was verified with JVM unit tests and Robolectric only. **No physical device or emulator was used in M2.** Every hardware-dependent claim below is marked **PENDING**.

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
| `core-export` | Android library | `SaveCopyExporter` (insert `IS_PENDING=1` → encode **once** → `IS_PENDING=0`; the pending row is deleted on failure; the source is never opened). `ContentResolverGateway`, `BitmapJpegEncoder`, `Rgba8JpegEncoder`. **`ExportCoordinator`**: an export path separate from the preview scheduler (§2 below). |
| `app` | Android app | `EditorViewModel` (session in a `StateFlow` and in `SavedStateHandle`; transient preview never persisted) with **`AutoStatus`** (Applied or Unavailable: Auto off plus a visible notice). `EditorScreen` is a thin Compose shell. The app ships an **empty basis registry**, because the research basis must not be bundled. The shell therefore shows "Auto enhancement unavailable" until the licensed model (U1) is packaged with its pinned sha256. |

### Decisions taken while implementing

- **Two kinds of revision.** `EditState.revision` counts commits and stays monotonic after undo-then-commit. The render scheduler issues its own request IDs. This is now spec §5.2 (`d293406`).
- **Saved Auto results resolve only to their own model version** (Codex M2 finding 4). A missing or tampered basis gives `AutoUnavailable`. The stored `AutoResult` is never rewritten, so the edit renders correctly again once that version is installed.
- **Two LUT passes in one fragment shader.** The value between O1 and O2 stays float. Two draws through an RGBA8 framebuffer would clip and quantise it, which the CPU oracle does not do. The shader does manual trilinear with `texelFetch` on RGBA32F and uses no hardware filtering.
- **Export is not a scheduler request kind.** `ExportCoordinator` has its own job and its own single-flight slot. It is not a child of the preview scheduler or the session, so preview submits, `cancel(through)` and `close()` cannot drop it. Cancel works until encoding starts. Encode and write are NonCancellable. The MediaStore row is created only after rendering, so a cancelled export leaves nothing behind.
- **Analysis decode size.** Spec §4.6 says the analysis source needs a long edge ≥ 1024; the M2 brief said ≤ 1024. Decoding to exactly 1024 (or the Original if smaller) satisfies both. Note that spec §5.3 still says "Analysis and model input come from the Proxy", which contradicts §4.6 ("the display Proxy is never the model input"). Android follows §4.6. The §5.3 sentence should be corrected.

## 3. Test results (`./gradlew test`, JVM + Robolectric, JDK 25)

**122 tests, 0 failures, 0 skipped.** Run with the golden set from the main checkout.

| Module | Task | Tests | Notes |
|---|---|---|---|
| core-session | `test` | 24 | EditSession 8, UndoStack 4, serialization 6 (golden JSON), recovery + fingerprint 6 |
| core-render | `test` | 43 | RenderScheduler 13, LUT unit 10, golden 4, shader source 6, shader-math twin 2, tiling/packing/pass plan 8 |
| core-model | `test` | 17 | preprocessing golden 3, fusion/guardrail 5, AutoEnhancer 5, basis versioning 4 |
| core-decode | `testDebugUnitTest` | 12 | sizing 6 (JVM), ImageDecoder 6 (Robolectric API 34, native graphics) |
| core-export | `testDebugUnitTest` | 19 | save flow 9 (JVM fake), ContentResolver 3 (Robolectric API 29), ExportCoordinator 7 |
| app | `testDebugUnitTest` | 7 | SavedStateHandle restore 5, AutoStatus 2 |

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

### Failing-before evidence and mutation checks

| Change | Evidence |
|---|---|
| Codex M2 finding 4 (basis by version) | A regression test written against the old API failed. With a "v2" basis installed and an edit saved with "v1", `lutFor()` returned a LUT instead of refusing: "Expected an exception to be thrown, but was completed successfully". |
| Scheduler `cancel(through)` | Clearing the pending slot unconditionally fails "cancel through revision 1 leaves revision 2 alive". |
| Two-pass shader | Clamping between passes in `main()` fails two shader tests: "single O4 clamp in main expected:<1> but was:<3>" and "intermediate must not be clamped/quantised". |
| Decoder colour conversion | Removing `setTargetColorSpace` and the sRGB check fails the P3 test: got `[204, 77, 51]` (P3 values passed through), expected `[221, 64, 37]`. |
| Export not cancellable during encode | Replacing `withContext(NonCancellable)` around save fails the "cancel once encoding has started" test: the state became Cancelled although the asset had been written. |

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
| MediaStore and JPEG on device | **PENDING.** Robolectric checks the ContentResolver contract only | Instrumented save test, original-unchanged hash test (§10), `Bitmap.compress` output (SOI/EOI, sRGB ICC, quality 92) |

## 6. Deliberate deferrals (M3 unless noted)

- **App wiring:**
  - Photo Picker and develop-on-select;
  - a GL thread dispatcher shared by `RenderScheduler` and `ExportCoordinator`;
  - building `LutPassPlan` from the committed state (Auto from `autoLutForRendering`, Look from the look-book);
  - the Save copy UI;
  - writing the recovery snapshot on every commit;
  - adaptive layout, haptics and full accessibility.
- **Export metadata:** sRGB ICC embedding, EXIF orientation 1, safe-metadata copy and the location setting (U7).
- **Spatial operators (O3):** grain, vignette and local contrast. `TilePlan` has no apron; O3 must extend it.
- **Other modules and tooling:**
  - `core-looks` (look-book, sha256-checked Look LUTs, ID migrations);
  - the `feature-editor` module;
  - Hilt;
  - the `contracts/` directory (M2.1, shared with iOS).
- **Compose UI tests and instrumented tests.** None in M2, because no device or emulator was used.

## 7. Notes

- Compose BOM is pinned to `2026.06.01` and lifecycle to `2.10.0`. The newer releases require `compileSdk 37`.
- `org.gradle.vfs.watch=false`: file-system watching missed edits in this git worktree and reported stale `UP-TO-DATE` results.
- Reused from the M1 harness: the antialiased resize (`ImageUtil.kt`) and the GLES structure and shader (`GlLut.kt`). The CPU trilinear weights were changed to float64 to match NumPy exactly.
