# M2 — Android foundation

Branch: `m2/android-foundation` (from `m1/spec-ux-lut-feasibility` @ `c6b1f98`)
Project: `android/` (new Gradle multi-module project; `Lightly/`, `experiments/` and other `docs/` are untouched)

This milestone builds the Android modules from spec §8 that can be verified **without a phone**: the edit model, the latest-wins render scheduler, the CPU reference for the LUT maths, model preprocessing/fusion, the MediaStore save flow, and a thin Compose shell. Everything was verified with JVM unit tests and Robolectric only. **No physical device or emulator was used in M2.** Every hardware-dependent claim below is marked **PENDING**.

## 1. Build and test

Toolchain: Gradle 9.7.1, AGP 9.4.1, Kotlin 2.4.20 (one Kotlin Gradle plugin for the JVM and Android modules), JDK 25 (Android Studio JBR) running the build, bytecode target 17. `compileSdk 36`, `minSdk 29` (U6), `targetSdk 36`.

```bash
cd android
echo "sdk.dir=$HOME/Library/Android/sdk" > local.properties   # once
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
| `core-session` | Kotlin/JVM | `EditState` v1 (§3) with init-time validation; `SourceFingerprint` (sha256 of the first 64 KiB, byte size and pixel size); `UndoStack` (immutable, cursor, cap 50 dropping the oldest, redo cleared on commit); `EditSession` (one step per committed change, no-op changes are not steps, Look *replaces*, Reset is undoable, monotonic revision counter); `SessionJson` (explicit nulls and defaults, unknown keys rejected); `RecoverySnapshot` + `RecoverySnapshotStore` (atomic temp-then-move write; corrupt or fingerprint-mismatched snapshots are discarded). |
| `core-render` | Kotlin/JVM | `RenderScheduler` (§5.2: one in-flight slot plus one conflated pending slot, revisions issued under a lock, publish only if latest, not cancelled and session open, `cancel(through)` leaves newer revisions alone, `close()` drops everything). CPU reference LUT maths (§4.2): `Lut3D` (33³ RGBA float, red fastest, exact-grid trilinear, input clamp on every stage), strength blend toward identity, `LutComposition.bake`, `CpuLutRenderer` (single final clamp at encode). Test fixtures: golden loader (javax.imageio raw raster, no colour conversion), pixel diff, synthetic LUTs. |
| `core-model` | Kotlin/JVM | `CanonicalAnalysisInput` (§4.6 pinned antialiased bilinear resize to 256×256 NCHW, ported from LUTBench `ImageUtil.kt`; rejects a source with long edge < 1024 unless it is the full Original, so the Proxy can never be the model input); `BasisLuts.fuse`; the `endpoint-v1` guardrail; `AutoModel` interface; `AutoEnhancer` (input → model → fuse → guardrail, memoised per fingerprint and model version; `lutFor()` re-renders a stored `AutoResult` from its saved weights). |
| `core-export` | Android library | `SaveCopyExporter` (§5.4: insert with `IS_PENDING=1` → open the new row with `"w"` → encode **once** → close → `IS_PENDING=0`; on any failure the pending row is deleted; no retries; refuses a target equal to the source and does not delete it). `ContentResolverGateway` (real MediaStore), `BitmapJpegEncoder`, failure mapping to the §5.4 categories. |
| `app` | Android app | `EditorViewModel` (session in a `StateFlow`, written to `SavedStateHandle` as JSON on every commit along with compare state and category; the transient preview is never committed or persisted). `EditorScreen` is a thin Compose shell with a demo session, category chips, stop buttons, a strength slider (previews while dragging, commits on release), undo/redo/reset and a compare toggle. |

### Decisions taken while implementing

- **Two kinds of revision.** `EditState.revision` is the *commit* counter. It increases monotonically across the session, including after undo-then-commit, because it is tracked in `EditSession.lastIssuedRevision`. Undo and Redo move the cursor back to an existing snapshot and do not mint a new revision. The render scheduler issues its *own* strictly increasing request revisions, so latest-wins still holds when an undo returns to an older `EditState`. iOS should match this, or the contract should say otherwise.
- **The scheduler is preview-only.** An export must never be coalesced away or dropped by a later preview, so it gets its own single-flight path (M3).
- **CPU arithmetic mirrors NumPy.** Positions are float32 and corner weights float64 rounded to float32, as `float32 − int64` promotes in `ia3dlut.apply_lut_reference`. This is why the CPU path reproduces the golden references bit for bit.

## 3. Test results (`./gradlew test`, JVM + Robolectric)

**80 tests, 0 failures, 0 skipped.** Run with the golden set from the main checkout.

| Module | Task | Tests | Notes |
|---|---|---|---|
| core-session | `test` | 24 | EditSession 8, UndoStack 4, serialization 6 (incl. a golden JSON string for `EditState`), recovery store + fingerprint 6 |
| core-render | `test` | 27 | RenderScheduler 13, LUT unit 10, golden 4 (~80 s: one exhaustive 256³ sweep × 23 LUTs, plus 23 full-resolution renders) |
| core-model | `test` | 12 | preprocessing golden 3, fusion/guardrail 5, AutoEnhancer (fake model) 4 |
| core-export | `testDebugUnitTest` | 12 | 9 flow tests on a JVM fake gateway, 3 Robolectric (API 29) against a fake MediaStore provider |
| app | `testDebugUnitTest` | 5 | ViewModel recreated from SavedStateHandle values |

Measured against the 23 golden cases in `experiments/lut3d/golden`:

| Check | Bound | Result |
|---|---|---|
| CPU LUT apply: `fused_lut.f32` on `source.png` vs `reference.png` | ≤ 1/255 | **0/255 on all 23** (bit-exact) |
| Canonical analysis input vs `input256.f32` | ≤ 1e-5 | max **6.6e-7** (1620×1080 to 3000×4514 sources) |
| Fusion of research basis with `weights_deploy` vs `fused_lut.f32` | ≤ 1e-5 | max **2.4e-7** |
| Golden Auto LUTs exercise out-of-range entries | min < 0, max > 1 | −0.143 … 1.475 |
| Baked vs two-stage, real photo (a1629, Auto 0.75 + Look 0.8) | ≤ 2/255 | **1/255** |
| Baked vs two-stage, every 8-bit input, every golden Auto LUT + strong Look | ≤ 2/255 | **21/23 pass; a1629 3/255, portrait_deep_03 6/255** (see §4) |

The scheduler regression test for the iOS defect (`cancel through revision 1 leaves revision 2 alive and published`) was written before the implementation. It was then checked by mutation: making `cancel()` clear the pending slot unconditionally makes it fail.

## 4. Finding: the §4.2 bake tolerance does not hold for every Auto LUT

Spec §4.1 allows O1+O2 to be baked into one 33³ LUT, `B(g) = L_look(clamp(L_auto(g)))`, with a tolerance of max ≤ 2/255 against two-stage rendering. It cites a measured max of 1.64/255. That figure came from 25,000 random inputs on the **first 8** golden LUTs.

Swept over all 256³ 8-bit inputs with the same strong synthetic Look (port of `look_lut()`), the encoded error is ≤ 2/255 for 21 of 23 golden Auto LUTs, but:

| Golden case | Max float error | Max encoded error | 8-bit colours > 2/255 |
|---|---|---|---|
| portrait_deep_03 (LUT max 1.475) | 5.6/255 | **6/255** | 519 |
| a1629 (LUT range −0.14…1.35) | 2.7/255 | **3/255** | 6 |

The cause is structural, not a porting error. When Auto overshoots 1 inside a grid cell, the clamp kink falls between grid points, and a single trilinear LUT cannot represent it. The test pins these two cases explicitly. It fails if either starts passing, if either error grows, or if any other LUT starts violating, so the issue cannot go stale silently.

**Contract decision needed (not taken here):** either (a) render O1 and O2 as two GPU stages on device (two 3D-texture fetches, which is cheap; baking stays available where the tolerance holds, e.g. thumbnails), or (b) revise the bake tolerance and state the input domain it is measured over. The recommendation is (a), because it removes the error rather than accepting it. Whichever is chosen must also be applied on iOS.

## 5. PENDING on physical hardware (phones disconnected — nothing here is claimed)

| Item | Status | What is needed |
|---|---|---|
| ONNX Runtime inference on Android | **PENDING.** Not implemented: `AutoModel` has only a fake. In M1, ORT raised SIGILL on the x86_64 emulator, and no phone has run it. | ORT-backed `AutoModel` (CPU/XNNPACK, fp32). Weight parity ≤ 1e-3 on golden `input256.f32`, and end-to-end Auto parity ≤ 2/255, on the Nothing SM7635 and moto edge 60 |
| GL LUT application on Adreno / Mali | **PENDING.** No GLES renderer in this module yet. LUTBench `GlLut.kt` is within 1/255 on the emulator only | Port `GlLut.kt` into core-render (EGL thread as the scheduler's dispatcher, float32 3D texture, manual trilinear if `RGBA16F` filtering exceeds tolerance). Compare against `CpuLutRenderer` and golden references on both GPUs |
| Timings (decode proxy, preprocess, inference, preview render, 48 MP export) | **PENDING** | Release build on both phones |
| Memory (proxy, analysis input, 48 MP export peak ≤ 600 MB) | **PENDING** | Same |
| MediaStore save on a real device | **PENDING.** Robolectric checks the ContentResolver contract (columns, modes, cleanup), not scoped-storage behaviour, `IS_PENDING` visibility in Photos, or real disk-full errors | Instrumented test plus the original-unchanged hash test (§10) |
| `Bitmap.compress` JPEG output | **PENDING.** Wrapper only, not exercised | Device test: SOI/EOI, sRGB, quality 92 |

## 6. Deliberate deferrals (M3 unless noted)

- **GLES renderer, proxy decoder (`ImageDecoder` → sRGB), export tiler.** These are hardware-bound (see §5). The scheduler and the CPU oracle they plug into are ready.
- **Export single-flight path** (separate from the preview scheduler), cancel-until-encode, and metadata (sRGB ICC, EXIF orientation 1, safe-metadata copy, location setting U7).
- **`core-looks`** (look-book JSON, sha256-checked LUT assets, ID migration table) and the `feature-editor` module. For now the editor ViewModel and screen live in `:app`.
- **App wiring:** Photo Picker, develop-on-select, the render scheduler driven from `uiState`, Save copy UI, writing the recovery snapshot on every commit (the store exists in core-session; the app does not call it yet), the "Continue editing?" UX (M4), adaptive layout (WindowSizeClass / FoldingFeature), stepped-slider haptics and full accessibility.
- **Hilt.** Construction is manual while the graph is this small.
- **`contracts/` directory** (golden set and schema moved out of `experiments/`): spec M2.1, shared with iOS.
- **Compose UI tests and instrumented tests.** None in M2, because no device or emulator was used.

## 7. Notes

- Compose BOM is pinned to `2026.06.01` and lifecycle to `2.10.0`. The newer cached releases (BOM `2026.09.00`, lifecycle `2.11.0`) require `compileSdk 37`, and M2 fixes `compileSdk` at 36. Raise them together.
- `org.gradle.vfs.watch=false`: Gradle file-system watching missed source edits in this git worktree and reported stale `UP-TO-DATE` test results.
- Reused from the M1 harness: the antialiased resize (`ImageUtil.kt`), the fusion layout and the CPU trilinear structure. Weights math was changed to float64 to match NumPy exactly.
