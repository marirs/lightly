# Look catalog and Look pack

The editor's Looks come from the curated preset collection, not from code.

| File | Committed | What it is |
|---|---|---|
| `catalog.json` | yes | Categories (opaque `id`, provisional `label`), each category's presets in browse order, with measured step sizes |
| `build_catalog.py` | yes | Regenerates `catalog.json` from `../shortlist.json` and the collection |
| `build_look_pack.py` | yes | Builds `out/` (`manifest.json` + `luts/<lookId>.f32`) from the catalog and the collection |
| `out/` | **no** (git-ignored) | The pack the apps bundle. Derived from the private collection; rebuild it, don't commit it |

```bash
python build_catalog.py                                   # only when the shortlist or ordering changes
python build_look_pack.py --hald-dir ../lr_kit/kit/exports/hald
python -m pytest tests -q
```

## Categories are data

- The five labels (Natural, Warm, Cool, Film, Mono) are **provisional**.
- To rename, merge or split categories, edit `catalog.json`. Neither app hard-codes a category name or count.
- A preset's `lookId` depends only on the preset (name slug plus a hash of its source path). Moving a preset between categories, or reordering a category, does not change its ID, so saved edits survive.

## Stop order

The slider selects a preset; it is **not** an intensity control, so stops are not sorted by strength. The order is the **shortest visual path from Auto through every preset in the category**: mean CIEDE2000 between renders on the 7 reference photos, solved exactly. Each drag to the next stop is the smallest change still available, and the slider never alternates between two characters.
- To set a human order instead, put an `orderOverride` list of lookIds on the category and rerun `build_catalog.py`; the category is then marked `"orderMethod": "override"`.
- A step under 2.0 ΔE00 is flagged `nearDuplicateOfPrevious`: the two stops may be hard to tell apart.

The numbers in brackets are the step from the previous stop, in mean ΔE00 measured with the calibrated approximation:

Stop 0 is the base with no Look. It reads **Auto** when an Auto correction is applied and **Original** when none is (today: always Original, since no Auto model ships). The order is measured from that base.

| Category (provisional) | Browse order |
|---|---|
| Natural | Base → S1 - Vibes (2.11) → S7 - Retro Mood (4.69) → Portrait-1 (4.78) → 08 (2.51) |
| Warm | Base → Earthy Wedding Tone (6) (4.9) → Nordic Tone (10) (4.15) → Adventure Tone (3) (3.56) → Golden Hour 9 (3.49) |
| Cool | Base → Cinematic Light Tone (11) (5.51) → Old Street-4 (6.54) → Black Paris Tone (11) (6.21) |
| Film | Base → Retro Wedding Tone (15) (4.11) → Rainy Tone (10) (5.02) → T2 (3.74) → C4 - Teals (4.96) |
| Mono | Base → Vintage Flim Tone (7) (11.02) → 03 Black and White 03 (1.61, near-duplicate) → 11 Black and White 11 (2.38) |

**Known limitation (approximation only):** three Looks (Retro Wedding Tone (15), Portrait-1 and 08) change abruptly at the gamut edge for fully saturated yellows (pure yellow at maximum saturation). Real photos rarely reach it. A Lightroom HALD LUT replaces the approximation once the export kit is run.

**Flag:** in Mono, "03 Black and White 03" is a small step from "Vintage Flim Tone (7)" (under the near-duplicate threshold). Review it before Mono is finalised.

## LUT source and status

| Source | When it's used | Notes |
|---|---|---|
| `lightroom-hald` | the export kit's `<kitLookId>__global.tif` exists | Lightroom's own global render |
| `lr-model-approximation` | otherwise | Today, all 18 Looks use this source. Held-out median ΔE00 4.8 vs Lightroom |

Status fields (pack format 2). Global-colour and full-recipe validation are separate and never merged:

| Field | Values | Meaning |
|---|---|---|
| `globalColour.status` | not-run · incomplete · failed · validated | Lightroom's global-only render vs the Look's LUT (`ingest_kit` "global") |
| `fullRecipe.status` | same | Lightroom's full Look vs Lightly's complete recipe (`ingest_kit` "full") |
| `conversion` | approximate · complete | `complete` only for a Lightroom-HALD LUT with no omitted operator |
| `status` | approximate · global-colour-validated · validated | promoted only by evidence about the LUT that ships |

- `status` is `validated` only for a Lightroom-HALD LUT with nothing omitted where both validations passed.
- `global-colour-validated` means a HALD LUT whose global comparison passed; effects may still be missing.
- Everything else is `approximate`, including every model-derived LUT, whatever a report says.
- Pass `--validation-report <kit>/results/report.json` to read the results; without it, every validation is `not-run`.
- Today all 18 Looks are `approximate`, with both validations `not-run`, because no Lightroom exports exist yet.
- `omittedOperators` lists what the LUT path does not render: clarity, texture, vignette and grain. For a HALD-derived LUT it also lists the adaptive tone sliders.
- `approximatedGlobally` lists what the model folds into the LUT as a global approximation.
