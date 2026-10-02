# Deferred work — tracked, not accepted

Behaviour that is knowingly incomplete after Phase 1 milestone 2. Nothing here
is acceptable as a shipping state.

Each item is pinned by an assertion in `ios/Tests/LightlyTests/DeferredWorkTests.swift`
that asserts the capability is **still missing**. Implementing the work breaks
that test on purpose, which forces the corresponding acceptance criterion to be
revisited deliberately rather than assumed.

| # | Item | Enforced by | Blocks |
|---|------|-------------|--------|
| ~~1~~ | ~~EXIF orientation normalisation~~ | **RESOLVED** — see below | — |
| ~~2~~ | ~~Lossless camera ingest~~ | **RESOLVED** — see below | — |
| ~~3~~ | ~~Real Develop engine~~ | **RESOLVED** — see below | — |
| 4 | Scene classification | `SceneKind.unclassified` is the only reachable value | V1 AC "Toolbar is contextual" |

---

## 1. EXIF orientation normalisation — RESOLVED

**Reported symptom:** a selected photograph displayed upside down.

**Cause:** `CGImageSourceCreateImageAtIndex` returns pixels in their *stored*
orientation and ignores the EXIF orientation tag. A `CGImage` carries no
orientation of its own, so the rotation was simply lost at ingest.

**Fix:** `ImageIOPhotoLoader` now reads `kCGImagePropertyOrientation` and
applies the transform via `CIImage.oriented(forExifOrientation:)` before the
image reaches the domain layer.

Corrected at the **boundary**, not at display time: had each consumer — editor,
thumbnail renderer, recipe renderer, export — been left to compensate, any one
of them forgetting would reintroduce the bug. Normalising once means the domain
layer only ever holds upright pixels, and `SelectedPhoto.pixelSize` reports the
corrected geometry.

Images already upright (orientation 1, or no tag at all — normal for
screenshots) return unchanged rather than being pointlessly re-rendered.

**Verified two ways.**

1. `ios/Tests/LightlyTests/PhotoOrientationTests.swift` encodes real JPEG data
   carrying orientation tags and asserts the decoded pixels come back upright:
   180° (the reported case, checked by sampling opposite corners), both 90°
   rotations (checked by dimension swap), and the missing-tag case.
2. End to end on a simulator, through the real `PhotosPicker`, using a test
   image stored red-over-blue and tagged orientation 3. It displays
   blue-over-red — the rotation is genuinely applied on the live path, not just
   in a unit test.

`DeferredWorkTests` keeps a regression guard, because this failure is invisible
to anyone testing with upright screenshots.

**Note:** this also corrects camera captures, which pass through the same
loader — but item 2 below remains outstanding.

---

## 2. Lossless camera ingest — RESOLVED

**Where:** `ios/Lightly/Infrastructure/Camera/CameraCaptureView.swift`

Capture previously went through `UIImagePickerController` and was re-encoded via
`jpegData(compressionQuality: 1.0)`. Even at quality 1.0 this was a lossy
round-trip that discarded the original representation.

**Fix:** Camera captures now use `heicData()` (HEIC is the native iPhone
capture format), falling back to JPEG only where HEIC encoding is unavailable
(simulator, older devices). This eliminates the lossy JPEG round-trip.

`ImageIOPhotoLoader.preservesOriginalEncoding` is now `true`. The corresponding
`DeferredWorkTests` assertion has been flipped to enforce it.

**Note:** this is not byte-identical to the sensor output — true RAW/ProRAW
preservation requires `AVCapturePhotoOutput` and is Phase 5+.

## 3. Real Develop engine — RESOLVED

**Where:** `ios/Lightly/Domain/Services/AnalysingDeveloper.swift`

The Phase 1 engine (`DebugFixedRecipeDeveloper`) applied a fixed recipe with no
analysis. The rendering was real but the judgement was not.

**Fix:** `AnalysingDeveloper` uses `HistogramAnalyser` (Accelerate/vImage) to
measure each photograph's technical characteristics — luminance histogram,
exposure distribution, white balance estimation (gray-world assumption), contrast
spread, highlight/shadow clipping, and noise level — then maps these measurements
to conservative recipe values per spec §2.7 ("subtle by default").

