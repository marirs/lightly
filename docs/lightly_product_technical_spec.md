# Lightly — Product & Technical Specification

**Product:** Lightly  
**Company:** Lightly Labs  
**Platform:** iOS first  
**Bundle ID:** `com.lightlylabs.lightly`  
**Primary domain:** `lightlylabs.app`  
**Secondary domain:** `lightlylabs.ai`  
**Tagline:** *See it as you remember it.*

---

## 1. Purpose

Lightly is a premium, minimal photo-development application built around one central interaction:

> Open → choose a photo → tap **Develop** → compare → save.

The product should feel calm, intelligent, private, and intentionally restrained. It should not resemble a dense Lightroom-style editor. Advanced features should appear only when relevant to the loaded image.

The core promise is:

> Lightly develops photographs thoughtfully, without making them look artificial.

---

## 2. Product Principles

1. **The photograph is the interface.**
   The image should occupy most of the screen.

2. **One clear next step.**
   Every state should have an obvious primary action.

3. **Contextual tools only.**
   Portrait tools should not appear when no portrait is detected. Architecture, night, RAW, monochrome, and other tools should appear only when relevant.

4. **No mandatory account.**
   Core editing should work without login, registration, or onboarding forms.

5. **On-device by default.**
   Core processing should remain on the device. Cloud-assisted features must be opt-in and clearly disclosed.

6. **Non-destructive editing.**
   Never overwrite the original photograph.

7. **Subtle by default.**
   The default result should feel natural, not exaggerated.

---

## 3. Core User Flow

```text
Launch
  ↓
Swipe up
  ↓
Choose Camera or Photo Library
  ↓
Select photo
  ↓
Photo selected
  ↓
Tap Develop
  ↓
Developing
  ↓
Developed photo
  ↓
Looks / Magic / Repair / B&W / More
  ↓
Compare
  ↓
Save or Share
```

---

## 4. Screen Specifications

## 4.1 Launch Screen

### Visual design

- Light or dark appearance based on system setting
- Lightly Labs logo centred
- Tagline beneath logo
- Minimal snow-mountain line artwork near the bottom
- Small upward gesture indicator
- No buttons
- No login
- No loading spinner unless genuinely required

### Copy

```text
Lightly
LABS

See it as
you remember it.

Swipe up to choose a photo
```

### Interaction

- User swipes upward
- Mountain artwork moves subtly with the gesture
- A bottom sheet is revealed
- The animation should feel smooth and restrained
- Do not force a separate onboarding screen

---

## 4.2 Source Selection Sheet

### Copy

```text
Choose a photo

Everything stays on your device.

Camera
Take a new photo

Photo Library
Choose from your library
```

### Behaviour

- **Camera** opens the native iOS camera capture flow
- **Photo Library** opens Apple Photos Picker
- Permissions should be requested only when the user selects the relevant option

### V1 recommendation

Use Apple-native capture and selection interfaces rather than building a custom camera or gallery.

---

## 4.3 Photo Selected Screen

The selected photograph should fill almost the entire screen.

### Top controls

```text
Back                                      More
```

### Bottom actions before development

```text
Crop              Develop
```

`Compare` should remain hidden or disabled until a developed version exists.

### Develop button

- Large central button
- Label: `Develop`
- Optional Lightly spark icon
- This is the primary action

---

## 4.4 Developing State

The photo remains visible but is darkened slightly behind a translucent overlay.

### Copy

```text
Developing…

Applying thoughtful enhancements
```

### Processing stages

Only display real pipeline stages:

```text
White balance
Exposure
Highlights
Shadows
Colour
Detail
Clarity
```

Each stage may receive a completion indicator.

### Performance targets

- Preview result: ideally 0.5–2 seconds on supported devices
- Full-resolution render may continue asynchronously
- RAW and very large files may take longer
- Never create fake delays merely for theatre

---

## 4.5 Developed Screen

After development, the large Develop button disappears.

### Top controls

```text
Back                                      More
```

### Secondary action row

- Left: `Crop`
- Right: `Compare`, `Share`

### Bottom contextual action bar

For a landscape:

```text
Looks    Magic    Repair    B&W    More
```

For a portrait:

```text
Portrait    Looks    Magic    Repair    More
```

For architecture:

```text
Perspective    Looks    Repair    Magic    More
```

For night photography:

```text
Low Light    Repair    Looks    Magic    More
```

For an already monochrome image:

```text
Tone    Grain    Repair    More
```

### Compare behaviour

Preferred interaction:

- Press and hold Compare → show original
- Release → return to developed result

Accessibility alternative:

- Tap to toggle original/developed
- VoiceOver label: `Show original photograph`

---

## 5. Develop Engine

The Develop engine is Lightly's most important feature.

It should analyse:

- Scene type
- Subject type
- Faces and people count
- Skin regions
- Sky
- Foreground/background
- Horizon alignment
- Exposure distribution
- White balance
- Dynamic range
- Highlight clipping
- Shadow loss
- Noise
- Blur
- Colour casts
- Subject prominence
- Orientation
- Image quality
- Whether the photograph is already monochrome
- Whether the photograph is RAW/ProRAW

### Develop output

The result should be represented as a non-destructive edit recipe.

Example:

```json
{
  "scene": "landscape",
  "whiteBalance": {
    "temperature": 180,
    "tint": -3
  },
  "exposure": 0.18,
  "highlights": -0.31,
  "shadows": 0.22,
  "contrast": 0.08,
  "vibrance": 0.12,
  "clarity": 0.06,
  "dehaze": 0.04,
  "sharpening": 0.11,
  "noiseReduction": 0.07
}
```

---

## 6. Lightroom Preset Conversion

## 6.1 Goal

Convert approximately 200–500 Lightroom presets into Lightly-compatible looks.

## 6.2 Input formats

Primary:

- `.xmp`

Possible secondary support:

- `.lrtemplate`
- `.dng` preset references

## 6.3 Transferable properties

Commonly transferable:

- Exposure
- Contrast
- Highlights
- Shadows
- Whites
- Blacks
- Temperature
- Tint
- Texture
- Clarity
- Dehaze
- Vibrance
- Saturation
- Tone curves
- HSL
- Colour grading
- Sharpening
- Noise reduction
- Vignette
- Grain
- Calibration-style colour shifts

## 6.4 Adobe-specific limitations

Some settings cannot be reproduced exactly:

- Adobe camera profiles
- Adobe RAW demosaicing
- AI masks
- Adaptive presets
- Lens-specific corrections
- Adobe-specific clarity/dehaze behaviour
- Profile-dependent colour science
- Proprietary content-aware adjustments

Do not claim pixel-identical Lightroom rendering.

## 6.5 Conversion pipeline

```text
XMP preset
  ↓
Parse XML
  ↓
Normalize Adobe values
  ↓
Map supported parameters
  ↓
Generate curves and/or LUT
  ↓
Render reference images
  ↓
Compare against Lightroom reference output
  ↓
Manual correction where needed
  ↓
Export Lightly preset package
```

## 6.6 Internal preset schema

```json
{
  "id": "film.golden-memory",
  "name": "Golden Memory",
  "category": "film",
  "version": 1,
  "compatibleScenes": [
    "portrait",
    "travel",
    "landscape"
  ],
  "recipe": {
    "contrast": 0.08,
    "highlights": -0.16,
    "shadows": 0.12,
    "toneCurve": [],
    "hsl": {},
    "grain": {
      "amount": 0.14,
      "size": 0.32
    }
  }
}
```

## 6.7 Preset organisation

Do not expose all 500 presets in one flat list.

Recommended categories:

- Recommended
- Natural
- Portrait
- Film
- Travel
- Landscape
- Cinematic
- Moody
- Bright
- Monochrome
- Favourites

Show only 3–6 recommended looks first.

---

## 7. Looks Screen

### Layout

```text
Looks                                      Close

Recommended   Film   Natural   Cinematic   Moody

[Preview] [Preview] [Preview]
[Preview] [Preview] [Preview]
[Preview] [Preview] [Preview]

Intensity  ─────────────○────
```

### Behaviour

- Thumbnails use the current photograph
- Render thumbnails at reduced resolution
- Render full resolution only when confirming/exporting
- Long press to favourite
- Preserve preset intensity separately from preset recipe
- Recommended tab should be scene-aware

---

## 8. Black & White

Do not provide only one grayscale conversion.

Recommended looks:

- Neutral
- Soft
- Fine Art
- Documentary
- High Contrast
- Matte
- Silver
- Warm Monochrome
- Cool Monochrome
- Infrared-inspired
- Film-grain variants

Each treatment may control:

- Per-colour channel luminance
- Tone curve
- Grain
- Highlight roll-off
- Shadow density
- Local contrast
- Optional toning

The B&W system can reuse the same preset engine.

---

## 9. Portrait Tools

Show only when one or more faces/people are detected.

### Tools

```text
Portrait

Natural Skin
Skin Tone
Texture
Under-eye
Eyes
Teeth
Hair
Beard
Background
```

### Product rules

Defaults must be conservative.

