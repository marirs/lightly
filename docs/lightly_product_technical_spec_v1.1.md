# Lightly — Product & Technical Specification (v1.1)

**Product:** Lightly
**Company:** Lightly Labs
**Platform:** iOS first (iPhone only for V1)
**Bundle ID:** `com.lightlylabs.lightly`
**Primary domain:** `lightlylabs.app`
**Secondary domain:** `lightlylabs.ai`
**Tagline:** *See it as you remember it.*
**Spec version:** 1.1
**Status:** Development contract — the “Decisions Locked” section below is binding.

---

## 0. Decisions Locked (v1.1)

> These are settled product decisions. Do **not** reinterpret, relitigate, or “improve” them during implementation. If a mockup, older spec text, or intuition conflicts with this section, **this section wins**. Raise a question before deviating.

### 0.1 Photo source

- **Use Apple’s native `PhotosPicker` (PhotosUI).** Do **not** build the custom photo grid shown in the original mockups.
- No full-library authorisation required for core selection.
- Lightly resumes its branded experience **after** the user picks a photo.
- A custom gallery is a **later, opt-in** feature, available only after the user explicitly grants broader Photos access. Never the default.
- The third mockup screen (custom “Search your library” grid) is **deprecated** and must be redrawn as an Apple system picker.

### 0.2 Presets

- All bundled presets are **owned by Lightly Labs / the founders**. No third-party or commercial preset packs are bundled. (Licensing is therefore **not** a blocker.)
- Work required is **conversion**, not acquisition: founder-owned Lightroom presets → Lightly recipe schema (§6).
- A private user-import path for personal `.xmp` files may ship later; bundled content stays first-party.

### 0.3 Monetisation & entitlements

- **Free tier:** Develop, Compare, Crop, basic export, 8–12 Looks.
- **Lightly Pro** (subscription or lifetime): unlimited Develop, all Looks, B&W, Portrait, Repair, RAW, maximum-quality export.
- **Generative credits** (consumable): outfit replacement, advanced reflection removal, reimagine-without-glasses, generative backgrounds.
- **No lock badges scattered through the editor.** User enters the tool, previews the result freely, and sees payment only at **apply/export** of a paid operation. (§26)

### 0.4 Product voice — AI vs engine

- Product voice is **“Lightly’s engine.”** AI is an **implementation detail**, never the emotional headline.
- Public site: *“Lightly intelligently develops your photographs.”*
- Processing screen: *“Applying thoughtful enhancements.”* (single canonical string)
- App Store: “AI” allowed in keywords / detailed description only.
- Technical docs: name Core ML, Vision, and specialised models plainly.

### 0.5 Privacy language

- No absolute “stays on your device” claim anywhere.
- Canonical short form: **“Your photos stay on your device by default.”**
- Canonical long form (where space allows): **“Core development happens on your device. Photos are uploaded only when you explicitly choose a cloud-assisted feature.”**

### 0.6 Cloud generative scope

- **Removed from the V1 delivery commitment.** Roadmap only.
- No generative cloud feature ships until the Cloud Contract (§29) is fully defined and signed off.

### 0.7 Platform & orientation

- iPhone only, **portrait orientation** for launch and source selection.
- Editor **may** gain landscape later.
- iPad is **deferred**, not accidentally shipped as a stretched iPhone build.

### 0.8 Localisation

- All user-visible strings live in **String Catalogs** from the first commit.
- English-only at launch is fine; architecture must be localisation-ready.

### 0.9 Telemetry

- Collect only: crashes, processing duration, device capability tier, tool success/failure, anonymous feature usage.
- Never collect: photographs, facial attributes, image embeddings, edit contents, location metadata, identity-linked natural-language prompts.
- Privacy-preserving identifiers; Settings disclosure required. (§30)

### 0.10 Undo / history

- Non-destructive **edit history is part of the domain model from day one**, even if V1 UI exposes only a single Undo. (§27)

### 0.11 Locked UI behaviour corrections

- **Compare** is hidden/disabled until a developed version exists.
- Looks shows **3–6 Recommended** in the first viewport (scroll reveals more); Recommended is scene-aware.
- **One** navigation model: the **contextual bottom action bar**. Remove the separate generic Tools grid from the core flow.
- Developing copy is exactly **“Applying thoughtful enhancements.”**
- Swipe-up affordance **animates gently after a short idle period**.
- Never combine “Coming soon” with an active App Store download badge — pick one.

