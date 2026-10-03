# iOS audit against the approved Lightly 1.0 UX (slice 1)

Audited on `master` at 0352972, before slice 1 work. The reference is the approved prototype at revision ff5c5ae (`docs/ui/app/`). Each row says whether the existing iOS code is **reused**, **partial** (exists but differs from the approved UX) or **missing**.

## App shell and entry

| Area | Existing iOS code | Status | Notes |
|---|---|---|---|
| Launch | `Features/Launch/LaunchView.swift` (mark, wordmark, "LABS", tagline, mountain artwork, swipe-up affordance with an idle nudge) and the generated system launch screen (blank) | partial | The approved Launch is the eight-ray mark alone, centred. The swipe-up entry is superseded by Welcome's buttons. The generated launch screen is blank, so the mark has to come from a launch image. |
| Welcome | none | missing | Mark, "Lightly", tagline, Choose a photo, Camera, the privacy line, the Privacy Policy link and ⋮ More. |
| Source choice | `Features/PhotoSelection/SourceSelectionSheet.swift` (Camera / Photo Library rows in a 280 pt sheet) | partial | Superseded: Welcome's two buttons open the system picker or camera directly. |
| Routing | `App/AppState.swift` (`AppRoute.launch`, `.editor`), `App/RootView.swift` | partial | Reused for loading and editor hand-off. Missing: the Welcome, camera-denied and load-failed routes; the More presentation. |
| Photo picker | `RootView.photosPicker` (`PhotosPicker`, no library permission, cancel → `cancelPhotoSelection`) | reuse | Already the native picker with no Photos authorisation. |
| Camera | `Infrastructure/Camera/CameraCaptureView.swift` (`UIImagePickerController`) | partial | It falls back to a `.photoLibrary` picker when there is no camera, which the approved UX does not have. There is no explicit permission flow and no denied screen. |
| Load failure | `AppState.present(_:)` plus a generic system alert ("error.title") | partial | The approved UX has a full screen, "This photo can’t be opened", with Choose another photo and Try again. |
| Editor hand-off | `AppState.loadPhoto` → `EditorView` / `LUTEditorViewModel` / `LUTEditSession` | reuse | Kept as is for slice 1. Slice 2 replaces the editor. |
| Editor ⋮ More | none (the top bar has Back and Save copy) | missing | |

## More, preferences, legal, about

| Area | Existing iOS code | Status | Notes |
|---|---|---|---|
| More (Preferences, Legal, About) | none | missing | |
| Preferences store | none. `UserDefaultsFavouritesManager` keeps an unordered `Set` of legacy Look ids | missing | A typed store is needed for appearance, export metadata and the preferred border. |
| Appearance System/Light/Dark | none (follows the system only) | missing | |
| Favourite presets (ordered, up to five, ids from `presets/develop-design-ui.json`) | `Domain/Presets/FavouritesManaging.swift` (unordered, unbounded, legacy Look ids, used only by the legacy `LooksView`) | partial | It does not fit the approved model (ordered, five slots, the Develop catalogue's ids). A new ordered store is added. The legacy one stays for `LooksView` until slice 2 removes it. |
| Saved signature | none | missing | Drawing and import come in slice 5. |
| Preferred border | none | missing | |
| Keep photo metadata / Include location | `Domain/Export/ExportSettings.swift` (`preservesMetadata`, `preservesLocation`), `Features/Export/ExportSheet.swift` (legacy, not reachable from the app) | partial | Location is honoured only when metadata is on, so the switches are not independent. `LUTEditorViewModel.saveCopy` always uses `.default`, so no preference reaches Save copy. |
| Legal, Privacy Policy, Terms of Use | none | missing | The release text is pending (D2). |
| About (version/build), Support | none | missing | The Support destination is pending (D2). |

## Export metadata (`ImageEngine/Export/ImageIOPhotoExporter.swift`)

| Behaviour | Status | Notes |
|---|---|---|
| Colour profile kept (sRGB embedded) | reuse | `ColorPipeline.convertToSRGB8` makes ImageIO embed sRGB. |
| Orientation written as 1 | reuse | The TIFF orientation is removed from the copied block. |
| Capture fields only (aperture, shutter, ISO, make/model, lens, date taken) | partial | The whole EXIF dictionary is copied, including the stale `PixelXDimension`/`PixelYDimension`, `UserComment`, maker data and so on. IPTC is copied too. |
| GPS only on Include location, independent of Keep metadata | partial | GPS is copied only inside the metadata branch. |
| Both off: optional metadata stripped | reuse | |
| No embedded thumbnail | partial | It is not requested explicitly. |

## Design system

| Area | Existing | Status | Notes |
|---|---|---|---|
| Colour tokens | `DesignSystem/Tokens/LightlyColor.swift` (warm paper/near-black palette) | partial | These differ from the approved tokens (#FFFFFF/#F6F6F7/#EEEEF0, ink #121214/#55555C/#6C6C74, hair #E3E3E6, selection #2257D2; dark #1C1C1E/#232326/#111113, ink #F2F2F4/#AEAEB4/#94949C, selection #7AA2FF). New screens use approved tokens. The legacy editor keeps `LightlyColor` until slice 2. |
| Type scale | `LightlyTypography` (text styles) | partial | The approved type sizes are point sizes scaled by text size (×1.24 for large text in the prototype). The new screens use a scaled point-size helper with the prototype's 1.35 line height. |
| Brand mark | `DesignSystem/Components/BrandMark.swift` | reuse | Same geometry as the prototype's `mark()`. The prototype's minimum stroke (1.6) is passed in. |
| Icons | SF Symbols | partial | The prototype draws its own 24-unit line icons (more, close, back, chevron, photo, camera, grip, trash, check). The new screens draw the same paths natively. |

## Platform

| Area | Existing | Status | Notes |
|---|---|---|---|
| Orientations | iPhone: portrait and both landscapes. iPad: all four | partial | Approved: iPhone portrait only. iPad: all orientations. |
| Dynamic Type | supported in the editor and the legacy sheets | reuse | New screens scale too and scroll when content is taller than the screen. |
| Safe areas | respected | reuse | |

## Tests and snapshots touched by slice 1

- Superseded and removed with the old entry flow: `LaunchLayoutTests`, `SourceSheetLayoutTests`, `LaunchSnapshotTests` and their references (`launch-*`, `source-sheet-*`), the source-row case in `SheetControlContrastTests`, the swipe-based UI tests and the picker diagnostics entry.
- Editor snapshots change only because the top bar gains ⋮ More. They are re-recorded in their own commit after inspection.
