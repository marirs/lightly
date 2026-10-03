# Lightly

One repository, two native apps sharing one rendering contract, Look pack and test fixtures.

| Path | What it holds |
|---|---|
| `ios/` | iOS app: `Lightly/` (sources and resources, including the AppIcon asset catalog), `Tests/` (unit, snapshot and UI tests), `project.yml` (XcodeGen spec) and the generated `Lightly.xcodeproj` |
| `android/` | Android app: Gradle multi-module project (`app`, `core-*`) |
| `docs/` | Product and technical spec (`docs/m1/spec.md`, including the shared rendering contract), milestone notes, mockups |
| `experiments/` | Shared, platform-neutral tooling and data: `presets/look_pack/` (Look catalog, pack format and builder), `presets/lr_kit/` (Lightroom validation kit), `lut3d/` (golden set and reference implementation used by both apps' tests) |
| `shared/` | Cross-platform definitions and fixtures both apps' tests read, e.g. `fixtures/edit-state/` (saved-edit schema 2 golden files and migration and resolution rules) |
| `scripts/` | Build and maintenance scripts: `bundle_look_pack.sh` and `check_app_icon.sh` (iOS build phases), `generate-app-icon.swift`, `ingest_presets.py` |

Shared definitions and fixtures stay outside the platform folders. Both apps' builds and tests read them from the repository root.

## Local data that is not in git

Each of these is git-ignored and must stay in this checkout.

- **`experiments/presets/look_pack/out/`** holds the built Look pack.
  - Both apps bundle it at build time.
  - Rebuild it with `python build_look_pack.py`, run from `experiments/presets/look_pack/`.
  - It is derived from the private preset collection (`~/Downloads/Presets - for lightly`).
- **`experiments/lut3d/golden/`** holds the golden images and LUTs the tests of both apps compare against.
- **`experiments/lut3d/models/`** holds the research models. They must never be bundled.
- **`experiments/presets/lr_kit/kit*/`** holds the Lightroom export kits and any exports already made.
- **`android/local.properties`** points to the Android SDK.

## Build and test

### iOS

The Xcode project is generated from `ios/project.yml`:

```bash
cd ios && xcodegen generate
```

```bash
xcodebuild test -project ios/Lightly.xcodeproj -scheme Lightly -destination 'platform=iOS Simulator,name=iPhone 17'
```

```bash
xcodebuild test -project ios/Lightly.xcodeproj -scheme LightlyUITests -destination 'platform=iOS Simulator,name=iPhone 17'
```

- **Snapshot environment:** the snapshot baselines are pinned to iPhone 17, iOS 26.5, Large text (`ios/Tests/LightlyTests/__Snapshots__/ENVIRONMENT.json`).
- **Look pack:** the `LookPack` target copies the pack into `Lightly.app/LookPack/`. Set `LIGHTLY_LOOK_PACK_DIR` to use a pack from elsewhere.
- **App icon:** the app target's last build phase runs `scripts/check_app_icon.sh`. It fails any build whose product lacks the AppIcon metadata or images. Run it on a built `.app` before installing it.

### Android

Use JDK 25, not 26, because Robolectric does not support JDK 26.

```bash
cd android && JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" ./gradlew test assembleDebug assembleRelease \
  -PlightlyGoldenDir="$PWD/../experiments/lut3d/golden" -PlightlyModelsDir="$PWD/../experiments/lut3d/models"
```

- **Look pack:** it is copied into the APK's `assets/lookpack/`. Override its location with `-PlightlyLookPackDir`.
- **Launcher icon:** every `assemble<Variant>` runs `verify<Variant>LauncherIcon`. It fails if the built APK lacks its launcher icon.

## Approved UI

The complete interactive design reference is in [docs/ui](docs/ui/README.md). Serve the repository root and open `/docs/ui/app/index.html` to review the screens and layouts.
