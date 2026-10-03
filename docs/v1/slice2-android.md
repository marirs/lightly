# Lightly 1.0, Android slice 2: editor session and Develop

Scope: the editor shell in every approved layout, one continuous session per photo, Develop with the real preset catalogue (format-3 pack), real preset rendering, Auto's unavailable and failed states, Compare, and Save copy of the committed recipe. Reference: the approved prototype `docs/ui/app/` (ff5c5ae, canonical at 0352972), reviewed under `docs/ui/REVIEW-RULES.md`. Slice 1 is in [slice1-android.md](slice1-android.md).

**Status: implemented and tested; no screen is recorded as exact-match verified.** Every captured comparison differs from its reference in at least the platform-drawn status bar (M7 of slice 1), and the items below list the other differences. Missing evidence is listed as unverified-pending.

## Commits

| Commit | What |
|---|---|
| 5b991d0 | `:core-develop` (pure JVM): develop.global port, 33³ bake, format-3 pack reader, lookVersion, portable random; parity tests |
| 47485ea | develop.spatial (noise reduction, clarity, texture, sharpening) and the preset's finishing vignette and grain, tiled with aprons; reference-vector tests |
| 1f912a1 | EditState schema 3 (edit recipe v1) with 1 → 2 → 3 migration; shared fixtures byte-exact |
| 80991d3 | Indexed pack reader (scanner + lazy entries), bake speed-ups; export takes any render plan |
| 490cbee | The slice-2 editor, Develop panel, ruler, favourites, Amount, Compare, Save copy, overlays; format-2 pack retired; format-3 bundling and APK check |
| f8a024c | Layout fixes from the emulator comparison (tab offset, ruler clip, split H panel, split V top bar, dialog row gap); timing logs |
| 7290012 | Editor screen tests on Robolectric |

## What was built

| Area | Where | Notes |
|---|---|---|
| Pack bundling | `app/build.gradle.kts` (`bundle<Variant>LookPack`, `verify<Variant>LookPack`) | Copies `shared/look-pack/out/manifest.json` (format 3) and `shared/contracts/rendering-v2.json` into `assets/lookpack/`. The build fails if the pack is missing, is not format 3, or was built for other model constants than the contract's. The built APK is checked again after packaging, next to the kept launcher-icon check. Format 2 (`experiments/presets/look_pack/out`, `LookPackLoader`, `LookBook`) is retired. |
| Pack reader | `core-develop/LookPack.kt` | One pass over the manifest text indexes categories and display fields; each preset's entry (recipe, coverage, validation) is parsed on first use. Strict: unknown recipe operators or parameters, another format, other model constants, or a HALD `globalOverride` (not implemented by this port; none exists) are refused. |
| develop.global | `core-develop/DevelopGlobal.kt`, `CurveTable.kt`, `ColourMath.kt`, `DevelopModel.kt` | Line-by-line port of `reference_model.develop_global` (G1–G11) in float64. Natural-spline curve tables, OKLab, constants read from the bundled contract and verified against `constantsSha256`. |
| Bake | `core-develop/LutBaker.kt`, `app/.../DevelopLibrary.kt` | 33³ contract grid, `[b][g][r]` red fastest, split by blue plane over 4 threads; LRU cache keyed by `lookVersion` (and dimension). |
| develop.spatial + finishing | `core-develop/DevelopRenderer.kt`, `Planes.kt`, `DevelopRenderPlan.kt` | Noise reduction, clarity, texture, sharpening; the preset's vignette and grain at absolute frame coordinates. Amount scales the LUT toward identity and every amount-like parameter (rendering-v2 §4.2). |
| EditState schema 3 | `core-session/EditTools.kt`, `EditState.kt`, `SavedEdits.kt`, `CanonicalNumbers.kt` | Every tool's section typed and range-checked, schema_check reader rules, canonical number text. Migration 1 → 2 → 3 (grain seed from `headSha256`). `EditSession.commit` records any whole-recipe change as one step. |
| Editor | `app/.../editor/EditorScreen.kt`, `DevelopPanel.kt`, `EditorOverlays.kt`, `EditorModels.kt` | Layout modes from the shell's fold/size decision: below (phones, folded), wide (tablet portrait, wrapped tabs, 600 dp content), side (tablet landscape, 360 dp panel + 84 dp rail), split V (unfolded portrait: photo left of the fold, panel + rail right, top bar split at the fold), split H (unfolded landscape: photo above the fold; top bar, panel and tools below). |
| Session | `app/.../editor/EditorViewModel.kt` | Opening photo (photo visible) → Develop → editor; generation checks after every suspension; latest-wins previews (`RenderScheduler`); SavedStateHandle restore without re-running Auto. |
| Save copy | `EditorViewModel.saveCopy`, `core-export` | The committed recipe, full resolution, 1024² tiles with the operators' apron; clarity's base computed once per frame; slice-1 metadata policy; Saving → Saved sheet (Share, Keep editing, Choose another photo); approved failure and storage dialogs. |

