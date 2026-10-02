# Provisional V1 Look shortlist

Status: **provisional, for review.** Chosen by Claude from the user's collection. Nothing here is validated against Lightroom yet. The Lightroom export kit (`experiments/presets/lr_kit/`) exists to validate exactly this list.

**Shape:** 18 Looks in 5 categories. Each category's stepped slider is *Auto* followed by its Looks as discrete stops. The category labels are provisional.

**Order (superseded):** the tables below list the Looks by increasing strength, which is how they were *picked*. The slider does not use that order: it is not an intensity control. The browse order is in `experiments/presets/look_pack/catalog.json`: the shortest visual path from Auto through the category's presets, so each step is the smallest change still available.

| Category | Looks | Stops incl. Auto |
|---|---|---|
| Natural | 4 | 5 |
| Warm | 4 | 5 |
| Cool | 3 | 4 |
| Film | 4 | 5 |
| Mono | 3 | 4 |

## How they were chosen

Code: `experiments/presets/shortlist.py`. Human decisions: `experiments/presets/shortlist_review.json`. Contact sheets: `experiments/presets/contact_sheets/*.jpg`.

1. **Eligible:** 2,078 unique presets.
   - Requirements: process version 2012+; no local masks, creative profile, non-Embedded camera profile or Point Color; |Clarity| and |Texture| ≤ 15 (local contrast is experimental, spec §4.1).
   - Vignette and grain are allowed; they are planned spatial operators.
   - Duplicates were collapsed: the same settings across desktop/mobile packs count once.
2. **Measured with the calibrated approximation** (held-out median ΔE00 4.8 vs candidate Lightroom references, so indicative only) on 7 test photos and a colour chart:
   - **warmth / tint:** on the *neutral* ramp only
   - **chroma ratio**
   - **midtone contrast**
   - **black lift:** fade
   - **strength:** mean ΔE00 vs the original
   - **skin metrics** on deep, medium and light portraits: hue shift, chroma ratio, lightness change
3. **Category rules:**

   | Category | Rule |
   |---|---|
   | Natural | Near-neutral WB, chroma ×0.92–1.15, no fade, strength < 7 |
   | Warm | Warmth ≥ +3 |
   | Cool | Warmth ≤ −3 |
   | Film | Black lift ≥ +3 L*, chroma ≤ ×1.05, contrast ≤ 1.05 |
   | Mono | Grayscale conversion |

   Two guards apply on top:
   - **Every colour category:** all three skin tones within hue ≤ 6°, chroma ≤ ×1.3 and lightness −5…+7 L*.
   - **Mono:** skin lightness ≥ −8 L*.
   - Reset presets ("Clear All") and near-identity presets (strength < 1.5) are excluded.
4. **Stop selection:** stops are picked at strength quantiles within each pool, with at most one preset per family across the whole list. A preset with a candidate Lightroom DNG pair is preferred when it's otherwise equal.
5. **Visual review** of the contact sheets, in three rounds. 8 automatic picks were rejected; the reasons are recorded below and in `shortlist_review.json`.

## The Looks

The strength column is mean ΔE00 vs the original (approximate). The skin column is the worst case across the three portraits.

### Natural: clean, minimal colour change

| Stop | Preset | Strength | Character (measured) | Why chosen |
|---|---|---|---|---|
| 1 | S1 - Vibes | 2.1 | neutral WB, slight green-cyan tint, contrast unchanged; skin ≤ 2.7°, ±0.1 L* | Lightest real Look: a gentle step above Auto. **Flag:** slight green-cyan cast on the light-portrait background; verify |
| 2 | S7 - Retro Mood | 2.8 | faint warmth (+1.7), deeper shadows; skin unchanged | Adds a little depth without changing skin |
| 3 | Portrait-1 | 4.4 | neutral, slightly cooler and cleaner; skin +4 L* | Brightens faces evenly across all three skin tones |
| 4 | 08 | 6.1 | neutral, bright and airy; skin +6.4…6.8 L* | The strongest "clean" option. Lifts the whole frame without a colour cast |

### Warm: warmer neutrals, kept skin