Avoid automatic:

- Face reshaping
- Eye enlargement
- Jaw or nose reshaping
- Skin whitening
- Removal of permanent identifying features

### Skin processing

Use frequency-aware skin smoothing:

- Preserve pores
- Preserve facial edges
- Protect eyes, eyebrows, lips, nostrils, and facial hair
- Reduce temporary blemishes
- Avoid waxy skin

---

## 10. Magic Tools

Magic contains AI-assisted and generative edits.

### Reflection features

Treat these as separate technical problems:

- Reduce eyeglass glare
- Remove sunglass reflection
- Reduce window reflection
- Reduce water reflection
- Reduce display-screen glare

### Appearance changes

- Hair colour
- Beard colour
- Outfit recolouring
- Outfit replacement
- Add sunglasses
- Reimagine without glasses
- Background replacement
- Sky relighting
- Golden-hour relighting

### Object operations

- Remove object
- Remove person
- Clean background
- Remove wires
- Remove dust spots
- Remove text/signage
- Extend background
- Reframe image

### Important terminology

Removing glasses entirely requires generating unseen eye regions. Label it clearly as:

```text
Reimagine without glasses
```

Do not present it as faithful restoration.

---

## 11. Repair Tools

```text
Repair

Noise
Motion Blur
Soft Focus
Compression
Dust
Scratches
Low Light
Old Photo
Reflection
```

### V1 candidates

- Denoise
- Mild sharpening
- Dust/spot removal
- JPEG artefact reduction
- Low-light recovery

### Later candidates

- Motion deblur
- Severe blur restoration
- Old-photo restoration
- Reflection removal
- Super-resolution

---

## 12. More Screen

```text
More

Adjust
Effects
Crop & Rotate
Perspective
Metadata
Histogram
Copy Development
Paste Development
Reset
Settings
```

### Advanced adjustments

- Exposure
- Contrast
- Highlights
- Shadows
- Whites
- Blacks
- Temperature
- Tint
- Vibrance
- Saturation
- Texture
- Clarity
- Dehaze
- Sharpness
- Noise reduction
- Curves
- HSL
- Colour grading
- Vignette
- Grain

These controls should remain hidden from the main interface.

---

## 13. Settings

```text
Settings

Appearance
System / Light / Dark

Development Style
Natural / Balanced / Expressive

Processing
Prefer On-Device
Allow Cloud Features

Export Format
HEIC / JPEG / PNG / TIFF

Export Quality
High / Maximum

Preserve Metadata
On

Preserve Location
Ask / On / Off

Save Copy
New Photo / Replace Editable Copy

Privacy
Manage Downloaded Models

About
Version
Licences
Support
```

No account should be required for core use.

---

## 14. Export

### V1 formats

- HEIC
- JPEG
- PNG

### Later formats

- TIFF
- 16-bit TIFF
- Display P3
- Batch export
- RAW sidecar recipe

### Export options

- Preserve EXIF
- Preserve capture date
- Preserve GPS
- Remove metadata
- Maximum resolution
- Social media sizes
- Optional Lightly recipe metadata

Do not watermark by default.

---

## 15. Technical Architecture

## 15.1 App layer

- Swift
- SwiftUI
- Swift Concurrency
- Observation
- PhotosUI
- AVFoundation
- StoreKit 2 when monetisation is added

## 15.2 Image layer

- Core Image
- Metal
- Metal Performance Shaders
- Core ML
- Vision
- Accelerate where useful

## 15.3 Rendering pipeline

```text
Original asset
  ↓
Orientation normalization
  ↓
Colour-space normalization
  ↓
Low-resolution preview
  ↓
Scene and quality analysis
  ↓
Non-destructive recipe graph
  ↓
Core Image / Metal preview renderer
  ↓
User refinements
  ↓
Full-resolution export renderer
```

## 15.4 Colour management

Support:

- sRGB
- Display P3
- Embedded ICC profiles
- HDR image handling where supported

Never silently flatten wide-gamut images to sRGB during editing.

---

## 16. Model Strategy

Lightly should not use one large LLM as its image engine.

Use several specialised on-device models.

## 16.1 LLM role

Use an LLM only for:

- Natural-language editing requests
- Mapping user intent into structured edit commands
- Explaining recommendations
- Describing what Develop changed
- Preset search by meaning
- Preset naming and organisation

Examples:

- “Make it warmer”
- “Reduce glare but keep the glasses”
- “Give this a soft film look”
- “Make the sky calmer”
- “Keep the skin natural”

## 16.2 Recommended LLM

Use Apple’s on-device Foundation Models framework when available.

