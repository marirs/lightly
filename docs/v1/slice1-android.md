# Lightly 1.0, Android slice 1: entry, More, Preferences

Scope: Launch, Welcome, the system photo picker and camera with their permission and failure states, ⋮ More with Preferences, Legal and About, and the two metadata switches wired into Save copy. The approved reference is `docs/ui/app/` (ff5c5ae). What existed before this slice is recorded in [android-audit.md](android-audit.md).

## What was built

| Area | Where | Notes |
|---|---|---|
| Launch | `res/values-v31/themes.xml`, `res/drawable/launch_*` | On API 31+, the system splash is the eight-ray mark (64 dp, the same geometry as `LightlyMark`) on the approved background, light or dark. On API 29–30 the launch window shows the same mark. Welcome follows the first frame. |
| Welcome | `shell/StartScreens.kt` | Shows ⋮, the mark, "Lightly", the tagline, Choose a photo, Camera, the privacy line and the Privacy Policy link. On an unfolded foldable the brand takes one pane and the actions the other. As in the prototype's `.foldsplit`, the area below the top bar is split into equal halves, with content top-aligned in each pane. There is no sign-in or onboarding. |
| Photo picker | `MainActivity` | `PickVisualMedia(ImageOnly)`. The persistable read grant is unchanged (`ContentResolverPhotoAccessGrants`). Cancelling returns null, and nothing changes. |
| Camera | `MainActivity`, `shell/CameraCaptures.kt`, manifest | The CAMERA runtime permission comes first, as the system dialog. Then `TakePicture` writes into a FileProvider URI under `cache/captures/`. Cancelling deletes the empty file and leaves Welcome unchanged. If permission is denied, the approved "Camera access is off" screen offers Open Settings (app details) and Choose a photo instead. |
| Photo can't be opened | `shell/StartScreens.kt` (`MessageScreen`) | Shown when the editor reports `LoadFailed`. It offers Choose another photo and Try again, which reopens the same URI. |
| Hand-off | `MainActivity.openInEditor` | The picked or captured URI goes to the existing M2 editor (`EditorViewModel.openPhoto`). A top row with Back and ⋮ sits above it. Slice 2 replaces the editor. |
| More | `shell/MorePages.kt`, `shell/LightlyAppContent.kt` | Preferences, Legal and About, with their sub-pages. On phones, More is a bottom sheet (92%, capped by `.sheet` max-height to 88%) and its pages are full screen, as in the prototype's `welcome-more`/`more` (sheets) and `preferences` etc. (pages). On tablets everything is in a centred form sheet, min(540 dp, 92%) wide and 70% tall. On an unfolded foldable, a bottom sheet stays inside the right half (vertical fold) or the lower half (horizontal fold) of the screen, as tall as its content (prototype `.scrim.paneR`/`.paneB`). |
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

## Side-by-side comparison (status under docs/ui/REVIEW-RULES.md)

All evidence is under `~/.codex/artifacts/lightly/v1/slice1/android/`:

- `reference/` holds `shot.js` renders of every slice-1 screen × 6 layouts × light/dark × default/large (480 files).
- `native/` holds emulator captures named `<screen>__<device>__<orientation>__<theme>__<text>.png`.
- `side-by-side/` puts the approved render on the left and native on the right. Its `flows/` subfolder covers the system UI.
- `flows/` holds real, undriven flows on Pixel_9_Pro: picker, cancel, permission dialog, Don't allow, camera, review, camera to editor, a broken file reaching "can't be opened", picker to editor, and More from the editor.
- `tools/` holds the capture scripts.

Captures used debug launch extras: `lightly.debug.screen`, `lightly.debug.appearance` and `lightly.debug.favourites`, seeded with the prototype's five favourites. Large text is the system `font_scale 1.24`.

**Nothing is recorded as exact-match verified.** Every native capture differs from its reference in at least one way that is listed below, and many captures have not yet been inspected one by one.

### Coverage: screen × layout (count of the 4 theme/text variants captured)

| Screen | pixel9pro | pixel10proxl | fold-outer | fold-inner portrait | fold-inner landscape | pixeltablet portrait | pixeltablet landscape |
|---|---|---|---|---|---|---|---|
| launch | 4/4 | pending | pending | 4/4 (light-default shows Welcome: the splash was missed) | 4/4 | pending | pending |
| welcome, welcome-more | 4/4 | pending | pending | 4/4 | 4/4, stale (M9) | pending | pending |
| picker, picker-cancelled, camera-permission, camera, camera-review | light-default flow only | pending | pending | pending | pending | pending | pending |
| camera-denied, load-failed | 4/4 + real flow | pending | pending | 4/4, stale (M10) | 4/4, stale (M9, M10) | pending | pending |
| more (from editor) | light-default flow only | pending | pending | pending | pending | pending | pending |
| preferences, pref-favourites, pref-signature, pref-border, legal, privacy, terms, about, support | 4/4 | pending | pending | 4/4 | 4/4, sheet stale (M9) | pending | pending |