| Stop | Preset | Strength | Character | Why chosen |
|---|---|---|---|---|
| 1 | Earthy Wedding Tone (6) | 5.0 | warmth +4.2, muted saturated colours (chroma ×0.72), slight contrast | Soft warm entry; sunsets keep their colour |
| 2 | Nordic Tone (10) | 5.8 | warmth +4.2, higher contrast (1.27) | Warm with more punch. **Pinned** after "Drone Green Tone (9)" was rejected |
| 3 | Adventure Tone (3) | 6.5 | warmth +3.3, contrast 1.16; skin −4.9 L* | Deeper and earthier. Skin darkens slightly but stays within the guard |
| 4 | Golden Hour 9 | 7.3 | strongest warmth (+5.0), muted chroma (×0.59) | A distinct golden-hour top stop. All four Warm presets have candidate Lightroom pairs |

### Cool: cooler neutrals, controlled skin

| Stop | Preset | Strength | Character | Why chosen |
|---|---|---|---|---|
| 1 | Cinematic Light Tone (11) | 5.5 | warmth −4.4, contrast 1.32; skin ≤ 4.9° | Bright, clean cool Look; the clearest of the pool |
| 2 | Old Street-4 | 6.6 | warmth −4.0, chroma ×0.55, teal shadows | A moodier cool step. Foliage desaturates, by design |
| 3 | Black Paris Tone (11) | 8.0 | warmth −4.0, strongly desaturated (×0.29) | Near-monochrome cool top stop. **Flag:** light skin desaturates toward pink; borderline, verify in Lightroom |

Only 8 presets passed the Cool rules, so Cool has 3 Looks.

### Film: faded blacks, softer contrast

| Stop | Preset | Strength | Character | Why chosen |
|---|---|---|---|---|
| 1 | Retro Wedding Tone (15) | 4.0 | black lift +6.7 L*, low contrast (0.82), mild warmth | A classic faded print. Skin hue nearly unchanged (1.5°) |
| 2 | C4 - Teals | 4.4 | black lift +5.1, teal-green shadows, muted | Cooler film character, so the slider isn't just "more fade" |
| 3 | T2 | 4.9 | black lift +3.5, warm-neutral, softer | Gentle negative-film feel |
| 4 | Rainy Tone (10) | 5.4 | strongest fade (+7.3), warm, contrast 0.87 | The most "film" top stop. Skin hue nearly unchanged (0.8°) |

### Mono

| Stop | Preset | Strength | Character | Why chosen |
|---|---|---|---|---|
| 1 | Vintage Flim Tone (7) | 11.0 | soft, slightly lifted; skin +2.4 L* | Gentle black-and-white with open shadows |
| 2 | 03 Black and White 03 | 11.3 | neutral contrast, deeper blacks | Classic black-and-white |
| 3 | 11 Black and White 11 | 11.8 | high contrast (1.24) | Punchy top stop |

## Rejected during review

Rejections that came from a rule fix are marked *(rule)*. All others are recorded in `shortlist_review.json`.

| Preset | Category tried | Reason |
|---|---|---|
| S0 - Clear All *(rule)* | Natural | A reset preset (identity), not a Look |
| Urban Night Tone (9) *(rule)* | Warm | Rendered teal/cool. This exposed a flaw in the warmth metric, now measured on neutrals |
| Moody Earthy Tone 3 *(rule)* | Warm | Darkened deep skin. This led to the skin-lightness guard |
| 09 Rich Black 09 | Cool | Greys out foliage; pushes deep skin red |
| 03 Adventure 03, 10 Drone 10 | Cool | Muddy midtones; light skin turns pink |
| Cinematic Drone Tone (family) | Film | Saturated grades without fade; not a film character |
| Drone Green Tone (9) | Warm | Reads green and muted, not warm |
| 12 Black and White 12 | Mono | Crushes the frame to near-black (deep skin −16.5 L*) |
| 02 Black and White 02 | Mono | Near-identical to "11 Black and White 11"; stops must be distinct |

## Caveats

- **Contact sheets are approximate renders** (calibrated `lr_model`), applied to *originals*, not on top of Auto. In the product, Looks apply above Auto (spec D7). Look-over-Auto combinations need re-checking once the Auto model is retrained.
- **Pools are small** for Natural (7) and Cool (8). That is a consequence of the strict skin guard and the local-contrast limit. If Lightroom validation fails for some of them, the category may shrink before it can be refilled.
- 8 of the 18 Looks have a candidate Lightroom DNG pair. All 18 need the export kit for validation.
- The names are vendor names, kept for traceability. Product-facing names are a separate decision (spec U8).
