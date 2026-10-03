# Lightly 1.0, Android slice 1: entry, More, Preferences

Scope: Launch, Welcome, the system photo picker and camera with their permission and failure states, ⋮ More with Preferences, Legal and About, and the two metadata switches wired into Save copy. The approved reference is `docs/ui/app/` (ff5c5ae). What existed before this slice is recorded in [android-audit.md](android-audit.md).

## What was built

| Area | Where | Notes |
|---|---|---|
| Launch | `res/values-v31/themes.xml`, `res/drawable/launch_*` | On API 31+, the system splash is the eight-ray mark (64 dp, the same geometry as `LightlyMark`) on the approved background, light or dark. On API 29–30 the launch window shows the same mark. Welcome follows the first frame. |
| Welcome | `shell/StartScreens.kt` | Shows ⋮, the mark, "Lightly", the tagline, Choose a photo, Camera, the privacy line and the Privacy Policy link. On an unfolded foldable the brand takes one pane and the actions the other, split exactly at the reported fold. There is no sign-in or onboarding. |
| Photo picker | `MainActivity` | `PickVisualMedia(ImageOnly)`. The persistable read grant is unchanged (`ContentResolverPhotoAccessGrants`). Cancelling returns null, and nothing changes. |
| Camera | `MainActivity`, `shell/CameraCaptures.kt`, manifest | The CAMERA runtime permission comes first, as the system dialog. Then `TakePicture` writes into a FileProvider URI under `cache/captures/`. Cancelling deletes the empty file and leaves Welcome unchanged. If permission is denied, the approved "Camera access is off" screen offers Open Settings (app details) and Choose a photo instead. |
| Photo can't be opened | `shell/StartScreens.kt` (`MessageScreen`) | Shown when the editor reports `LoadFailed`. It offers Choose another photo and Try again, which reopens the same URI. |
| Hand-off | `MainActivity.openInEditor` | The picked or captured URI goes to the existing M2 editor (`EditorViewModel.openPhoto`). A top row with Back and ⋮ sits above it. Slice 2 replaces the editor. |
| More | `shell/MorePages.kt`, `shell/LightlyAppContent.kt` | Preferences, Legal and About, with their sub-pages. On phones, More is a 92% bottom sheet and its pages are full screen, as in the prototype's `welcome-more`/`more` (sheets) and `preferences` etc. (pages). On tablets everything is in a centred form sheet, min(540 dp, 92%) wide and 70% tall. On an unfolded foldable, a bottom sheet stays inside the right pane (vertical fold) or the lower pane (horizontal fold). |
| Preferences | `prefs/UserPreferences.kt` | SharedPreferences: DataStore is not a project dependency, and nothing was downloaded. Appearance System/Light/Dark applies at once and app-wide; on API 31+ it is also passed to `UiModeManager.setApplicationNightMode` so the splash matches. Favourites hold catalogue ids from `presets/develop-design-ui.json` (bundled verbatim into `assets/catalogue/`): at most five, reorder by drag or TalkBack Move up/down, remove. Preferred border defaults to None and is never applied. Keep photo metadata defaults on; Include location defaults off. |
| Saved signature | `MorePages.kt` (`SignatureBody`) | Structure only. Draw and Import rows are present but disabled until slice 5. There is no mock signature and no Delete row until a signature exists. |
| Legal / About | `prefs/ReleaseText.kt`, `assets/legal/release-text.json` | The release text (D2) is loaded from an asset that is **empty** in this build. Privacy Policy and Terms therefore show "This document isn't available in this build.", and Support shows "Support isn't available in this build." with no Contact button. About shows `versionName (versionCode)` from BuildConfig. A test fails if the bundled asset is ever non-empty without real content. |
| Metadata | `core-export/ExportMetadata.kt`, `PlatformExifMetadata.kt`, `SaveCopyExporter` | The policy is captured when Save copy is tapped. Keep metadata copies Make, Model, FNumber, ExposureTime, ISO and DateTimeOriginal; Include location copies the GPS latitude, longitude, altitude, time and date tags. With both off, the copy has no EXIF block. The ICC profile is always kept, and no orientation, dimension or thumbnail tag is ever copied. |
| Orientation and layout | `shell/ShellLayout.kt`, `MainActivity.applyOrientationPolicy` | Displays with a smallest width under 600 dp (phones, folded foldables) are portrait; larger displays are unspecified. This uses `WindowMetricsCalculator.computeMaximumWindowMetrics`, never model names, and never locks in multi-window. Layout mode comes from window width (> 700 dp is Large, as in the prototype) and the WindowManager `FoldingFeature`. Edge-to-edge with transparent bars; status and navigation icon contrast follows Appearance; content pads `safeDrawing`. |

## Known limits (platform or dependency)

- **LensModel is not copied.** The platform `android.media.ExifInterface` neither reads nor writes EXIF 0xA434; this was checked against the API 34 implementation that Robolectric runs. `androidx.exifinterface` supports it but is not a project dependency, and adding it means a download. This is marked `DEFERRED(dependency)` in `ExportMetadataTags`.
- **Location from picked photos.** Android redacts GPS from MediaStore and Photo Picker reads unless the app holds `ACCESS_MEDIA_LOCATION`. "Include location" copies whatever location the readable Original carries: camera captures keep theirs, while picker copies are usually already redacted. Whether to request `ACCESS_MEDIA_LOCATION` is a product decision (DEFERRED, slice 5).
- **Camera captures** stay private to Lightly (app cache) and are replaced by the next capture. Saving an edit uses Save copy.
- **Debug-only launch extras** (`DebugLaunchOptions`) open any slice-1 screen directly for the scripted comparison. Release builds compile them out (`BuildConfig.DEBUG`).

## Tests

- `core-export` `SaveCopyMetadataTest` (Robolectric, native graphics): checks all four switch combinations on the written JPEG bytes. Each check covers capture tags, GPS, no EXIF block when both are off, the ICC APP2 segment, no orientation/thumbnail/stale dimension, and only whitelisted tags. It also covers an unreadable Original (the copy is saved without metadata) and removal of the scratch file.
- `app` `AppNavigatorTest`: every More parent; Privacy from Welcome versus via Legal; Back from editor, camera-denied and load-failed; process-death encoding; layout decisions by size and fold; the orientation policy.
- `app` `PreferencesTest` (Robolectric): approved defaults, persistence across launches, the four independent switch states, favourites rules, corrupted values, the real catalogue (2,591 presets), and the empty release-text asset.
- `app` `LightlyAppContentTest` (Robolectric Compose): Welcome content; Privacy link round trip; phone sheet then full page; Preferences changes; favourites; About/Support; signature structure; camera-denied and load-failed actions; tablet form sheet; unfolded split (portrait and landscape) with More in one pane; 1.3× text.

## Side-by-side comparison

Native screenshots against `shot.js` renders are in `~/.codex/artifacts/lightly/v1/slice1/android/`: `reference/`, `native/`, `side-by-side/` (approved on the left), and `flows/` for the system UI (picker, permission dialog, camera).