## Behaviour (as approved)

- **Ruler:** one tick per stop (stop 0 bold, every 10th longer, labels every 50), fixed needle, fade at both ends. Dragging previews the stop under the needle; release (after any fling, which always settles on a stop) commits ONE undo step, and nothing if the Look did not change. No interpolation, no arrows. Holding still for 450 ms while dragging enters Fine mode ("Fine" label; the ruler moves at a quarter of the finger's speed) until release. TalkBack: the ruler is an adjustable range whose value is the stop name.
- **Categories:** Favourites first (`n/5`), then the catalogue's nine categories with their counts; the applied preset's category carries the dot in tabs. Phones: one scrolling row, faded ends, the selected tab placed 120 dp from the screen edge (prototype `buildRulers`). Tablet portrait: wrapped rows. Side panels and the unfolded portrait fold: a list with a "Develop" title (no dot in the list, as in the prototype's CSS). Changing category never changes the Look.
- **Name row:** star, name (wraps), `stop / count`, "Amount N"; the star and Amount keep their space but are hidden at stop 0. Stop 0 reads "Auto" only when Auto is applied, otherwise "Original".
- **Applied line:** "Applied: <name>" when the applied preset is not in the browsed list.
- **Amount:** the text button opens the approved slider row (label, 90 dp track, value, Done). Drag previews; release is one undo step. Re-selecting the applied preset keeps its Amount; another preset takes the Amount last set for it in this session, else 100 (prototype `s.dev.amount`).
- **Favourites:** the star toggles the applied preset (shared with Preferences › Favourite presets); a sixth star shows the approved notice with Replace… and Not now; Replace opens the approved sheet.
- **Compare:** hold the compare button to see the original with the "Original" badge; for TalkBack the same button is a toggle.
- **Close / Back:** with unsaved changes, the approved "Leave without saving?" dialog; otherwise straight to Welcome.
- **Auto:** no shippable model (D1). Every photo opens with the approved "Automatic correction isn't available on this device. Presets still work." notice and the switch in its unavailable state; stop 0 reads "Original". The failure state (Retry / Continue with original) is implemented for a model that fails; nothing presents an unchanged photo as Auto. "Developing…" is shown only while a model actually runs, so this build never shows it.
- **Tools:** all seven in the dock or rail. Background, Edit, Effects, Watermark, Border (and Portrait) open a panel marked "Development stub (debug build only)" in debug builds; release builds keep them visible and inert.
- **Portrait visibility:** `PersonDetector` decides; the only implementation is `PendingPersonDetector` (D3: ML Kit / MediaPipe evaluation pending a device run, nothing downloaded). While pending, debug builds offer Portrait on every photo (its stub says why) and release builds leave it out.

## Rendering

| Path | What renders | Resolution |
|---|---|---|
| Committed preview | develop.global (33³), develop.spatial, finishing | display proxy, long edge ≤ 1600 px |
| Save copy | the same plan | full resolution, 1024² tiles |
| Drag preview (transient, never committed) | develop.global only, 17³ bake | half-size proxy |
| Compare | the decoded original | display proxy |

- **CPU, not GPU.** The GLES renderer (`:core-render-gl`) implements LUT passes only and has not been validated on a GPU; Develop also needs its spatial operators. Everything renders on the CPU (`DevelopRenderer`, 4 worker threads).
- **Approximations against reference_model (review evidence, not UI):**
  - clarity's Gaussian (σ ≈ 5.4 % of the long edge) is computed at low resolution with variance compensation, from the develop.global output before noise reduction (the reference blurs the noise-reduced lightness);
  - the four spatial operators share one OKLab pass; the reference returns to clipped sRGB between them, which differs only for colours that leave the gamut in between;
  - the drag preview omits develop.spatial and finishing and uses a 17³ bake on a half-size proxy; release re-renders the full recipe.
- **Per preset, recorded by the pack itself** (`approximated`, `unsupported`, `notApplied` in the manifest): all 2,591 presets are `approximate`; 164 are `incomplete` (local masks, creative profile stubs, lens vignetting, camera profiles, curve saturation refinement are not rendered). The app does not show these (no approved UI); they are listed in docs/v1/preset-pack.md.
- **Stages after effects/finishing** (geometry, adjust, remove, background, portrait, user effects, border, watermark) are carried in the recipe but not rendered: their tools are not implemented in this slice.

## Parity (shared/fixtures/look-pack, 40 presets)

| Check | Tolerance | Worst |
|---|---|---|
| 17³ bake vs golden float16 LUT, every node | 1e-3 | 2.44e-4 (float16 quantisation) |
| develop.global direct on 24 probes | 5e-4 | 5.0e-8 |
| 33³ bake, trilinear lookup of the probes | 1e-3 | 1.63e-7 |
| lookVersion recomputed | equal | equal for all 40 |
| lowbias32 / Gaussian field | exact / 1e-6 | exact / within 1e-6 |

The full built pack (2,591 presets) parses and every recipe bakes (host test). Spatial and finishing operators are checked against vectors generated from `reference_model.py` (`core-develop/src/test/resources/spatial/generate.py`): every operator within 8-bit rounding (≤ 1.98e-3) where clarity is blurred exactly, clarity's low-resolution path within 3.4e-3; tiles render byte-identical to the whole frame. Save copy equals the whole-frame render of the committed recipe (EditorViewModelTest).

## Performance

Emulator numbers only; device numbers stay pending. The host was heavily loaded during every run (load average 8–47 on 10 cores, a concurrent iOS build), so these are pessimistic and noisy.

| Measure | Target | Release build, Pixel_9_Pro emulator | Debug build |
|---|---|---|---|
| Manifest parse + index (cold) | ≤ 300 ms | 71–111 ms | 3.5–14 s (debuggable ART; not representative) |
| 33³ bake | median ≤ 16 ms, p95 ≤ 33 ms | median 28.6 ms, p95 71 ms (n = 7, committed stops) | median 244 ms |
| Drag preview (17³ bake + global render, half-size proxy) | stale ≤ 100 ms while scrubbing 20 stops | median 20.7 ms, p95 51 ms, max 57 ms (n = 56) | 1.7 s |
| Committed preview (full recipe, 1067×1600) | — | median 463 ms, p95 705 ms | 8 s |
| Host JVM 33³ bake (4 threads) | — | median 10.6 ms, p95 14.2 ms | — |

- The 33³ bake misses its target on this loaded emulator; the drag path meets the stale-preview budget because it bakes at 17³. Whether the 33³ target holds on the oldest supported device is **pending a device run**.
- Release numbers come from the app's own log lines (`LightlyDevelop`) during a real flow (Photo Picker, ruler swipes) on a release APK signed locally with the debug key (`tools/release-perf.sh`); the debug numbers from the debug-only benchmark (`--ez lightly.debug.benchmark true`).

## UX conflicts to resolve (reported, not changed)

| # | Conflict | Implemented |
|---|---|---|
| C1 | The slice brief says "Strength"; the approved prototype says **Amount** | Amount, as approved |
| C2 | The slice brief says "Reset"; the approved prototype has **no Reset control** | No Reset. Stop 0 on the ruler removes the Look (one undo step). The old `resetToAuto` API was removed |
| C3 | The prototype remembers an Amount per preset for the session (`s.dev.amount`); the checklist only says re-selecting the applied preset keeps its Amount | The prototype's behaviour (session memory; the recipe stores only the applied Look's Amount) |
| C4 | Approved screens `developing` and `developed` (Auto applied, "Developed" toast) cannot occur without a model (D1) | Not shown in this build; captured only with a debug-injected Auto state for layout comparison |
| C5 | Unimplemented tools: the brief allows a stub in debug builds only | Release builds keep the tools visible but inert; confirm this is acceptable until slices 3–5 |

## Debug launch options (debug builds only)

`lightly.debug.photo` (a file in the app's private files, opened as `file://`), `lightly.debug.editor` (a prototype screen id), `lightly.debug.people present|absent` (stands in for the pending detector), `lightly.debug.favourites`, `lightly.debug.appearance`, `lightly.debug.benchmark`. Every Auto state other than "unavailable" is **injected** for layout comparison: the photo is never corrected. Captures start history at the configured recipe (Undo disabled, as on the prototype's screens). Release builds compile all of this out.

## Comparison matrix

Evidence: `~/.codex/artifacts/lightly/v1/slice2/android/` — `reference/` (shot.js renders), `native/` (emulator captures, `<screen>__<device>__<orientation>__<theme>__<text>.png`), `side-by-side/`, `tools/`. Large text is the system `font_scale 1.24`.

Each cell is one screen in one layout and covers its four variants (light/dark × default/large). "mismatch n/4" means n variants were captured from the current build (f8a024c) and each differs from the reference at least by the listed ids; the remaining variants are **unverified-pending**. **No cell is exact-match verified.**

| Screen | pixel9pro portrait | pixel10proxl portrait | fold-outer portrait | fold-inner portrait | fold-inner landscape | pixeltablet portrait | pixeltablet landscape |
|---|---|---|---|---|---|---|---|
| `loading` | unverified-pending | unverified-pending | mismatch 1/4 (S1); 3 unverified | mismatch 4/4 (S1, S5) | unverified-pending | unverified-pending | unverified-pending |
| `developing` | unverified-pending | unverified-pending | mismatch 1/4 (S1, S2); 3 unverified | mismatch 4/4 (S1, S2, S5) | unverified-pending | unverified-pending | unverified-pending |
| `developed` | unverified-pending | unverified-pending | mismatch 1/4 (S1, S2); 3 unverified | mismatch 4/4 (S1, S2, S5) | unverified-pending | unverified-pending | unverified-pending |
| `model-unavailable` | unverified-pending | unverified-pending | mismatch 1/4 (S1); 3 unverified | mismatch 4/4 (S1, S5) | unverified-pending | unverified-pending | unverified-pending |
| `develop-failed` | unverified-pending | unverified-pending | mismatch 1/4 (S1); 3 unverified | mismatch 4/4 (S1, S5) | unverified-pending | unverified-pending | unverified-pending |
| `dev-preset` | unverified-pending | unverified-pending | mismatch 1/4 (S1, S2); 3 unverified | mismatch 4/4 (S1, S2, S5) | unverified-pending | unverified-pending | unverified-pending |
| `dev-original` | unverified-pending | unverified-pending | mismatch 1/4 (S1); 3 unverified | mismatch 4/4 (S1, S5) | unverified-pending | unverified-pending | unverified-pending |
| `dev-dragging` | unverified-pending | unverified-pending | mismatch 1/4 (S1, S2); 3 unverified | mismatch 4/4 (S1, S2, S5) | unverified-pending | unverified-pending | unverified-pending |
| `dev-browse` | unverified-pending | unverified-pending | mismatch 1/4 (S1, S2); 3 unverified | mismatch 4/4 (S1, S2, S5) | unverified-pending | unverified-pending | unverified-pending |
| `dev-large` | unverified-pending | unverified-pending | mismatch 1/4 (S1, S2); 3 unverified | mismatch 4/4 (S1, S2, S5) | unverified-pending | unverified-pending | unverified-pending |
| `dev-long-name` | unverified-pending | unverified-pending | mismatch 1/4 (S1, S2); 3 unverified | mismatch 4/4 (S1, S2, S5) | unverified-pending | unverified-pending | unverified-pending |
| `dev-amount` | unverified-pending | unverified-pending | mismatch 1/4 (S1, S2); 3 unverified | mismatch 4/4 (S1, S2, S5) | unverified-pending | unverified-pending | unverified-pending |
| `dev-starred` | unverified-pending | unverified-pending | mismatch 1/4 (S1, S2); 3 unverified | mismatch 4/4 (S1, S2, S5) | unverified-pending | unverified-pending | unverified-pending |
| `dev-favourites` | unverified-pending | unverified-pending | unverified-pending | mismatch 4/4 (S1, S2, S5) | unverified-pending | unverified-pending | unverified-pending |
| `dev-fav-full` | unverified-pending | unverified-pending | unverified-pending | mismatch 4/4 (S1, S2, S5) | unverified-pending | unverified-pending | unverified-pending |
| `dev-fav-replace` | unverified-pending | unverified-pending | unverified-pending | mismatch 4/4 (S1, S2, S5) | unverified-pending | unverified-pending | unverified-pending |
| `dev-bw` | unverified-pending | unverified-pending | unverified-pending | mismatch 4/4 (S1, S2, S5) | unverified-pending | unverified-pending | unverified-pending |
| `dev-landscape-photo` | unverified-pending | unverified-pending | unverified-pending | mismatch 4/4 (S1, S2, S5) | unverified-pending | unverified-pending | unverified-pending |
| `dev-portrait-photo` | unverified-pending | unverified-pending | unverified-pending | mismatch 4/4 (S1, S2, S5) | unverified-pending | unverified-pending | unverified-pending |
| `compare` | unverified-pending | unverified-pending | unverified-pending | mismatch 4/4 (S1, S2, S4, S5) | unverified-pending | unverified-pending | unverified-pending |
| `saving` | unverified-pending | unverified-pending | unverified-pending | mismatch 4/4 (S1, S2, S4, S5) | unverified-pending | unverified-pending | unverified-pending |
| `saved` | unverified-pending | unverified-pending | unverified-pending | mismatch 4/4 (S1, S2, S4, S5) | unverified-pending | unverified-pending | unverified-pending |
| `leave-unsaved` | unverified-pending | unverified-pending | unverified-pending | mismatch 4/4 (S1, S2, S4, S5) | unverified-pending | unverified-pending | unverified-pending |
| `more` | unverified-pending | unverified-pending | unverified-pending | mismatch 4/4 (S1, S2, S4, S5) | unverified-pending | unverified-pending | unverified-pending |

**Capture run stopped early** at the coordinator's instruction (host load 60 on 10 cores). Captured from the current build: fold-inner portrait (all 24 screens × 4 variants) and part of fold-outer light/default. Everything else is unverified-pending, including Pixel 9 Pro, Pixel 10 Pro XL, fold-inner landscape and Pixel Tablet in both orientations. Some fold-outer captures under load are blank and are counted as not captured.

**Earlier evidence from older builds (superseded, kept for reference, not counted above):** `side-by-side/*__pixel9pro__*` (build 490cbee, before the tab-offset, ruler-clip and dialog-gap fixes) for all 22 screens × 4 variants of Pixel 9 Pro except where noted, and spot checks in light/default for Pixel Tablet portrait and landscape, fold-inner landscape and fold-outer (build 490cbee/f8a024c, not saved to the evidence folder). These showed the layouts as in the reference apart from the ids below; the fixes in f8a024c came from them.

### Mismatch ids

| Id | Where | Expected (approved) | Observed (native) | Evidence | Status |
|---|---|---|---|---|---|
| S1 | every screen | Prototype status bar (48 dp phones, 40 dp fold, 32 dp tablet) and home bar | Real system bars; on the fold the top inset is 52 dp, so the whole editor sits ~10 dp lower | every side-by-side | Platform (slice-1 M7) |
| S2 | every Develop screen except loading, model-unavailable, develop-failed, dev-original; developing, developed | Auto applied ("Auto" at stop 0, filled switch), "Developing…", "Developed" toast | The same UI, but the Auto state is **injected** by the debug capture route; this build has no model (D1), so no correction is applied and these states never occur for a user | `native/developed__fold-inner__portrait__*.png` | Dependency D1; layout compared only |
| S3 | every screen showing a preset | The prototype's CSS filter simulation of the preset | The real render of the preset's recipe (develop.global + spatial + finishing); colours differ by design | e.g. `side-by-side/dev-preset__fold-inner__portrait__light__default.png` | Expected: the prototype simulates appearance |
| S4 | compare, saving, saved, leave-unsaved, more | Effects carries the "used" dot (the prototype's `edited()` turns a vignette on) | No dot: Effects is not implemented in this slice | `side-by-side/compare__fold-inner__portrait__light__default.png` | Deviation until slice 4 |
| S5 | every screen, large text | Text ×1.24 linear | Android 14+ non-linear font scaling (headings grow less) | `native/*__large.png` | Platform (slice-1 M5); needs approval |
| S6 | undo/redo on every captured screen | Prototype screens open with Undo disabled | Same (capture route rebases history); in real use Undo is enabled after any commit | — | Capture method, no deviation |

### Slice-1 cells re-captured with this build

`slice1-recapture/` holds the slice-1 screens on **fold-inner portrait and landscape** (13 screens + launch × 4 variants each, 112 files), which re-captures the cells stale after M9 and M10. They have **not been compared** yet: unverified-pending. Pixel 10 Pro XL, fold-outer and Pixel Tablet (both orientations) slice-1 cells remain **unverified-pending** (not captured).

## Tests

`./gradlew test assembleDebug assembleRelease -PlightlyGoldenDir=… -PlightlyModelsDir=…`: **218 tests, 0 failures, 0 skipped**; debug and release APKs build; look-pack and launcher-icon checks pass for both.

| Module | Tests | New or changed in slice 2 |
|---|---|---|
| core-develop | 14 | DevelopParityTest (8), DevelopRendererTest (4), DevelopBenchmarkTest (2, including the full 2,591-preset pack) |
| core-session | 32 | SessionSerializationTest rewritten for schema 3 (24 valid fixtures byte-exact, 7 invalid rejected, migrations); EditSessionTest (whole-recipe undo, no Reset) |
| core-export | 34 | Export tests moved to ExportRenderPlan |
| app | 66 | DevelopPanelModelTest (11), EditorViewModelTest (11: drag/commit, category, Amount keep, undo/redo, favourites, photo switch, Save copy = preview render, leave, compare, unknown Look), EditorScreenTest (4, Robolectric) |
| core-render, core-model, core-decode | 72 | unchanged |

The M2 editor tests (EditorViewModelTest, EditorScreenTest, LookPackLoaderTest, EditorLayoutPolicyTest) were removed with the code they tested.

## Pending

- Device runs: bake and browsing targets, GPU path, export memory on 12–48 MP files.
- D1 Auto model, D3 person detection (Portrait visibility).
- Rendering of the later stages (Edit, Background, Portrait, Effects, Border, Watermark).
- A "Look changed / unavailable" notice for restored edits has no approved UI; such Looks render without the Look and are never substituted.