### 0.12 Brand mark

- Eight-ray mark gets a **production redraw**: slightly thicker strokes, optical (not purely mathematical) spacing.
- Test at 16, 24, 32, 40, 60, 120, 1024 px.
- Dedicated favicon variant + dedicated monochrome notification/settings variant.
- Default app icon stays predominantly black/white with a **restrained warm centre/glow** (not the fully warm variant).

---

## 0.13 Changelog v1.0 → v1.1

| Area | v1.0 | v1.1 |
|---|---|---|
| Photo picker | Custom grid mockup / “prefer native” | **Native `PhotosPicker` locked**; custom grid deprecated |
| Presets | “Convert 200–500 Lightroom presets” | **First-party founder presets only**; conversion, no licensing |
| Monetisation | Absent (StoreKit “when added”) | **Free / Pro / Generative-credits model locked** (§26) |
| AI voice | Mixed “AI” / “engine” across site + captions | **“Lightly’s engine” is the voice; AI is implementation** (§0.4) |
| Privacy claim | “Photos stay on your device” (absolute) | **“…by default”**; explicit cloud caveat (§0.5) |
| Cloud generative | Implied V1-adjacent | **Out of V1 delivery**; gated on Cloud Contract (§29) |
| Error states | None | **Full catalogue added** (§28) |
| Undo/history | Not modelled | **History in domain model from day one** (§27) |
| Platform | “iOS first” (ambiguous) | **iPhone/portrait V1; iPad deferred** (§0.7) |
| Localisation | Not mentioned | **String Catalogs from commit 1** (§0.8) |
| Telemetry | Folder only | **Collection/exclusion policy locked** (§30) |
| Brand mark | Thin 8-ray, warm variant | **Production redraw + size tests; warm centre only** (§0.12) |

---

## 1. Purpose

Lightly is a premium, minimal photo-development application built around one central interaction:

> Open → choose a photo → tap **Develop** → compare → save.

The product should feel calm, intelligent, private, and intentionally restrained. It should not resemble a dense Lightroom-style editor. Advanced features should appear only when relevant to the loaded image.

The core promise is:

> Lightly develops photographs thoughtfully, without making them look artificial.

---

## 2. Product Principles

1. **The photograph is the interface.** The image should occupy most of the screen.
2. **One clear next step.** Every state should have an obvious primary action.
3. **Contextual tools only.** Portrait tools should not appear when no portrait is detected. Architecture, night, RAW, monochrome, and other tools should appear only when relevant.
4. **No mandatory account.** Core editing should work without login, registration, or onboarding forms.
5. **On-device by default.** Core processing stays on device. Cloud-assisted features must be opt-in and clearly disclosed.
6. **Non-destructive editing.** Never overwrite the original photograph.
7. **Subtle by default.** The default result should feel natural, not exaggerated.
8. **The engine, not the acronym.** We describe *what the photo becomes*, not the technology that did it. (See §0.4.)

---

## 3. Core User Flow

```text
Launch
  ↓
Swipe up (gentle idle affordance nudges after ~2.5s)
  ↓
Choose Camera or Photo Library (native PhotosPicker)
  ↓
Select photo
  ↓
Photo selected  (Compare hidden/disabled)
  ↓
Tap Develop
  ↓
Developing
  ↓
Developed photo  (Compare now enabled)
  ↓
Looks / Magic / Repair / B&W / More  (contextual bottom bar)
  ↓
Compare
  ↓
Save or Share  (paywall only at apply/export of paid ops)
```

---

## 4. Screen Specifications

### 4.1 Launch Screen

**Visual design**

- Light or dark appearance based on system setting
- Lightly Labs logo centred
- Tagline beneath logo
- Minimal snow-mountain line artwork near the bottom
- Small upward gesture indicator
- No buttons, no login, no loading spinner unless genuinely required

**Copy**

```text
Lightly
LABS

See it as
you remember it.

Swipe up to choose a photo
```

**Interaction**