Use it as an orchestrator, not a renderer.

Structured output example:

```json
{
  "intent": "adjust",
  "targets": ["global"],
  "operations": [
    {
      "type": "temperature",
      "value": 0.12
    },
    {
      "type": "saturation",
      "value": -0.04
    }
  ]
}
```

The app must continue to work without this model.

Do not bundle a general 3B–8B LLM in V1.

---

## 17. Recommended On-Device Model Stack

## 17.1 Scene classifier

Purpose:

- Portrait
- Landscape
- Food
- Architecture
- Night
- Snow
- Beach
- Pet
- Document
- Macro
- Sunset

Recommended architecture:

- MobileNetV3
- EfficientNet-Lite
- Small custom ViT or ConvNeXt model

Target:

- Core ML
- Quantised
- Approximately 10–30 MB

## 17.2 Image quality model

One multi-task model should predict:

- Exposure
- White balance
- Colour cast
- Blur
- Noise
- Contrast
- Highlight clipping
- Shadow loss
- Subject prominence

## 17.3 Segmentation

Use:

- Vision person segmentation
- Vision face detection and landmarks
- Custom segmentation for:
  - Sky
  - Hair
  - Skin
  - Glasses
  - Clothing
  - Windows
  - Water
  - Foreground/background

## 17.4 Face processing

Use:

- Vision face detection
- Vision face landmarks
- Skin mask model
- Hair segmentation
- Glasses/glare classifier
- Optional facial parsing network

## 17.5 Reflection removal

Likely requires a dedicated image-to-image restoration model.

Candidate architecture families:

- U-Net
- NAFNet
- Restormer-like lightweight network
- Mobile restoration transformer

Use lower-resolution preview and tiled high-resolution export.

## 17.6 Generative features

Outfit replacement, hidden-eye generation, complex relighting, and high-quality object removal may require cloud assistance initially.

Recommended hybrid architecture:

```text
On-device:
Detection, segmentation, masks, privacy controls

Cloud:
Generative render

On-device:
Final compositing, colour matching, export
```

Cloud processing must be opt-in.

---

## 18. Device Capability Tiers

## Tier 1 — All supported iPhones

- Presets
- Develop
- Scene analysis
- B&W
- Crop
- Tone and colour
- Denoise
- Portrait segmentation
- Conservative skin enhancement
- Hair/beard recolouring
- Export

## Tier 2 — Apple Intelligence-capable devices

- Natural-language edits
- Edit explanations
- Contextual suggestions
- Semantic preset search
- Structured editing commands

## Tier 3 — Explicit cloud opt-in

- Reimagine without glasses
- Outfit replacement
- Strong reflection removal
- Background generation
- High-resolution object removal
- Generative relighting

---

## 19. Data and Privacy

- Core processing on-device
- No account for basic use
- No upload without explicit permission
- Clearly label cloud-assisted tools
- Do not retain cloud-processed photos by default
- Provide a privacy screen explaining each processing mode
- Preserve originals
- Give the user control over metadata and GPS retention

---

## 20. Suggested Codebase Structure

```text
Lightly/
├── App/
│   ├── LightlyApp.swift
│   ├── AppState.swift
│   └── DependencyContainer.swift
├── Features/
│   ├── Launch/
│   ├── PhotoSelection/
│   ├── Editor/
│   ├── Developing/
│   ├── Looks/
│   ├── Portrait/
│   ├── Magic/
│   ├── Repair/
│   ├── BlackAndWhite/
│   ├── Export/
│   └── Settings/
├── Domain/
│   ├── Models/
│   ├── Recipes/
│   ├── Presets/
│   └── Services/
├── ImageEngine/
│   ├── Pipeline/
│   ├── CoreImage/
│   ├── Metal/
│   ├── ColourManagement/
│   └── Export/
├── Intelligence/
│   ├── SceneAnalysis/
│   ├── QualityAnalysis/
│   ├── Segmentation/
│   ├── FaceAnalysis/
│   └── LanguageOrchestration/
├── Infrastructure/
│   ├── Photos/
│   ├── Camera/
│   ├── Persistence/
│   ├── Networking/
│   └── Telemetry/
├── DesignSystem/
│   ├── Typography/
│   ├── Icons/
│   ├── Components/
│   └── Motion/
└── Tests/
    ├── Unit/
    ├── Snapshot/
    ├── Integration/
    └── Performance/
```

---

## 21. V1 Scope

### Required

