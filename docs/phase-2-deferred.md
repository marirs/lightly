# Deferred work — tracked, not accepted

Behaviour that is knowingly incomplete after Phase 1 milestone 2. Nothing here
is acceptable as a shipping state.

Each item is pinned by an assertion in `Tests/LightlyTests/DeferredWorkTests.swift`
that asserts the capability is **still missing**. Implementing the work breaks
that test on purpose, which forces the corresponding acceptance criterion to be
revisited deliberately rather than assumed.

| # | Item | Enforced by | Blocks |
|---|------|-------------|--------|
| ~~1~~ | ~~EXIF orientation normalisation~~ | **RESOLVED** — see below | — |
| 2 | Lossless camera ingest | `ImageIOPhotoLoader.preservesOriginalEncoding == false` | Editing from original data rather than a re-encode |
| 3 | Real Develop engine | `DevelopImplementationKind.debugFixedRecipe` | V1 AC "Develop generates a visible improvement" (in the intended sense) |
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

1. `Tests/LightlyTests/PhotoOrientationTests.swift` encodes real JPEG data
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

## 2. Lossless camera ingest — Phase 2

**Where:** `Lightly/Infrastructure/Camera/CameraCaptureView.swift`

Capture currently goes through `UIImagePickerController` and is re-encoded via
`jpegData(compressionQuality: 1.0)`. Even at quality 1.0 this is a lossy
round-trip, and it discards the original representation — including any
HEIC/ProRAW data and most metadata.

**Impact:** the user begins editing from a degraded copy. Unacceptable in a
photo application; it also undermines the non-destructive promise, because the
"original" Lightly holds is already not the original.

**Resolution:** capture to a file URL or obtain the original asset
representation, and pass the untouched data to the loader. Then set
`preservesOriginalEncoding = true`.

---

## 3. Real Develop engine — Phase 2 / Phase 4

**Where:** `Lightly/Domain/Services/DebugFixedRecipeDeveloper.swift`

The shipped engine is precise about what it is:

- **Real:** rendering. Core Image genuinely alters pixels through
  `RecipeRenderer`, which is the graph Phase 2 keeps. Compare shows a true
  before/after.
- **Not real:** judgement. Every analysis in spec §5 — scene, faces, exposure,
  white balance, dynamic range, noise — is absent. The same fixed recipe is
  returned for every photograph.

Two spec §4.4 rules are honoured rather than worked around:

- **No fabricated delay.** The engine is fast because it does little. The
  developing state passes almost instantly. That flicker is the honest
  signature of "no analysis"; it is not a bug to be smoothed over with a
  spinner.
- **No fabricated stages.** `performedStages` omits Detail and Clarity because
  the engine does not perform them, even though the spec's full list includes
  them.

**Disclosure:** a persistent yellow notice reads *"Debug engine — real
rendering, no analysis"*. It is driven by the engine's own
`implementationKind`, not a UI flag, so a placeholder cannot be presented as
finished by forgetting to set something.

**Resolution:** implement the analysis stack (§17), return
`.production`, and the disclosure disappears automatically.

---

## 4. Scene classification — Phase 4

**Where:** `Lightly/Domain/Models/ContextualTool.swift`

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
xcodebuild test -project Lightly.xcodeproj -scheme Lightly -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Unit, history, entitlement, and snapshot tests. Fast; run this constantly.

```bash
xcodebuild test -project Lightly.xcodeproj -scheme LightlyUITests -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
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
  editing. Full P3/ICC output handling remains Phase 2.