- User swipes upward; mountain artwork moves subtly with the gesture
- A bottom sheet is revealed; animation feels smooth and restrained
- Do not force a separate onboarding screen
- **v1.1:** if the user is idle for a short period (~2.5s), the swipe indicator performs a gentle looping nudge for discoverability. It must not be loud or nagging.

### 4.2 Source Selection Sheet

**Copy**

```text
Choose a photo

Everything stays on your device.

Camera
Take a new photo

Photo Library
Choose from your library
```

**Behaviour (v1.1 — locked)**

- **Photo Library opens Apple’s native `PhotosPicker`.** No custom grid. No full-library permission requested for core selection.
- **Camera** opens the native iOS camera capture flow.
- Permissions are requested only when the user selects the relevant option.
- A branded custom gallery is a later opt-in feature behind explicit broader-Photos consent; it is **not** V1.

> **Deprecated:** the original “Search your library / Photos / Albums” custom grid mockup. Redraw screen 3 as the Apple system picker.

### 4.3 Photo Selected Screen

The selected photograph fills almost the entire screen.

**Top controls**

```text
Back                                      More
```

**Bottom actions before development**

```text
Crop              Develop
```

- **Compare is hidden or disabled** until a developed version exists (locked, §0.11). Do not render it as a tappable control pre-develop.

**Develop button**

- Large central button, label `Develop`, optional Lightly spark icon. Primary action.

### 4.4 Developing State

The photo remains visible, darkened slightly behind a translucent overlay.

**Copy (canonical)**

```text
Developing…

Applying thoughtful enhancements
```

**Processing stages** (display only real pipeline stages):

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

**Performance targets**

- Preview result: ideally 0.5–2 s on supported devices
- Full-resolution render may continue asynchronously
- RAW and very large files may take longer
- Never create fake delays for theatre
- On failure, route to the appropriate error state (§28), never a hung spinner.

### 4.5 Developed Screen

After development, the large Develop button disappears.

**Top controls**

```text
Back                                      More
```

**Secondary action row**

- Left: `Crop`
- Right: `Compare` (now enabled), `Share`

**Bottom contextual action bar** (single navigation model — no separate Tools grid)

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

**Compare behaviour**

- Preferred: press and hold Compare → show original; release → return to developed result.
- Accessibility alternative: tap to toggle. VoiceOver label: `Show original photograph`.

---

## 5. Develop Engine

The Develop engine is Lightly’s most important feature.

It analyses: scene type, subject type, faces/people count, skin regions, sky, foreground/background, horizon alignment, exposure distribution, white balance, dynamic range, highlight clipping, shadow loss, noise, blur, colour casts, subject prominence, orientation, image quality, whether already monochrome, whether RAW/ProRAW.

**Develop output** — a non-destructive edit recipe:

```json
{
  "scene": "landscape",
  "whiteBalance": { "temperature": 180, "tint": -3 },
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

The Develop result becomes the first entry after `Original` in the edit history (§27).

---

## 6. Preset Conversion (First-Party)

### 6.1 Goal

Convert the founders’ own Lightroom presets into Lightly recipes. Target roughly 200–500 converted looks over time; **50–100 curated looks for V1**.

### 6.2 Ownership (locked)

- Only presets **created by / owned by / commissioned for Lightly Labs** are bundled.
- No third-party commercial packs. Licensing is **not** a blocker because the source presets are first-party.
- Owning a *file* is not the concern here — we own the *rights*. This is stated so no external packs sneak in during implementation.

### 6.3 Input formats

Primary: `.xmp`. Possible secondary: `.lrtemplate`, `.dng` preset references.

### 6.4 Transferable properties

Exposure, Contrast, Highlights, Shadows, Whites, Blacks, Temperature, Tint, Texture, Clarity, Dehaze, Vibrance, Saturation, Tone curves, HSL, Colour grading, Sharpening, Noise reduction, Vignette, Grain, Calibration-style colour shifts.

### 6.5 Adobe-specific limitations

Cannot reproduce exactly: Adobe camera profiles, Adobe RAW demosaicing, AI masks, adaptive presets, lens-specific corrections, Adobe-specific clarity/dehaze behaviour, profile-dependent colour science, proprietary content-aware adjustments. **Do not claim pixel-identical Lightroom rendering.**

### 6.6 Conversion pipeline

```text
XMP preset → Parse XML → Normalize Adobe values → Map supported parameters →
Generate curves and/or LUT → Render reference images →
Compare against founder reference output → Manual correction → Export Lightly preset package
```

### 6.7 Internal preset schema

```json
{
  "id": "film.golden-memory",
  "name": "Golden Memory",
  "category": "film",
  "version": 1,
  "compatibleScenes": ["portrait", "travel", "landscape"],
  "recipe": {
    "contrast": 0.08,
    "highlights": -0.16,
    "shadows": 0.12,
    "toneCurve": [],
    "hsl": {},
    "grain": { "amount": 0.14, "size": 0.32 }
  }
}
```

### 6.8 Organisation

Do not expose all presets in one flat list. Categories: Recommended, Natural, Portrait, Film, Travel, Landscape, Cinematic, Moody, Bright, Monochrome, Favourites. **Show 3–6 Recommended first** (scene-aware); scroll reveals more.

---

## 7. Looks Screen

**Layout**

```text
Looks                                      Close

