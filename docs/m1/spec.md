# Lightly — Product & Architecture Specification (M1)

Status: **Draft for Codex review — Milestone 1**
Branch: `m1/spec-ux-lut-feasibility`
Supersedes: any conflicting section of `docs/lightly_product_technical_spec.md`, `docs/lightly_product_technical_spec_v1.1.md` and `docs/phase-2-deferred.md` (see §13 for the explicit conflict list).

Companion deliverables:
- UX prototype: `docs/m1/prototype/` (interactive HTML + screenshots)
- Model feasibility: `docs/m1/lut-feasibility.md`, experiment code in `experiments/lut3d/`
- Licensing: `docs/m1/licensing.md`
- Audit of the current iOS code: §12 of this document

---

## 1. Fixed product decisions

| # | Decision | Consequence for this spec |
|---|---|---|
| D1 | iOS and Android ship together, with adaptive layouts for phone, tablet and foldable | One shared contract (recipe, rendering, look-book, model) and two native implementations validated against the same golden images |
| D2 | Selecting a photo develops it automatically, on device | No Develop button. Auto runs as soon as the photo is decoded |
| D3 | Enhancement uses Image-Adaptive 3D LUT, subject to validation | Experiment in `experiments/lut3d/`. **The pretrained weights cannot ship as-is** (licence and quality, see feasibility report). The architecture and pipeline are retained |
| D4 | The photo stays visible while editing | Controls are a bottom panel (≤ 35% of height) on compact screens and a side panel on wide screens. No modal sheet over the photo |
| D5 | A small set of top-level Look categories | Built from the curated preset collection. Categories, labels and membership are catalog data (`experiments/presets/look_pack/catalog.json`), not code; the current five labels (Natural, Warm, Cool, Film, Mono) are provisional |
| D6 | Each category has a stepped slider. Each stop is a curated preset that previews immediately | Stop 0 is the base with no Look: it reads "Auto" when an Auto correction is applied and "Original" when none is (Auto unavailable, not bundled, or strength 0); every other stop is one preset, labelled with its name. The slider selects a preset; it is never an intensity control. Stops are in browse order: the shortest visual path from Auto through the category's presets (catalog `orderMethod`), or a recorded human override |
| D7 | Auto is the starting result. Looks apply above it. Changing the Look replaces the previous one | `output = Look(Auto(Original))`, with at most one Look |
| D8 | Save creates a new JPEG and never modifies the original | Add-only library access. No "replace" or "revert" path exists |
| D9 | The JPEG is encoded once, at export | Previews are GPU textures or bitmaps and are never encoded |
| D10 | Compare and session Undo stay simple and accessible | Compare works by hold and by toggle. Undo/Redo is linear and session-scoped, one step per committed change |

### 1.1 Auto development objective

The reference is Arsenal 2's **Deep Color** (https://witharsenal.com/). Publicly, Arsenal describes it as a neural network that produces "a set of adjustments custom to each photo" and is "not a look or a filter", with a 0–100% strength control. Arsenal does not publish whether its adjustments are global or local.

Lightly's Auto must produce a considered, image-specific developed result that holds up without any Look. **Stronger saturation or brightness alone is not improvement.** Acceptance criteria per scene class are defined in `docs/m1/lut-feasibility.md` §5, and Auto is evaluated against them:

| Scene | Must preserve | Must correct |
|---|---|---|
| Sunset / golden hour | Warmth: warm-pixel chroma ratio 0.95–1.10, hue shift ≤ 4° | Crushed foreground, if present |
| Skin (all tones) | Natural hue (≤ 4°) and chroma (ratio ≤ 1.12) | Under-exposure of the face |
| Night | Mood: median L* lift ≤ 3, no new black clipping | Blocked shadows near light sources (mildly) |
| Backlit subject | Highlight detail (no new clipping) | Subject lightness (raise it; a global darkening is a failure) |
| Already good | Overall look: mean ΔE00 ≤ 3 | Nothing material |

Our test set is Unsplash photos, which are already processed, unlike Arsenal's own captures (RAW/stacked). Comparing directly against Arsenal output needs side-by-side captures; that is open question U9.

---

## 2. Primary flow

```
Select photo ──► Decode proxy ──► Auto develop ──► Ready (Auto baseline)
                    │                 │                 │
                    │                 └─ fail ─► "Couldn't enhance" [Retry] [Continue with original]
                    └─ fail ─► "Couldn't open this photo" [Choose another]

Ready ──► pick category ──► move stepped slider (each stop previews immediately)
      ──► optional Strength (active Look only)
      ──► Compare (hold photo, or Compare toggle)
      ──► Undo / Redo / Reset to Auto
      ──► Save copy ──► Saving… ──► "Saved as a new photo. Original unchanged." [View]
                                └─► failure ─► specific message [Retry]
```

1. **Select.** Uses the system picker (iOS `PHPickerViewController`/`PhotosPicker`; Android Photo Picker, via the Play-services backport below API 33). This needs no full-library permission. The app receives the asset identifier or URI and reads it.
2. **Decode a proxy.** Decode at display resolution first (ImageIO thumbnail / `ImageDecoder` target size), so the photo appears in under ~300 ms even for 48 MP assets. Full resolution is decoded only at export.
3. **Auto develop.** Run the model on the canonical 256×256 analysis input (§4.6, independent of screen size), fuse the LUT, apply it to the proxy, and show the result. The photo stays visible throughout, with a subtle progress indicator and a Cancel action.
4. **Looks.** Pick a category tab and move the stepped slider. Every stop change renders a preview immediately. A Look commits to history when the slider settles (pointer up, or a keyboard/accessibility increment). Changing category alone does not change the Look.
5. **Strength.** An optional secondary control, 0–100%, default 100%, shown only when a Look other than Auto is active. It commits on release.
6. **Compare.** Press and hold the photo to see the Original. The Compare toggle (`aria-pressed` / `accessibilityAddTraits(.isSelected)`) does the same for people who cannot hold. Compare always shows the Original, not the Auto result. A secondary "Compare to Auto" is out of scope for V1.
7. **Save copy.** Render at full resolution once, encode once as JPEG, and add the result as a **new** asset. Show success with a "View" action. The session stays open, so the user can keep editing and save again.