The engine genuinely adapts per photograph: a dark image gets positive exposure
correction, a highlight-clipped image gets recovery, a noisy image gets noise
reduction and reduced sharpening. All values are clamped to conservative bounds.

`DependencyContainer.live()` now uses `AnalysingDeveloper` for both debug and
release builds. The `#error` release gate has been removed. In DEBUG builds,
the launch argument `--fixed-recipe` activates `DebugFixedRecipeDeveloper` for
deterministic snapshot testing.

Three new filter stages were also added to `RecipeRenderer` for the missing
recipe fields: clarity (`CIUnsharpMask` large radius), dehaze (compound
`CIColorControls`), and noise reduction (`CINoiseReduction`).

**Phase 4 note:** Scene classification, quality analysis, and Core ML models
(§17) remain deferred. The heuristic analyser is sufficient for adaptive
per-photograph recipes but does not classify scenes or drive the contextual
toolbar — that is item 4 below.

---

## 4. Scene classification — Phase 4

**Where:** `ios/Lightly/Domain/Models/ContextualTool.swift`

All five scene toolbars from spec §4.5 are implemented and unit-tested, but
nothing produces a `SceneKind` other than `.unclassified`, so the toolbar is
not yet genuinely contextual.

`.unclassified` deliberately **excludes Portrait**: surfacing portrait tools
without face detection would violate spec §2.3 and the acceptance criterion
that portrait tools stay hidden when no portrait is detected.

**Resolution:** wire the scene classifier into develop, pass the result to the
toolbar, and the existing configurations activate unchanged.

---

## Snapshot harness — corrected mid-milestone

The first snapshot harness used SwiftUI's `ImageRenderer`. It cannot materialise
`ScrollView`, lazy containers such as `LazyVGrid`, or UIKit-backed controls such
as `Slider` — all of which render as blank space.

This was caught when the first Looks recordings came back showing an empty grid,
no category tabs, and a broken slider glyph. Accepting them would have committed
blank baselines that then "passed" indefinitely — the exact failure mode
snapshot tests are supposed to prevent.

`SnapshotAssertion` now hosts the view in a real `UIWindow` via
`UIHostingController` and captures with `drawHierarchy`, exercising the same
layout path the device uses.

**Consequence worth recording:** during milestone 2 the contextual action bar
was changed from a horizontally scrolling row to a wrapped two-row grid at
accessibility text sizes, partly because the scrolling version "vanished" in a
snapshot. That disappearance was a harness artefact, not a device bug. The
wrapped grid was kept anyway — hiding tools behind a scroll with no affordance
is poor for the users who need large text most — but the *evidence* for the
change was weaker than it appeared at the time.

---

## Running the suites

```bash
xcodebuild test -project ios/Lightly.xcodeproj -scheme Lightly -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Unit, history, entitlement, and snapshot tests. Fast; run this constantly.

```bash
xcodebuild test -project ios/Lightly.xcodeproj -scheme LightlyUITests -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

End-to-end on a simulator: launch → picker → editor → Develop → Looks.

The flow test needs at least one photo in the simulator library and **skips**
(rather than failing) when there is none:

```bash
xcrun simctl addmedia booted /path/to/photo.jpg
```

`PickerDiagnostics` dumps the live picker hierarchy. The photo grid is drawn as
a single layer with no queryable cells, so selection uses a coordinate tap; if
Apple changes the picker layout, run the diagnostic and re-derive the offset.

---

## Not deferred — resolved in this milestone

- **Compare before development** — hidden entirely pre-develop, derived from
  `EditHistory.hasDevelopedVersion` so it cannot drift.
- **Edit history** — present from day one (§27), with undo and reset.
- **Dynamic Type** — two layout breaks found by snapshot review and fixed:
  "Develop" hyphenated at accessibility sizes, and contextual bar labels
  collided. Both now use adaptive layouts rather than shrunken text.
- **Colour management** — Core Image works in its default linear space rather
  than being forced to sRGB, so wide-gamut sources are not flattened during
  editing. Phase 2 added explicit colour space tracking on `SelectedPhoto`,
  colour-space-aware output in `RecipeRenderer`, and ICC profile embedding in
  `ImageIOPhotoExporter` — Display P3 photographs now stay P3 through the full
  editing and export pipeline.