Recommended   Film   Natural   Cinematic   Moody

[Preview] [Preview] [Preview]     ← first viewport: 3–6 Recommended
[Preview] [Preview] [Preview]     ← revealed on scroll
[Preview] [Preview] [Preview]

Intensity  ─────────────○────
```

**Behaviour**

- Thumbnails use the current photograph, rendered at reduced resolution; full resolution only on confirm/export.
- Long press to favourite. Preset intensity is preserved separately from the recipe.
- Recommended is **scene-aware**: a landscape must not surface B&W Classic as a top recommendation.
- First viewport stays selective (3–6). More results appear only after scrolling.

---

## 8. Black & White

Provide multiple treatments, not one grayscale conversion: Neutral, Soft, Fine Art, Documentary, High Contrast, Matte, Silver, Warm Monochrome, Cool Monochrome, Infrared-inspired, Film-grain variants.

Each may control: per-colour channel luminance, tone curve, grain, highlight roll-off, shadow density, local contrast, optional toning. Reuses the same preset engine. **Pro entitlement** (§26).

---

## 9. Portrait Tools

Show only when one or more faces/people are detected.

**Tools:** Natural Skin, Skin Tone, Texture, Under-eye, Eyes, Teeth, Hair, Beard, Background.

**Product rules — defaults must be conservative.** Avoid automatic: face reshaping, eye enlargement, jaw/nose reshaping, skin whitening, removal of permanent identifying features.

**Skin processing** — frequency-aware smoothing: preserve pores, preserve facial edges, protect eyes/eyebrows/lips/nostrils/facial hair, reduce temporary blemishes, avoid waxy skin. **Pro entitlement.**

---

## 10. Magic Tools

AI-assisted and generative edits. **Generative subset is credit-gated and out of V1 delivery** (§0.6, §26, §29).

**Reflection features:** reduce eyeglass glare, remove sunglass reflection, reduce window reflection, reduce water reflection, reduce display-screen glare.

**Appearance changes:** hair colour, beard colour, outfit recolouring, outfit replacement, add sunglasses, reimagine without glasses, background replacement, sky relighting, golden-hour relighting.

**Object operations:** remove object, remove person, clean background, remove wires, remove dust spots, remove text/signage, extend background, reframe image.

**Terminology (locked):** removing glasses entirely generates unseen eye regions. Label it `Reimagine without glasses`. Never present it as faithful restoration.

---

## 11. Repair Tools

`Noise, Motion Blur, Soft Focus, Compression, Dust, Scratches, Low Light, Old Photo, Reflection`

**V1 candidates:** Denoise, mild sharpening, dust/spot removal, JPEG artefact reduction, low-light recovery. **Pro entitlement.**

**Later:** motion deblur, severe blur restoration, old-photo restoration, reflection removal, super-resolution.

---

## 12. More Screen

`Adjust, Effects, Crop & Rotate, Perspective, Metadata, Histogram, Copy Development, Paste Development, Reset, Settings`

**Advanced adjustments** (hidden from main interface): Exposure, Contrast, Highlights, Shadows, Whites, Blacks, Temperature, Tint, Vibrance, Saturation, Texture, Clarity, Dehaze, Sharpness, Noise reduction, Curves, HSL, Colour grading, Vignette, Grain.

`Reset` maps to clearing the edit history back to `Original` (§27).

---

## 13. Settings

```text
Settings