- Launch screen
- Swipe-up source selection
- Camera
- Photos Picker
- Photo selected screen
- Develop
- Developing state
- Developed screen
- Compare
- Crop
- Share/save
- Context-aware toolbar
- Preset engine
- 50–100 curated looks
- Multiple B&W looks
- Basic scene recognition
- Non-destructive edit recipes
- HEIC/JPEG/PNG export
- Offline processing
- Light and dark themes

### Explicitly not required for first release

- Login
- User account
- Social feed
- Marketplace
- Custom camera
- Full Lightroom replacement
- Generative outfit replacement
- Hidden-eye reconstruction
- Complex cloud rendering
- Batch editing
- Desktop sync

---

## 22. V1 Acceptance Criteria

### Launch

- App opens without login
- Launch animation completes smoothly
- Swipe-up gesture reveals source selection
- Light/dark mode follows system appearance

### Selection

- Camera and Photos Picker both work
- Photo selection does not require full-library permission
- Selected image orientation is correct

### Develop

- Develop generates a visible improvement
- Output remains natural
- Processing stages reflect real work
- Preview appears within the performance target on supported devices

### Editor

- Compare works
- Crop works
- Share/save works
- Toolbar is contextual
- Portrait tools remain hidden when no portrait is detected

### Presets

- Thumbnails use the selected photograph
- Presets apply non-destructively
- Intensity is adjustable
- Favourites persist locally
- Categories work

### Export

- Full-resolution export succeeds
- Colour profile is preserved correctly
- Metadata settings are respected
- Original image remains unchanged

### Privacy

- No image leaves the device unless the user explicitly selects a cloud feature
- Cloud features display a clear consent prompt

---

## 23. Development Phases

## Phase 1 — UI shell

- Design system
- Launch screen
- Swipe gesture
- Source sheet
- Photos Picker
- Camera
- Editor shell
- Developed screen
- Looks screen
- Settings

## Phase 2 — Image pipeline

- Core Image graph
- Non-destructive recipes
- Preview renderer
- Full-resolution renderer
- Export
- Colour management
- Compare

## Phase 3 — Presets

- XMP parser
- Mapping layer
- Internal schema
- Thumbnail generation
- Categories
- Favourites
- Intensity
- Validation against Lightroom references

## Phase 4 — Intelligence

- Scene classification
- Quality analysis
- Contextual toolbar
- Recommendation ranking
- Portrait detection
- Basic segmentation

## Phase 5 — Advanced tools

- Skin enhancement
- Hair/beard recolouring
- Denoise
- Repair
- Reflection experiments
- Natural-language orchestration

---

## 24. Claude Development Instructions

When using Claude to implement Lightly:

1. Ask it to work phase by phase.
2. Do not request the entire app in one prompt.
3. Require compiling code after each milestone.
4. Require unit tests for recipes, preset parsing, and export.
5. Require snapshot tests for major screens.
6. Keep UI, domain logic, image engine, and ML code separated.
7. Require all public APIs and complex image transforms to be documented.
8. Do not accept placeholder image processing presented as finished functionality.
9. Require explicit error handling.
10. Require performance profiling before full-resolution export is considered complete.

Recommended first prompt:

```text
You are the lead iOS engineer for Lightly.

Read this specification completely before writing code.

Start only with Phase 1: UI shell.

Create a production-quality SwiftUI iOS project structure for bundle identifier com.lightlylabs.lightly.

Implement:
- Design system
- Light and dark themes
- Launch screen
- Swipe-up source selection sheet
- Camera and Photos Picker entry points
- Photo selected editor shell
- Developed editor shell
- Looks screen
- Settings screen

Do not implement actual AI or image-processing logic yet. Use clear protocols and mock services so the real image engine can be integrated later.

Requirements:
- Swift Concurrency
- Observation
- Dependency injection
- No force unwraps
- Accessibility labels
- Dynamic Type support
- Unit-testable view models
- Snapshot-test-ready views
- Clean folder structure matching the specification

Before coding, provide:
1. Architecture summary
2. Folder structure
3. Data flow
4. Milestone plan

Then implement one milestone at a time.
```

---

## 25. Final Technical Recommendation

For V1:

```text
Language model:
Apple Foundation Models framework
Only for language understanding and edit orchestration

Scene model:
Quantised MobileNetV3 or EfficientNet-Lite Core ML model

Quality model:
Small custom multi-task Core ML model

Segmentation:
Apple Vision plus custom Core ML segmentation models

Rendering:
Core Image plus Metal

Generative operations:
Cloud-assisted later, with explicit opt-in
```

The product must succeed without generative AI.

The foundation is:

> Excellent development, excellent presets, natural portrait work, strong privacy, and an interface that stays out of the photograph.