---

## 3. Image states — vocabulary used everywhere

| Term | Definition | Lives where | Persisted? |
|---|---|---|---|
| **Original** | The user's asset as decoded, oriented and colour-converted. Never written to | Photo library / content URI | Never modified |
| **Proxy** | A display-sized decode of the Original (long edge ≤ the screen's longest pixel dimension, capped at 2732 px). Input to every preview render | Memory (GPU texture or bitmap) | No |
| **Auto correction** | `AutoResult {modelId, modelVersion, weights[3], guardrail, strength}`. Deterministic for a given Original and model version | Edit state | Yes (in the session snapshot) |
| **Creative Look** | `LookRef {lookId, lookVersion, strength}` or `null`. At most one | Edit state | Yes |
| **Transient preview** | What is on screen while the slider is moving (hover, drag or scrub). Rendered from the Proxy. **Not** in Undo history | View model only | No |
| **Committed edit** | An immutable `EditState` snapshot pushed to the undo stack when a change settles | Undo stack | Yes (session snapshot) |
| **Export** | A full-resolution render of exactly one committed `EditState`, encoded once | New library asset | Yes (new asset) |

**Invariant P=E.** Preview and export both evaluate `render(EditState, source)` through the same operator chain. They differ only in source resolution and output sink. Every operator is specified in resolution-independent units, so a preview at proxy scale matches the export at full scale. Spatial operators (grain, vignette) are defined in normalised image coordinates and are seeded from the asset identity, so the grain pattern is stable across preview and export (scale-dependent grain is a known defect today; see §12).

**Invariant R (replace).** `EditState.look` is a single optional value. Selecting another Look replaces it. Preview of a candidate Look is computed as `render(committed.with(look: candidate))`, never as `committed.look ∘ candidate`. This fixes the current preview≠commit defect (§12, e).

```text
EditState {
  schema: 2   // 2: look.lookVersion is the Look pack's version string (an Int in schema 1)
  source: { assetId, fingerprint (sha256 of first 64 KiB + byte size + pixel size), orientation }
  auto:   { modelId: "ia3dlut", modelVersion, weights: [f32;3], guardrail: "endpoint-v1"|null, strength: 0…1 }
  look:   { lookId, lookVersion: string (Look pack, changes with the LUT), strength: 0…1 } | null
  revision: u64   // monotonically increasing within a session
}
```

Undo stack: `[EditState]` with a cursor. One step is pushed per committed Look change, Strength release or Reset. Redo is cleared on a new commit. The stack is capped at 50 entries, dropping the oldest. Undo/Redo is session-scoped and is not persisted after the user leaves the photo, except through the recovery snapshot (§5.6).

---

## 4. Rendering contract v1 (shared, versioned)

A single document, `contracts/rendering-v1.md`, plus machine-readable JSON, both owned jointly by iOS and Android. It is introduced in M2. This section is its normative outline.

### 4.1 Operator order (fixed)

```
O0 decode + EXIF orientation + convert to sRGB (relative colorimetric), 8- or 16-bit
O0b (proposed, U10) Auto local exposure: smooth low-res gain map, applied in linear light
O1 Auto LUT           (3D LUT, sRGB-encoded domain)          strength-blended toward identity
O2 Look LUT           (3D LUT, sRGB-encoded domain)          strength-blended toward identity
O3 Look spatial ops   (V1: local contrast [Clarity/Texture], vignette, grain; radii and positions in units of
                      the image's long edge, so preview and export match; local contrast is EXPERIMENTAL)
O4 clamp [0,1] → encode sRGB 8-bit → JPEG (export only)
```

- **O1 and O2 are applied as two LUT passes** (revised). Baking them into one 33³ LUT (`B(g) = L_look(clamp(L_auto(g)))`) is **not allowed by default**.
  - The earlier figure of 1.64/255 came from random samples on 8 Auto LUTs and understated the error.
  - An exhaustive check (64³ colours × all 23 golden Auto LUTs with a strong Look) gives baked vs two-stage up to **6/255** (`portrait_deep_03`, whose Auto output reaches 1.475) and 3/255 (`a1629`). That exceeds the 2/255 tolerance.
  - Found by the Android foundation tests and reproduced in `experiments/lut3d/reference/test_lut_composition_exhaustive.py`.
  - A second LUT pass is one extra texture lookup per pixel.
  - An implementation may bake a specific Auto+Look pair only if that pair passes the exhaustive check.
- **Decision (Codex M1 finding 4):** Clarity and Texture are **included** in the V1 Look format as one O3 operator, `localContrast {clarity, texture}`.
  - Why: 81% of the collection uses Clarity.
  - It stays *experimental*: a Look that uses it ships only if its Lightroom-export validation passes (§4.4). Otherwise the Look is excluded, not silently degraded.
  - The provisional shortlist prefers presets with |Clarity| ≤ 15 to limit exposure to this risk.
- Dehaze, sharpening and noise reduction are not in V1 Looks. The importer reports them per preset (§4.5).
- Vignette and grain are O3 parameters. They are not implemented in the experimental renderer yet, so presets that use them count as *coverage incomplete*.

### 4.2 LUT representation

- Dimension 33. Values are float32 RGBA. Memory order is red fastest: `index = r + 33·g + 33²·b`, which matches Core Image `CIColorCube` and GL 3D-texture uploads.
- Domain and codomain are **sRGB-encoded** (gamma) values in [0,1]. That is the space the model was trained in, and it makes LUT authoring match Lightroom's display-referred export.
- Interpolation is exact-grid trilinear: `pos = v·(N−1)`. The upstream `1.0001/(N−1)` bin-size quirk is **not** reproduced; its maximum effect was measured at 0.02/255.
- **Boundary rule (single rule, baked or not):** every LUT stage clamps its *input* to [0,1] (clamp-to-edge, as GPU texture addressing does). LUT *entries* may be outside [0,1], so a stage's output may be out of range, and the next stage clamps it on input. The final output is clamped once at O4. No extrapolation beyond the cube is defined or allowed.
  - Consequence: Auto's out-of-range highlights (values > 1) are clipped before the Look sees them. This is an accepted V1 limitation.
  - Tested with values < 0 and > 1 (`test_lut_composition.py`, `test_lut_composition_exhaustive.py`).
- Strength blend: `L_s = I + s·(L − I)`, where `I` is the exact identity LUT.

### 4.3 Colour management

- **Working/LUT space is sRGB.** Wide-gamut originals (Display P3, Adobe RGB) are converted to sRGB before O1. Measured on the test set, 2.6% (P3 landscape) and 3.9% (Adobe RGB street) of pixels fall outside sRGB and are clipped by this conversion.
- **Export is sRGB JPEG** with an embedded sRGB ICC profile. This is universally safe and matches the LUT domain. A wide-gamut export path (apply LUTs to extended-range values) is deferred; see Unresolved U4.
- HDR gain maps (iPhone HEIC/JPEG, Ultra HDR on Android) are **dropped** in V1 and the export is SDR. This must be stated in the Save copy footnote. It is deferred.
- Every platform path declares its colour space explicitly. Default/device RGB is banned (the current analyser uses `DeviceRGB`; see §12).

### 4.4 Validation

- **Golden set:** `experiments/lut3d/golden/` now; it moves to `contracts/golden/` in M2. It contains a source PNG, the expected 256-input tensor, the fused LUT, and the reference output per image.
- **Per-platform test:** render the golden source with the golden LUT and compare to the reference. Pass when max |Δ| ≤ 2/255 and the share of pixels with |Δ| > 1 is ≤ 1%. Numbers are confirmed from harness results in the feasibility report.
- **Cross-platform test:** the iOS and Android exports of the same `EditState` must satisfy mean CIEDE2000 ≤ 0.5 and p99 ≤ 2.0.
- **Model parity:** weights within 1e-3 of the reference on golden `input256.f32`.
- **End-to-end Auto parity** (decode → canonical analysis input → model → fuse → apply) is measured as **max 8-bit output difference vs the golden reference ≤ 2/255** on every golden image, and is reported together with max |Δw|.
  - Justification from measurements: with the pinned antialiased resize, varying the intermediate size (512–2732 px) or adding ±1 LSB decoder noise changed weights by ≤ 0.019, which is ≤ 1/255 of output (`experiments/lut3d/report/analysis_input_sensitivity.json`).
  - A non-pinned resampler (vImage Lanczos) moved weights by 0.145. A non-antialiased resize moved them by 0.43, which is 14/255.
  - The weight bound is therefore set at 0.05 (≈ 1.6/255 at the measured slope). It is a diagnostic; the output bound is the acceptance criterion.
- Tests that only assert dimensions or non-nil do not count as filter tests.

### 4.5 Looks and presets

- A V1 Look is `{id, version, category, stopIndex, displayName, lut33: file+sha256, vignette?, grain?, sourceProvenance}`.
- Both apps load Looks from one **Look pack** (`manifest.json` + `luts/<lookId>.f32`, built by `experiments/presets/look_pack/build_look_pack.py`). The ID depends only on the preset, never on category or stop, so relabelling or reordering the catalog does not break saved edits. Each Look records its LUT source (`lightroom-hald` or `lr-model-approximation`), the operators its LUT omits or only approximates globally, and two separate validations: `globalColour` and `fullRecipe` (pack format 2). Its `status` is `approximate`, `global-colour-validated` or `validated`, promoted only by evidence about the shipped LUT. Approximate colour, or colour with missing effects, is never reported as a finished conversion. Formula-generated Looks are test fixtures only and never ship as content.
- Looks are **authored offline** from Lightroom-style recipes and compiled into LUTs by a desktop tool. That tool reports every unsupported parameter explicitly per preset (`unsupported: ["Texture", "ParametricCurve*", …]`), and a preset with unsupported parameters cannot be marked converted. Acceptance against Lightroom reference exports is M4.
- **Saved edits (EditState schema 2):** `lookVersion` is the pack's version string. A schema-1 edit is migrated to schema 2 with `lookVersion = "legacy-v1-<n>"`, not dropped. A saved Look whose ID is missing from the pack is *unavailable*; one whose version differs is *changed* and is not rendered until the user chooses "Use current version", which is an undoable step. No other Look is ever substituted. The shared fixtures and rules are in `shared/fixtures/edit-state/`.
- IDs are stable. Renames go through an explicit migration table `{oldId → newId}`. Fuzzy, prefix or substring lookup is forbidden. An unknown ID becomes "Look unavailable" in the UI and falls back to Auto, with a visible notice.
- **Provenance is recorded per Look** (`sourceProvenance`).
  - Distribution terms are tracked separately in `docs/m1/licensing.md`.
  - They are not part of engineering acceptance.

### 4.6 Model contract (`ia3dlut` family)

- **Canonical analysis input (Codex M1 finding 2): independent of screen size.**
  - Source: the decoded, oriented, sRGB-converted frame decoded to a **1024 px long edge** (or the original size if smaller). Both platforms use this size. The sensitivity measurements show any long edge ≥ 512 gives ≤ 1/255, but one fixed size keeps iOS and Android identical.
  - Transform: resize the whole frame (aspect ignored) to 256×256 with the **pinned antialiased bilinear resize**. Use the exact algorithm of `torch.nn.functional.interpolate(..., mode="bilinear", antialias=True, align_corners=False)`, written out in the contract as pseudo-code with golden tensors.
  - Result: float32 `[1,3,256,256]`, RGB, sRGB-encoded [0,1], no mean/std.
  - The display **Proxy is never the model input**, so a phone and a tablet produce the same Auto result for the same photo (within the §4.4 end-to-end tolerance).
  - Ported implementations measured so far: iOS CPU port matches golden tensors to 2e-6 on device; Android Kotlin port to 2.4e-7, on an emulator only.
- **Output:** `weights[3]`, raw linear.
- **Fusion:** `L = Σ wᵢ·Bᵢ`, using basis LUT file `basis_luts_f32.bin` with a sha256.
- **Guardrail (experimental, M1):** endpoint renormalisation (see feasibility report). It is versioned as part of `AutoResult` so old edits re-render identically.
- **Precision:** fp32 Core ML / ONNX. fp16 Core ML on CPU drifted 7/255 in the experiment, and the 1.1 MB size saving is not worth that.
- `modelVersion` changes whenever weights, basis LUTs or preprocessing change. Saved `EditState`s keep their weights, so re-rendering an old session never re-runs a different model silently.

---

## 5. Lifecycle: loading, cancellation, failure, retry, export, leaving

### 5.1 Session state machine

```
Empty ─select─► Loading(asset) ─proxy ok─► Developing ─ok─► Ready(EditState)
   ▲               │fail                       │fail             │
   │               ▼                           ▼                 ├─ edit ─► Ready(revision+1)
   │          LoadFailed[Choose another]   DevelopFailed          ├─ save ─► Exporting ─► Ready + SavedBanner
   │                                       [Retry][Use original]  │                    └► Ready + SaveFailed[Retry]
   └──────────── leave (confirm if dirty) ◄────────────────────────┘
```

`Use original` gives `Ready` with `auto.strength = 0` and a banner saying "Auto enhancement unavailable". Looks still work, applied on the Original.

### 5.2 Concurrency: bounded work, latest request wins

- **One render scheduler per session**, on its own serial executor (iOS actor; Android single-thread dispatcher that owns the GL context).
- Requests carry `(sessionId, requestId, kind: preview|export)`. `requestId` is issued by the scheduler and increases on every request; it is **not** `EditState.revision`, which counts commits (after Undo, an older EditState can be the newest request). The scheduler has **one in-flight slot and one pending slot**. A new preview request replaces the pending one (coalescing), so the queue never grows during a slider drag.
- A result is published only if `result.requestId == latestRequestId` and `sessionId` matches. Otherwise it is dropped. This also covers Reset, Undo, closing Looks, and switching photo.
- Switching photo or leaving cancels the session's tasks cooperatively (Swift `Task` cancellation / coroutine `Job`). GPU work already submitted finishes, but its result is discarded.
- The model runs at most once per Original and model version, and its result is memoised by source fingerprint.
- **Thumbnails** (category and stop previews) are keyed by `(sourceFingerprint, editBase revision, lookId, lookVersion, size)`, never by dimensions alone. This fixes the cross-photo cache reuse (§12, d). They are rendered from a 256-px proxy of the current Auto result, so a stop thumbnail shows exactly what selecting it produces.

### 5.3 Large assets and memory

- Preview never touches the full-resolution image.
- Analysis and model input come from a separate **analysis decode** (§4.6), never from the display Proxy, so memory is O(1024² px) regardless of screen.
- Export renders full resolution in tiles where needed (Core Image handles tiling internally; Android renders FBO tiles of ≤ 4096² and streams them to the encoder bitmap).
- Peak export budget targets: ≤ 600 MB for 48 MP on iOS 6 GB-RAM devices, and ≤ 600 MB on Android 8 GB devices. Measured numbers are in the feasibility report.
- Assets above 100 MP or with unsupported formats are rejected up front with a specific message.

### 5.4 Export (Save copy)

1. Snapshot the committed `EditState` at tap time. A Transient preview is not exported. If the user is mid-drag, the export waits for the settle commit.
2. Decode the Original at full resolution, oriented, as sRGB.
3. Render with the same operator chain.
4. Encode **once** as JPEG (quality 0.92, sRGB ICC, EXIF orientation = 1). Copy safe metadata: capture date, camera make/model, lens. Location is copied only if the user setting allows it (default on, matching the system behaviour of other editors; to be confirmed, see U7).
5. Write a **new** asset. iOS: `PHAssetCreationRequest` with add-only authorisation (`.addOnly`). Android (minimum API 29; see U6 and Codex M1 finding 8): `MediaStore.Images` insert with `IS_PENDING=1`, write, then `IS_PENDING=0`. On failure, delete the pending row. `IS_PENDING` and scoped-storage inserts without `WRITE_EXTERNAL_STORAGE` exist only from API 29, so the V1 save path is defined for API 29+ only. The original URI is never opened for write.
6. Success: banner "Saved as a new photo. Original unchanged." with a [View] action, announced politely to assistive tech.
7. Failure mapping:
   - permission denied → explain the setting
   - out of storage → "Free up space and retry"
   - original no longer available (e.g. iCloud asset not downloadable) → "Couldn't load full-resolution photo"
   - render failure → generic message with Retry
   Each is announced assertively. The edit state is kept.
8. Cancel is available until the encode starts. The encode and write are not cancellable, to avoid partial assets. On Android a pending row is cleaned up on failure.

### 5.5 Leaving an unfinished session

"Dirty" means the current committed revision has not been saved since its last change.

- **Back or choosing another photo while dirty:** in-page dialog "Discard edits?", with the note "Your original isn't affected." Buttons: [Keep editing] (default) and [Discard].
- **Process death or system kill:** a recovery snapshot `{assetId, fingerprint, undoStack, cursor}` is written to app storage on every commit. It is tiny JSON with no pixels. On next launch the app offers "Continue editing <thumbnail>?" if the asset still exists and its fingerprint matches. Otherwise the snapshot is discarded silently. Full recovery UX is M4; M3 must at least survive configuration changes.
- **Configuration change** (rotation, fold/unfold, window resize, multi-window, Dynamic Type change): the session must be preserved exactly, including category, stop, strength, undo stack, compare state and in-flight export. Android: `ViewModel` plus `SavedStateHandle`. iOS: state owned above the size-class-dependent view tree.

### 5.6 Retry

- DevelopFailed: [Retry] re-runs the model once; [Use original] continues.
- SaveFailed: [Retry] re-exports the same snapshot.
- LoadFailed: [Choose another].
- Retries are user-initiated only. There are no silent loops.

---

## 6. UX specification (summary; see prototype)

- **Compact phone (portrait):** photo on top, fitted. Bottom panel ≤ 35% of height containing: a category tab row, the stepped slider with the current stop's name, Strength (when relevant), and an action row (Undo, Redo, Compare, Save copy).
- **Phone landscape / wide / unfolded / tablet:** side panel 320–380 pt/dp wide, photo fills the remaining space. On a foldable in book posture, never place the photo across the hinge. Use the WindowManager `FoldingFeature` on Android; iPadOS has no hinge.
- **Stepped slider:** discrete detents with haptic ticks and a visible label for the current stop. All stop names are visible when they fit; otherwise only the current name is shown. Accessibility value: "Film, Portra, 2 of 5". Increment/decrement moves one stop.
- **Large text (AX3 / 200%):** the category row becomes a scrollable list or picker, the slider shows only the current stop name, the panel scrolls, and the photo keeps at least 40% of the height (phone portrait).
- **Screen readers:**
  - Photo label: "Photo, enhanced automatically, Film look Portra at 80 percent."
  - Compare is a toggle.
  - Save progress and results are announced.
  - Focus order: photo → categories → slider → strength → actions.
- **Motion:** crossfade ≤ 150 ms between previews; none when reduced motion is on.

---

## 7. Platform responsibilities

| Concern | Shared (contract + assets) | iOS | Android |
|---|---|---|---|
| EditState / undo | Schema, semantics, JSON | Swift value types, `@Observable` session | Kotlin data classes, `ViewModel` + `SavedStateHandle` |
| Model | ONNX/Core ML from one PyTorch source; preprocessing spec; golden tensors | Core ML (`.mlpackage`, fp32, all compute units) | ONNX Runtime Android (CPU/XNNPACK) — LiteRT is an alternative if ORT size matters |
| LUT apply | LUT format, interpolation, order, tolerance | Custom Metal kernel / `CIKernel` sampling a float 3D texture (measured: `CIColorCube*` stores the cube as clamped 8-bit → 5/255 error, fails tolerance) | OpenGL ES 3.0 offscreen EGL, 3D texture, shader per §8 |
| Looks | Look-book JSON, compiled LUTs, provenance | Bundle resources | APK assets |
| Picker | — | `PhotosPicker` | Photo Picker (+ backport) |
| Save | JPEG once, sRGB, metadata policy | `PHPhotoLibrary` add-only, `CGImageDestination` | `MediaStore` insert + `IS_PENDING`, `Bitmap.compress` or libjpeg-turbo |
| Adaptive layout | Breakpoints (compact < 600, medium 600–839, expanded ≥ 840 dp/pt) | Size classes + `ViewThatFits` | `WindowSizeClass` + `FoldingFeature` |

---

## 8. Proposed Android architecture

```
app/                  Compose UI, navigation, DI (Hilt)
feature-editor/       EditorScreen, LooksPanel, CompareToggle, SaveCopy UI; EditorViewModel (UDF, StateFlow)
core-session/         EditState, UndoStack, SessionRepository (recovery snapshot), revision/latest-wins
core-render/          RenderScheduler (single thread, conflated pending slot), GlRenderer (EGL, FBO tiles),
                      LutTexture, Proxy decoder (ImageDecoder → sRGB), export tiler
core-model/           AutoEnhancer: preprocessing (pinned resize), ORT session, fusion, guardrail
core-looks/           LookBook loader (JSON + LUT assets, sha256 checked), ID migrations
core-export/          JPEG encode once, MediaStore writer, metadata copy (androidx.exifinterface)
contracts/            (git submodule or shared dir) golden images + schema; consumed by instrumented tests
```

**Rendering strategy, chosen: OpenGL ES 3.0, offscreen.**
- Available on every device in the V1 support range (API 29+; GLES 3.0 itself is API 18+). It has 3D textures and float textures, renders off the UI thread with its own EGL context, and draws the result into a `SurfaceView`/`TextureView` for display, or reads back for export.
- **Rejected for V1:**
  - RenderEffect/AGSL: API 33+, no 3D textures, and tied to the View/Compose draw pass, so export would need a separate path and preview≠export becomes likely.
  - Vulkan: more capability than this pipeline needs, and much more code.
  - CPU (RenderScript is deprecated): too slow at 12–48 MP.
- **Precision:** use a float32 LUT with manual trilinear (`texelFetch`) when `GL_RGBA16F` hardware filtering exceeds tolerance. Hardware filtering uses reduced-precision weights on some GPUs. The harness measures both, and the choice is taken from the results (feasibility report).
- **Threading:** one render thread owns the EGL context. `RenderScheduler` exposes `suspend fun render(req): Result` with a conflated pending request. Results go back to `StateFlow` only if the revision matches.
- **Process death:** `SavedStateHandle` holds `assetUri` and a serialized undo stack (small). The proxy is re-decoded on restore.
- **Display:** a preview bitmap or `HardwareBuffer` shown in Compose `Image`, or a `SurfaceView` for zero-copy. Start with a bitmap (simpler) and measure.

**iOS equivalent.**
- `EditorSession` (`@Observable`, `@MainActor`) owns `EditState`, the undo stack and the revision.
- `RenderService` (actor) holds a `CIContext` (Metal, working space extended linear sRGB, output sRGB), a float-3D-texture LUT kernel, and the latest-wins slots.
- `AutoEnhancer` holds the Core ML model, loaded once per app.
- `LookBook`.
- `ExportService` (full-res decode, render, `CGImageDestination` JPEG, `PHAssetCreationRequest`).

---

## 9. Shared vs native code decision

**Recommendation: shared contract and golden data, native implementations.** No shared C++ or KMP core for V1.

- The per-pixel work is one LUT operation, plus vignette and grain, which is small enough to implement twice.
- Platform GPU APIs (Core Image/Metal vs GLES) are where the work is, and they are inherently native.
- A shared core adds build complexity on both platforms. It would also still need native GPU backends.
- Parity is enforced by the golden-image tests (§4.4), which is stronger than "same code" because it tests the actual outputs.

Revisit this if Looks grow beyond LUT + vignette + grain (local adjustments, masks).

---

## 10. Testing strategy (applies from M2)

- **Pixel tests per operator:** known input patches and the expected output (e.g. exposure +1 EV on 18% grey, a WB shift on a neutral patch, grain-strength variance at 0/50/100).
- **Golden image tests:** per platform against contract references, with tolerances from §4.4.
- **Concurrency tests:** inject a slow renderer; fire N rapid requests, then Reset; assert that only the last revision publishes and that nothing publishes after Reset or leave.
- **Thumbnail cache test:** two photos with identical dimensions → different thumbnails.
- **Preview=Export test:** render the proxy and the full-res export of the same `EditState`, downsample the export to proxy size, and assert ΔE within tolerance.
- **Original-unchanged test:** hash the original's bytes before and after Save (Photos sandbox / MediaStore test URI).
- **Snapshot (UI) baselines are never regenerated to make a change pass.** A baseline change needs a reviewed reason in the commit.

---

## 11. Proposed implementation sequence

| Step | Scope | Exit criteria |
|---|---|---|
| M1 (this) | Spec, prototype, model feasibility, licensing | Codex review sign-off; decisions U1–U8 answered |
| M2.1 | `contracts/` dir: rendering-v1 doc + JSON schema + golden set; Python reference renderer is canonical | Reference renderer reproduces golden references bit-exact |
| M2.2 | iOS: remove absolute path; explicit preset IDs + migration table; delete fuzzy lookup | Tests: unknown ID → explicit unavailable state |
| M2.3 | iOS: render scheduler (latest-wins, bounded), thumbnail key fix | Concurrency + cache tests above |
| M2.4 | iOS: colour pipeline explicit (decode → sRGB, render, export sRGB JPEG) | Golden + Preview=Export tests |
| M2.5 | iOS: operator fixes (exposure/WB units, whites/blacks, HSL, colour grading, RGB curves, curve blending, grain strength) — **only where still needed after the Look-as-LUT decision (U3)** | Per-operator pixel tests |
| M2.6 | Bounded analysis memory (proxy-only), large-asset rejection | 48 MP memory test on device |
| M3.1 | Shared look-book V1 (5 categories × 4–6 stops) compiled to LUTs with provenance | Importer reports unsupported params; no silent drops |
| M3.2 | iOS flow end-to-end (auto on select → stepped Looks → Compare → Undo → Save JPEG) | Acceptance list in brief |
| M3.3 | Android project + same flow | Same, plus cross-platform ΔE parity |
| M3.4 | Device measurements (development devices only: iPhone SE 3 / iPhone 11 Pro Max; Nothing SM7635 / moto edge 60) | Report attached |
| M4 | Curated launch collection vs Lightroom exports; crop; recovery; a11y polish; export polish; purchases | Separate reviews |

The enhancement model is retrained under a commercially clear licence in parallel with M2/M3 (see licensing doc). Until it lands, both apps integrate against the **contract**, using the research weights in debug builds only.

---

## 12. Audit of the current iOS implementation (verified from code)

The descriptions below were confirmed by reading the code. Comments and docs claiming completion were not relied on.

| Ref | Defect | Evidence |
|---|---|---|
| a | Exposure: the importer stores LR EV ÷ 5, but the renderer feeds the value as EV, so +1 EV renders as +0.2 EV. Temperature: the importer stores absolute Kelvin, but the renderer treats it as an offset from 6500 K (5000 K → targets 11500 K). The analyser's "tint" is B/G, i.e. the blue/yellow axis | `scripts/ingest_presets.py:134,146`; `RecipeRenderer.swift:88-105`; `HistogramAnalyser.swift:79-83`; `+Composition.swift:88` |
| b | HSL and colour grading are no-ops. Whites/blacks are never read. R/G/B curves are ignored. The master curve is used only when it has exactly 5 points. Positive highlights are clamped away. Contrast −1 renders flat grey | `RecipeRenderer.swift:111-161` |
| c | Curves switch on/off at intensity 0.05. Grain ignores amount/size/frequency, and is per-pixel (so preview ≠ export) | `+Composition.swift:61-64`; `RecipeRenderer.swift:179-194` |
| d | Thumbnail cache key `(sourceWidth, dimension)` is shared across photos | `LookThumbnailRenderer.swift:33,49-51`; `AppState.swift:79,89` |
| e | The preview stacks the candidate Look on the committed Look, while the commit replaces it. Thumbnails render on the Original without Develop | `EditorViewModel.swift:232-233`; `EditHistory.swift:100-104`; `LookThumbnailRenderer.swift:41` |
| f | Untracked detached Tasks write `renderedImage`. No cancellation and no revision checks | `EditorViewModel.swift:152-156,235-247,285-299` |
| g | The export render passes no output colour space. The exporter ignores its `colorSpace` parameter. The loader converts only when orientation ≠ 1. The analyser uses DeviceRGB | `PreviewRenderer.swift:44`; `ImageIOPhotoExporter.swift:22,33`; `PhotoLoading.swift:101-107` |
| h | Bidirectional `hasPrefix` lookup, plus a "gold" substring fallback | `BuiltInPresetCatalog.swift:56-65` |
| i | Absolute `/Users/...` path in shipping code and in the script | `BuiltInPresetCatalog.swift:97`; `scripts/ingest_presets.py:442-443` |
| j | Analysis runs at full resolution, about 45 B/px (≈ 2.2 GB at 48 MP). The loader decodes at full size | `AnalysingDeveloper.swift:31`; `HistogramAnalyser.swift:30-116` |
| + | Undo and Reset exist in the view model but no UI calls them | grep: no `.undo()` caller in Views |
| + | Develop is a manual button. The Looks sheet (0.62 detent) hides the photo | `EditorView.swift:168`; `LooksView` |
| + | 702 presets have the curve `["{"]`, garbage from lrtemplate parsing. Bare `except: pass` silently drops data | `ingest_presets.py:254-390` |
| + | No test asserts filter pixel values. 36 UI snapshot baselines exist; a previous session's allow-list shows the baselines being deleted and regenerated | `ios/Tests/LightlyTests/*`; `.claude/settings.local.json` |
| + | Preset provenance is third-party commercial packs ("WithLuke - Master Collection" etc.). Distribution terms are tracked in licensing.md, separately from engineering | `presets_photo.json` `originPath` |
| + | The export default is HEIC, which conflicts with D8 (JPEG) | `ExportSettings.swift:79-84` |

---

## 13. Conflicts with older documents (superseded)

- v1 §3 / §4.3 "Tap Develop": superseded by D2.
- v1 §4.4 "darkened photo behind overlay" and the 0.62 Looks sheet: superseded by D4.
- v1 §5 parametric-only Develop recipe: superseded by the LUT-based `AutoResult` (§3).
- v1 §6.8 11 categories and §7 thumbnail grid with continuous intensity: superseded by D5/D6. Strength remains as a secondary control.
- v1 §6.1 "50–100 curated presets" vs 3,157 bundled: V1 is about 25 Looks (5 × 4–6) with provenance.
- v1 §13 "Replace Editable Copy" and HEIC/PNG/TIFF options: superseded by D8 (new JPEG only).
- `phase-2-deferred.md` "P3 stays P3 through export": false today, and V1 policy is now sRGB export (§4.3).

---

## 14. Unresolved decisions (need product owner input — recommendations included)

| ID | Decision | Recommendation | Tradeoff |
|---|---|---|---|
| U1 | **Auto model source.** The pretrained weights are research-only (FiveK) and over-process already-processed phone photos | Retrain the same Apache-2.0 architecture on commercially licensed data whose inputs are real phone outputs. Until then, use research weights in debug builds only | Costs data licensing plus retoucher time, and training (GPU hours are cheap; data is the cost). The alternative is a non-ML parametric Auto, which is cheaper but loses image adaptivity |
| U2 | Default Auto strength and guardrail | Default 75% with the endpoint guardrail, pending the retrained model | Too strong reads as "filter"; too weak reads as "nothing happened" |
| U3 | Looks as compiled LUTs (+vignette/grain) vs a full parametric engine | Compiled LUTs | LUTs make preview=export and iOS/Android parity tractable. Clarity/texture-style local contrast Looks can't be expressed and need a later spatial operator |
| U4 | Export colour space | sRGB JPEG in V1 | Loses about 3% of out-of-gamut pixels on P3 originals. A P3 path needs extended-range LUT application and a separate validation pass |
| U5 | HDR gain-map handling | Drop it (SDR export), disclosed | Users with HDR photos see a flatter saved copy |
| U6 | Android minimum API | **29** (revised after Codex M1 finding 8). The save path (`IS_PENDING`, scoped-storage insert without a storage permission) exists only from API 29. The Photo Picker backport covers selection on 29–32 | Supporting 26–28 would need a second save path: `WRITE_EXTERNAL_STORAGE` permission, a direct file write plus a `MediaStore` insert, manual cleanup on failure, and a permission-denied UX. Current device-share figures should be checked before deciding; none are asserted here |
| U7 | Location metadata in saved copy | Keep (match the original) with a setting | Privacy expectations vs continuity |
| U8 | Launch categories/stops names | As in the prototype (illustrative) | Needs brand and curation input in M4 |
| U9 | Deep Color comparison method | Capture 20–30 scenes with an Arsenal 2 rig and a phone at the same time, then score both outputs on the §1.1 criteria plus a blind preference test | Needs hardware (~$200) and photographer time; without it, "matches Deep Color" can't be verified |
| U10 | Local exposure addition (one low-frequency gain-map pass before the LUT) | Include it in the retrained model's design: train the LUT with the gain map in the loop, and gate it on a dynamic-range measure | Adds one GPU pass (a per-pixel multiply by an upsampled gain map; not yet measured on device) and one more contract operator. Without it, backlit subjects can't be lifted by a global transform |

---

## M2 foundation status (branch `m2/foundation`)

| §12 ref | Status | Where |
|---|---|---|
| h | Fixed: exact ID lookup after an explicit `PresetIDMigrations` table (shipped empty; no real renames exist). Unknown IDs resolve to `.unavailable`; unavailable favourites are hidden, logged, and kept in storage | `PresetIDMigrations.swift`, `BuiltInPresetCatalog.resolvePreset(id:)`, `LooksViewModel.resolveFavourites()` |
| i | Fixed: catalogue loads only from a given bundle and throws `PresetCatalogLoadError`; the ingest script derives its output dir from its own location and requires the source dir | `BuiltInPresetCatalog.load(from:)`, `scripts/ingest_presets.py` |
| d | Fixed: thumbnail cache keyed on photo fingerprint (SHA-256 of encoded bytes + upright size), edit base, look id + recipe, output size; preview base keyed on fingerprint | `PhotoFingerprint.swift`, `LookThumbnailRenderer.swift`, `PreviewRenderer.swift` |
| f | Fixed: one in-flight + one pending render per photo, revisioned, published only if latest and the session is open; Reset/close/photo switch cancel. The editor now renders through `LUTEditSession` on the same `LatestWinsRenderScheduler`; the recipe `EditorViewModel` was removed | `PreviewRenderScheduler.swift`, `LUTEditSession.swift` |
| f (cont.) | Fixed after Codex review: `cancel(through:)` never cancels newer request IDs. Request IDs are per render request, not edit revisions (§5.2). (The per-run Develop gating lived in the recipe `EditorViewModel`, now removed; Auto runs once per editor in `LUTEditorViewModel`) | `PreviewRenderScheduler.swift`, `LUTEditorViewModel.swift` |
| g | Mostly fixed: decode → upright 8-bit sRGB (P3/Adobe RGB converted), sRGB render contexts, export converts to sRGB and embeds the sRGB profile, JPEG quality 0.92, no Device RGB in app code. **Open:** JPEG as the default format (D8) changes export-sheet snapshots and needs an approved re-record | `ColorPipeline.swift`, `PhotoLoading.swift`, `ImageIOPhotoExporter.swift`, `ExportSettings.swift` |
| j | Fixed for analysis: a 1024 px ImageIO proxy decode with orientation is analysed, never full resolution. The full-resolution decode for editing/export is unchanged | `AnalysisProxy.swift`, `AnalysingDeveloper.swift` |
| e | Preview half fixed in the LUT editor: a candidate Look previews as `render(committed.with(look: candidate))` (Invariant R) and settling always restores the committed render (Codex M2 finding 2). Thumbnail half not applicable: the stepped slider has no thumbnails; the recipe Looks sheet that had them is no longer reachable (see below) | `LUTEditSession.swift` |
| + Undo/Reset | Fixed: Undo and Reset to Auto are on screen. Reset clears only the Look, keeps Auto and is an undoable step (Codex M2 finding 3); history capped at 50 entries, oldest dropped, starting entry counted (Android `UndoStack` parity) | `LUTEditSession.swift`, `EditorPanelControls.swift` |
| + Develop/sheet | Fixed: selecting a photo develops it (no Develop button, D2); Looks are a bottom panel (≤ 35% of the height, scrolls at accessibility sizes) and the photo is never covered (D4) | `EditorView.swift` |

### iOS editor wired to the LUT pipeline

The editor screen runs the §2 flow on `LUTEditSession` through `LUTEditorViewModel`: photo → Auto → category + stepped slider (preview while dragging, commit on settle, Looks replace) → Compare (hold the photo, or the Compare toggle) → Undo → Reset to Auto → Save copy (tiled full-resolution render, one sRGB JPEG, added as a new asset; the original is not written). Covered by `LUTEditorViewModelTests` and `EditorFlowUITests.testEditAndSaveCopyEndToEnd` on the iPhone 17 simulator.

- **Auto:** no production model exists, so Auto is shown as explicitly unavailable (an on-screen notice, also read by VoiceOver) and blocks nothing. The research (FiveK-derived) weights are not bundled.
- **Looks:** DEBUG and release builds load the Look pack bundled at build time (`LookPackLoader`; `scripts/bundle_look_pack.sh`, run by the `LookPack` aggregate target, copies `experiments/presets/look_pack/out` — from `$LIGHTLY_LOOK_PACK_DIR`, this checkout, or the main checkout of a `.claude/worktrees/<name>` worktree — into `Lightly.app/LookPack/`). Categories, labels, stop order and preset names come from the manifest; no category is named in code. A Look whose LUT fails the size or sha256 check is dropped and logged; an unsupported or malformed manifest gives an empty book. Without a pack the editor says "No Looks are available in this build." While any offered Look is an `lr-model-approximation` or not `validated`, the editor says "Looks are approximate conversions, not yet checked against Lightroom." Formula LUTs exist only as test fixtures (`LookPackFixture`).
- **Deferred:** Strength control, Redo, the "View" action after saving (add-only access cannot read the new asset), Cancel while developing, the Retry/"Continue with original" develop-failure flow, moving the preview downscale off the main actor.
- **Not reachable, not removed:** the recipe Looks sheet (`LooksView`), recipe `ExportSheet` and recipe Develop engine (`AnalysingDeveloper`, `EditHistory`) still compile with their tests; porting or deleting them is a separate decision.
- **Unverified:** GPU/device performance and memory of the LUT preview and tiled export on real devices (simulator only so far), and spatial Look fidelity (grain, vignette, local contrast — not implemented in the LUT path).