Appearance            System / Light / Dark
Development Style     Natural / Balanced / Expressive
Processing            Prefer On-Device · Allow Cloud Features (off by default)
Export Format         HEIC / JPEG / PNG / TIFF
Export Quality        High / Maximum
Preserve Metadata     On
Preserve Location     Ask / On / Off
Save Copy             New Photo / Replace Editable Copy
Privacy               Manage Downloaded Models · Diagnostics & Usage (telemetry disclosure)
Subscription          Manage Lightly Pro · Restore Purchases · Generative Credits
About                 Version · Licences · Support
```

No account required for core use. Telemetry disclosure and opt-out live under **Privacy → Diagnostics & Usage** (§30).

---

## 14. Export

**V1 formats:** HEIC, JPEG, PNG. (TIFF/16-bit/P3/batch/RAW sidecar later.)

**Export options:** Preserve EXIF, preserve capture date, preserve GPS, remove metadata, maximum resolution, social-media sizes, optional Lightly recipe metadata.

Do not watermark by default. **Maximum-quality export is a Pro entitlement.** Export failures route to §28.

---

## 15. Technical Architecture

**App layer:** Swift, SwiftUI, Swift Concurrency, Observation, PhotosUI, AVFoundation, StoreKit 2.

**Image layer:** Core Image, Metal, Metal Performance Shaders, Core ML, Vision, Accelerate.

**Rendering pipeline**

```text
Original asset → Orientation normalization → Colour-space normalization →
Low-resolution preview → Scene and quality analysis → Non-destructive recipe graph →
Core Image / Metal preview renderer → User refinements → Full-resolution export renderer
```

**Colour management:** sRGB, Display P3, embedded ICC profiles, HDR where supported. Never silently flatten wide-gamut images to sRGB during editing.

---

## 16. Model Strategy

Lightly does not use one large LLM as its image engine. Use several specialised on-device models.

**16.1 LLM role (only):** natural-language editing requests, mapping intent → structured edit commands, explaining recommendations, describing what Develop changed, preset search by meaning, preset naming/organisation.

**16.2 Recommended LLM:** Apple’s on-device Foundation Models framework when available, as an **orchestrator, not a renderer**.

```json
{
  "intent": "adjust",
  "targets": ["global"],
  "operations": [
    { "type": "temperature", "value": 0.12 },
    { "type": "saturation", "value": -0.04 }
  ]
}
```

The app must work without this model. Do not bundle a general 3B–8B LLM in V1.

> **Voice note:** internally this is “the language orchestrator.” Externally it is never the headline (§0.4).

---

## 17. Recommended On-Device Model Stack

**17.1 Scene classifier** — Portrait, Landscape, Food, Architecture, Night, Snow, Beach, Pet, Document, Macro, Sunset. Arch: MobileNetV3 / EfficientNet-Lite / small custom ViT or ConvNeXt. Target: Core ML, quantised, ~10–30 MB.

**17.2 Image quality model** — multi-task: exposure, white balance, colour cast, blur, noise, contrast, highlight clipping, shadow loss, subject prominence.

**17.3 Segmentation** — Vision person segmentation; Vision face detection/landmarks; custom segmentation for sky, hair, skin, glasses, clothing, windows, water, foreground/background.

**17.4 Face processing** — Vision face detection + landmarks, skin mask model, hair segmentation, glasses/glare classifier, optional facial parsing.

**17.5 Reflection removal** — dedicated image-to-image restoration (U-Net / NAFNet / Restormer-like / mobile restoration transformer). Low-res preview + tiled high-res export.

**17.6 Generative features** — outfit replacement, hidden-eye generation, complex relighting, high-quality object removal may require cloud initially.

```text
On-device: detection, segmentation, masks, privacy controls
Cloud:     generative render
On-device: final compositing, colour matching, export
```

Cloud processing is opt-in and **out of V1 delivery** (§0.6, §29).

---

## 18. Device Capability Tiers

**Tier 1 — all supported iPhones:** presets, Develop, scene analysis, B&W, crop, tone/colour, denoise, portrait segmentation, conservative skin enhancement, hair/beard recolouring, export.

**Tier 2 — Apple Intelligence-capable:** natural-language edits, edit explanations, contextual suggestions, semantic preset search, structured editing commands.

**Tier 3 — explicit cloud opt-in (post-V1):** reimagine without glasses, outfit replacement, strong reflection removal, background generation, high-res object removal, generative relighting.

If a requested feature’s model/tier is unavailable on the current device, route to the “Model unavailable” state (§28) rather than failing silently.

---

## 19. Data and Privacy

- Core processing on-device.
- No account for basic use.
- No upload without explicit permission; cloud-assisted tools clearly labelled.
- Do not retain cloud-processed photos by default (enforced via Cloud Contract, §29).
- Provide a privacy screen explaining each processing mode.
- Preserve originals. User controls metadata and GPS retention.

**Canonical privacy copy (locked, §0.5):**

- Short: *“Your photos stay on your device by default.”*
- Long: *“Core development happens on your device. Photos are uploaded only when you explicitly choose a cloud-assisted feature.”*

Do not use any absolute “never leaves your device” phrasing anywhere in product, marketing, or App Store metadata.

---

## 20. Suggested Codebase Structure

```text
Lightly/
├── App/                      (LightlyApp, AppState, DependencyContainer)
├── Features/                 (Launch, PhotoSelection, Editor, Developing, Looks,
│                              Portrait, Magic, Repair, BlackAndWhite, Export, Settings, Paywall)
├── Domain/                   (Models, Recipes, History, Presets, Entitlements, Services)
├── ImageEngine/              (Pipeline, CoreImage, Metal, ColourManagement, Export)
├── Intelligence/             (SceneAnalysis, QualityAnalysis, Segmentation, FaceAnalysis, LanguageOrchestration)
├── Infrastructure/           (Photos, Camera, Persistence, Networking, StoreKit, Telemetry)
├── DesignSystem/             (Typography, Icons, Components, Motion)
├── Resources/                (Localizable String Catalogs from commit 1)
└── Tests/                    (Unit, Snapshot, Integration, Performance)
```

New vs v1.0: `Features/Paywall`, `Domain/History`, `Domain/Entitlements`, `Infrastructure/StoreKit`, `Resources/` String Catalogs.

---

## 21. V1 Scope

**Required**

- Launch screen · swipe-up source selection · Camera · **native Photos Picker** · Photo-selected screen · Develop · Developing state · Developed screen · Compare · Crop · Share/save · context-aware bottom bar · preset engine · **50–100 curated first-party looks** · multiple B&W looks · basic scene recognition · non-destructive edit recipes **with undo/history** · HEIC/JPEG/PNG export · offline processing · light/dark themes · **String Catalogs** · **free/Pro entitlement gating** · **error/recovery states (§28)** · **telemetry policy (§30)**.

**Explicitly not required for first release**

- Login · user account · social feed · marketplace · custom camera · **custom photo gallery** · full Lightroom replacement · generative outfit replacement · hidden-eye reconstruction · **complex cloud rendering / any generative cloud feature** · batch editing · desktop sync · iPad build.

---

## 22. V1 Acceptance Criteria

**Launch**

- Opens without login; launch animation completes smoothly; swipe-up reveals source selection; **idle affordance animates after short delay**; light/dark follows system.

**Selection**

- Camera and **native PhotosPicker** both work; **selection requires no full-library permission**; selected image orientation correct.

**Develop**

- Generates a visible, natural improvement; processing stages reflect real work; preview within performance target on supported devices; **failure paths land on defined error states, never a hang**.

**Editor**

- Compare works and is **hidden/disabled until a developed version exists**; Crop works; Share/save works; toolbar is contextual (single bottom-bar model); Portrait tools hidden when no portrait detected; **Undo reverses the last operation without destroying the original**.

**Presets**

- Thumbnails use the selected photograph; apply non-destructively; intensity adjustable; favourites persist locally; categories work; **first viewport shows 3–6 scene-aware Recommended**.

**Monetisation**

- Free features usable with no paywall friction; **paid operations preview freely and prompt payment only at apply/export**; restore purchases works; entitlements persist.

**Export**

- Full-resolution export succeeds; colour profile preserved; metadata settings respected; original unchanged; **Maximum quality gated to Pro**.

**Privacy**

- No image leaves the device unless the user explicitly selects a cloud feature; cloud features show a clear consent prompt; **telemetry excludes all prohibited fields (§30) and is disclosed in Settings**.

---

## 23. Development Phases

**Phase 1 — UI shell:** design system, launch screen, swipe gesture + idle affordance, source sheet, **native Photos Picker**, camera, editor shell, developed screen, Looks screen, Settings, **String Catalogs scaffolding**, **entitlement/paywall stubs**.

**Phase 2 — Image pipeline:** Core Image graph, non-destructive recipes, **edit-history model**, preview renderer, full-resolution renderer, export, colour management, Compare.

**Phase 3 — Presets:** XMP parser, mapping layer, internal schema, thumbnail generation, categories, favourites, intensity, validation against founder reference output.

**Phase 4 — Intelligence:** scene classification, quality analysis, contextual toolbar, recommendation ranking, portrait detection, basic segmentation.

**Phase 5 — Advanced tools:** skin enhancement, hair/beard recolouring, denoise, repair, reflection experiments, natural-language orchestration.

**Phase 6 — Commerce & polish:** StoreKit 2 integration, paywall at apply/export, generative-credit ledger (UI only until Cloud Contract signed), telemetry wiring, error-state coverage.

---

## 24. Claude Development Instructions

1. Work phase by phase. Do not request the entire app in one prompt.
2. Compile after each milestone.
3. Unit tests for recipes, **history/undo**, preset parsing, export, **entitlement checks**.
4. Snapshot tests for major screens **and every error state (§28)**.
5. Keep UI, domain logic, image engine, and ML code separated.
6. Document all public APIs and complex image transforms.
7. Do not present placeholder image processing as finished functionality.
8. Explicit error handling — no silent failures; map to §28 states.
9. Profile performance before full-resolution export is considered complete.
10. **Treat §0 Decisions Locked as binding. If a mockup or older text conflicts, follow §0 and flag the conflict.**

Recommended first prompt (updated tail):

```text
You are the lead iOS engineer for Lightly. Read this specification completely, especially
section 0 (Decisions Locked), before writing code. Start only with Phase 1: UI shell.
Use the native PhotosPicker — do not build a custom photo grid. Place all user-visible
strings in String Catalogs. Stub entitlements and error states now. Do not implement AI or
image-processing logic yet; use protocols and mock services. Provide architecture summary,
folder structure, data flow, and milestone plan before coding, then implement one milestone
at a time.
```

---

## 25. Final Technical Recommendation

For V1:

```text
Language model:   Apple Foundation Models — language understanding + edit orchestration only
Scene model:      Quantised MobileNetV3 or EfficientNet-Lite Core ML
Quality model:    Small custom multi-task Core ML
Segmentation:     Apple Vision + custom Core ML segmentation
Rendering:        Core Image + Metal
Generative:       Cloud-assisted later, explicit opt-in, gated on the Cloud Contract (§29)
```

The product must succeed **without** generative AI. Foundation: excellent development, excellent first-party presets, natural portrait work, strong privacy, and an interface that stays out of the photograph.

---

## 26. Monetisation & Entitlements (new)

### 26.1 Tiers

| Tier | Included |
|---|---|
| **Free** | Develop, Compare, Crop, basic export, 8–12 Looks |
| **Lightly Pro** (subscription or lifetime) | Unlimited Develop, all Looks, B&W, Portrait, Repair, RAW, maximum-quality export |
| **Generative credits** (consumable packs) | Outfit replacement, advanced reflection removal, reimagine-without-glasses, generative backgrounds |

### 26.2 Gating rules

- **No lock badges scattered through the editor.** The tool opens, the result previews, and payment is requested **only at apply/export** of a paid operation.
- Pro unlocks entire tool families; generative credits are consumed per operation.
- Entitlement state lives in `Domain/Entitlements`, backed by StoreKit 2, cached locally, with **Restore Purchases**.
- Free tier must feel complete, not crippled — Develop + Compare + Crop + a real set of Looks is a usable product on its own.

### 26.3 Paywall presentation

- Contextual: triggered by intent (applying a Pro Look, exporting max quality, running a generative op).
- Show the *previewed result the user already likes* alongside the offer.
- One clear primary purchase action; no dark patterns; honest trial terms.

---

## 27. Undo & Edit History (new)

Edit history is part of the domain model from day one, even if V1 UI exposes only a single Undo.

**Model**

```text
Original
  → Develop
  → Look applied
  → Intensity changed
  → Crop
  → Repair
