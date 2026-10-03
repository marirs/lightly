# Android audit against the approved Lightly 1.0 UX (slice 1)

Audited: `android/` at 0352972, before any slice-1 change. Reference: the approved prototype in `docs/ui/app/` (ff5c5ae), screen ids from `docs/v1/implementation-checklist.md`.

Status words: **reused** (kept as it is), **partial** (exists, but differs from the approved UX or is incomplete), **missing** (nothing exists).

## What exists today

The Android app is the M2 editor shell. It is a single Activity with one Compose screen (`EditorScreen`). That screen goes straight to "Choose a photo", then shows the stepped Look slider, Strength, Undo/Redo/Compare/Reset and Save copy. There is no Welcome, More, Preferences, Legal or About, and no theme beyond default Material 3.

## Start and photo choice

| Screen / behaviour | id | Status | Notes |
|---|---|---|---|
| Launch | `launch` | missing | The manifest uses `Theme.Material.NoActionBar`. There is no splash icon or background, so Android 12+ shows the launcher icon on a default background. |
| Welcome | `welcome` | missing | The editor's empty state ("Choose a photo to start editing…") stands in for it. There is no brand mark, tagline, Camera, privacy line, Privacy Policy link or ⋮. |
| Welcome · More | `welcome-more` | missing | |
| Photo picker | `picker` | **reused** | `PickVisualMedia(ImageOnly)` plus persistable read grants (`ContentResolverPhotoAccessGrants`, retained/released per photo). Kept unchanged. |
| Picker cancelled | `picker-cancelled` | partial | A null result was already ignored, but on the editor's empty state rather than on Welcome. |
| Camera permission / capture / review | `camera-permission`, `camera`, `camera-review` | missing | No camera entry point, no CAMERA permission and no FileProvider. |
| Camera denied | `camera-denied` | missing | |
| Photo can't be opened | `load-failed` | partial | `EditorPhase.LoadFailed` exists, but only as red text plus "Choose another" inside the editor panel. It does not have the approved message, actions or layout. |

## More, preferences, legal and about

| Screen / behaviour | id | Status | Notes |
|---|---|---|---|
| More from the editor | `more` | missing | The editor has no top bar and no ⋮. |
| Preferences, Appearance | `preferences` | missing | Light/dark follows the system through Material defaults. The approved token colours are not used. |
| Favourite presets | `pref-favourites` | missing | The editor's Look pack (18 Looks, format 2) is not the v1 catalogue. The v1 ids come from `presets/develop-design-ui.json`, which is not bundled yet. |
| Saved signature | `pref-signature` | missing | |
| Preferred border | `pref-border` | missing | |
| Keep photo metadata / Include location | (preferences) | missing | Save copy writes `Bitmap.compress` output with no EXIF at all. Under Robolectric's host Skia, that output does carry an ICC profile. |
| Legal, Privacy, Terms | `legal`, `privacy`, `terms` | missing | No content and no screens. |
| About, Support | `about`, `support` | missing | `versionName` is `0.1.0-m2`. `buildConfig` generation is off. |

## Platform and layout

| Concern | Status | Notes |
|---|---|---|
| Edge-to-edge and insets | partial | The editor pads `safeDrawing`, and targetSdk 36 forces edge-to-edge. The status-bar icon colour is not managed. |
| Fold and hinge | partial | `WindowInfoTracker` FoldingFeature flows into `EditorLayoutPolicy`, but only for the editor and only when the fold *separates* content. The approved non-editor screens split panes at any fold, flat or not. |
| Orientation policy | missing | No orientation is requested anywhere. Phones and folded foldables rotate freely. |
| Window size classes | partial | `EditorLayoutPolicy` uses dp sizes, not model names. That is reused for the editor. |
| Launcher icon and Look pack checks | **reused** | `verify<Variant>LauncherIcon` and `bundle<Variant>LookPack` are kept unchanged. |

## Export (relevant to the metadata switches)

| Piece | Status | Notes |
|---|---|---|
| `SaveCopyExporter` (pending row, encode once, publish, delete on failure) | **reused** | Extended with an optional metadata step. The flow and failure classification are unchanged. |
| `ExportCoordinator`, tiling, buffer ledger | **reused** | Untouched. |
| EXIF copy | missing | Neither `androidx.exifinterface` nor DataStore is a project dependency, and slice 1 adds no downloads. Slice 1 therefore uses the platform `android.media.ExifInterface` and `SharedPreferences`. |

## Editor (slice 2 replaces it)

The existing editor (`EditorScreen`, `EditorViewModel`, `SteppedLookSlider`, `LookPackLoader`) differs from the approved Develop UX in almost every visible respect: there is no top bar, no tool dock, no ruler, and categories are chips. Slice 1 keeps it as the hand-off target, as instructed, and adds only a top row with Back and ⋮ above it.