"pending" means unverified: those layouts were not captured. Host load reached a load average of 800 and repeatedly restarted the emulator's system_server, so capture stopped at the coordinator's instruction. "Stale" means the code changed after the capture, so the capture no longer shows the current build.

### Mismatches (expected → observed → evidence)

| # | Where | Expected (approved) | Observed (native) | Evidence | Status |
|---|---|---|---|---|---|
| M1 | privacy, terms, all layouts | Draft placeholder bars under section labels | "This document isn't available in this build." (D2; the brief forbids placeholder bars) | `side-by-side/privacy__pixel9pro__portrait__light__default.png` | Needs a user decision |
| M2 | support | Note + "Contact support" button + Version | "Support isn't available in this build." + Version (no destination, D2) | `side-by-side/support__pixel9pro__portrait__light__default.png` | Needs a user decision |
| M3 | about, support | "Version 1.0 (1)" | "Version 0.1.0-m2 (1)" from BuildConfig (version scheme is D2) | `side-by-side/about__pixel9pro__portrait__light__default.png` | Needs D2 |
| M4 | pref-signature | A saved signature drawing; Draw, Import and Delete rows active | No signature; Draw and Import disabled; no Delete (slice 5) | `side-by-side/pref-signature__pixel9pro__portrait__light__default.png` | Deviation until slice 5 |
| M5 | every screen, large text | Text ×1.24 linear | Android 14+ non-linear font scaling: large headings grow less (Welcome wordmark) | `side-by-side/welcome__pixel9pro__portrait__light__large.png` | Platform; needs user approval |
| M6 | launch | Mark centred below the status bar | System splash centres the mark in the whole screen, about 24 dp higher | `side-by-side/launch__pixel9pro__portrait__dark__default.png` | Platform (system splash) |
| M7 | every screen | Mock bars (9:41, punch-hole) | Real status and navigation bars; content starts at the real inset (52 vs 48 dp on Pixel 9 Pro) | every side-by-side | Platform |
| M8 | preferences captures | Appearance segment "System" selected | "Light" or "Dark" selected, because the capture set Appearance in the app. Behaviour (default System) is covered by tests | `side-by-side/preferences__pixel9pro__portrait__light__default.png` | Capture method; recapture with system night mode pending |
| M9 | fold-inner landscape (welcome, messages, More sheet) | Panes are equal halves of the area below the top bar; the sheet takes the lower half of the screen | The captured build split at the reported hinge (content ~32 dp higher) and sized the sheet from it | `side-by-side/load-failed__fold-inner__landscape__dark__default.png` | Fixed in code after capture; recapture pending |
| M10 | fold-inner camera-denied, load-failed | Text block centred across its pane | The captured build placed the text block at the pane's start | `side-by-side/camera-denied__fold-inner__portrait__dark__large.png` | Fixed in code after capture; recapture pending |
| M11 | more (from editor) | The approved editor under the sheet | The M2 editor with a Back and ⋮ row (slice 2 replaces it) | `flows/more__pixel9pro__portrait__light__default.png` | Deviation until slice 2 |
| M12 | picker, camera-permission, camera, camera-review | The prototype's mock of the system UI | The real Android Photo Picker (Photos/Collections tabs, access banner), permission dialog and camera app | `side-by-side/flows/` | Platform-owned UI |
| M13 | picker | Tapping a photo opens it | The Android 16 picker on this image needs Done after tapping a photo | `flows/load-failed-real__pixel9pro__portrait__light__default.png` (selection state) | Platform behaviour |

Fixed during comparison and recaptured on pixel9pro:
- List rows no longer add vertical padding (`.listrow` is min-height 52 with no padding).
- The phone More sheet is 88% tall.
- The message-screen icon sits at the start of the text block.
- Fold panes are top-aligned.

### Device checks done on the emulator

- The splash, then Welcome.
- The picker and its cancel.
- The CAMERA permission dialog, then Don't allow, which shows "Camera access is off".
- The camera with permission granted, then shutter, review, Done, which reaches the editor.
- A broken file chosen in the picker, which reaches "This photo can't be opened".
- A photo chosen, then More from the editor.
- Save copy of a camera capture on device. The written JPEG carries an EXIF block (Make "Google", Model "sdk_gphone64_arm64") and an ICC_PROFILE segment.
- On the Fold, WindowManager reports a FLAT `FoldingFeature`, vertical in portrait and horizontal at y=1038 px in landscape. Both splits were confirmed on screen.