```

- Each operation is a reversible node on a non-destructive stack; reversing never reprocesses or mutates the original.
- `Reset` clears back to `Original`.
- `Copy Development` / `Paste Development` operate on the recipe graph, not pixels.
- V1 UI: a single **Undo** control (and Reset in More). Full branching history UI is later.
- Persist history with the working session so a returning user can still step back.

---

## 28. Error & Recovery States (new)

Every state below needs defined copy, an illustration/affordance, and a clear next action. No silent failures; no infinite spinners.

| State | Trigger | Behaviour |
|---|---|---|
| Unsupported image format | Picked asset can’t be decoded | Explain, offer to pick another |
| Failed photo loading | Asset load throws | Retry / pick another |
| Insufficient memory | Large asset can’t be held | Suggest smaller/lower-res, degrade gracefully |
| Develop failure | Pipeline error | Keep original, offer retry, log to telemetry |
| Cloud feature unavailable | Service down / not V1 | Explain, offer on-device alternative if any |
| Network interrupted | Mid cloud op | Safe cancel, no partial charge of credits |
| No face detected | Portrait tool on faceless image | Portrait tools stay hidden; if forced, explain |
| Multiple faces detected | Portrait op ambiguity | Let user pick target face |
| RAW file too large | Exceeds device budget | Offer reduced-res develop path |
| Model unavailable on device | Tier mismatch | Explain capability tier, hide/disable feature |
| Export failure | Write/encode error | Retry, preserve edit state |
| Storage full | No room to save | Prompt to free space, keep edit in memory |
| Permission denied | Camera/Photos refused | Explain, deep-link to Settings |
| User cancellation | User backs out mid-op | Clean cancel, no side effects, no charge |

All error states get **snapshot tests** (§24.4).

---

## 29. Cloud Contract (new — gate for any generative feature)

No generative cloud feature ships until all of the following are defined and signed off. Until then, generative features are UI-only roadmap items.

- Processing provider
- Region
- Maximum retention period
- Deletion guarantees
- Encryption (in transit + at rest)
- Subprocessors
- Cost per operation
- Timeout and retry behaviour
- Content policy / moderation
- User consent flow
- Whether prompts/images are used for model training (target: **no**)

**V1 decision:** generative cloud features are removed from the delivery commitment (§0.6). Build the on-device detection/segmentation/masking now; wire the generative render only after this contract exists.

---

## 30. Telemetry Policy (new)

**Collect only**

- App crashes
- Processing duration
- Device capability tier
- Tool success/failure
- Anonymous feature usage

**Never collect**

- Photographs
- Facial attributes
- Image embeddings
- Edit contents
- Location metadata
- Natural-language prompts tied to identity

**Rules**

- Privacy-preserving identifiers only (no stable cross-app identity).
- Settings disclosure under **Privacy → Diagnostics & Usage**, with opt-out.
- Telemetry must never carry image data or derived biometric attributes.

---

## 31. Platform & Localisation Scope (new)

**Platform**

- iPhone only for V1; portrait orientation for launch and source selection.
- Editor may support landscape later.
- iPad deferred — do not ship a stretched iPhone interface as “iPad support.”

**Localisation**

- All user-visible strings in String Catalogs from the first commit.
- English-only at launch is acceptable; no hard-coded display strings.

---

## 32. Brand Mark Production Notes (new)

- Eight-ray aperture/spark mark requires a **production redraw**: slightly thicker strokes, optical spacing correction (not purely mathematical).
- Verify legibility at **16, 24, 32, 40, 60, 120, 1024 px** before locking.
- Dedicated **favicon** variant.
- Dedicated **monochrome** notification/settings variant.
- Default app icon stays predominantly **black/white with a restrained warm centre/glow** — this keeps the premium identity while nodding to photographic warmth. The fully-warm variant is an alternate, not the default.
- Name-collision note: “Lightly” exists elsewhere (e.g. lightly.ai). Disambiguated via `lightlylabs.app` / `.ai`; verify trademark classes before brand spend and expect some App Store/SEO contention.
