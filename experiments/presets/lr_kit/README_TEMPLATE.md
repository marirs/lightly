# Lightly — Lightroom export kit (provisional shortlist)

Purpose: get Lightroom's own renders of the provisional V1 Looks, so Lightly can measure two separate things:
1. **Global transform.** Extract each Look's pixel-independent colour/tone transform from an identity (HALD) image rendered with the *global-only* variant. Compare it with Lightroom's renders of the same global-only variant on real photographs.
2. **Full recipe.** Compare Lightly's complete recipe with Lightroom's renders of the *full* Look on the same photographs. The complete recipe is the global transform plus Lightly's own versions of the operators the global-only variant removes:
   - Highlights, Shadows, Whites, Blacks, Dehaze
   - Clarity, Texture

   Operators Lightly does not implement (vignette, grain) prevent a Look from being validated, and are listed.

Neither result is assumed.

The two **fixture cards** are needed for grain:
- `fixture_smooth` provides the smooth areas where grain can be measured.
- `fixture_textured` is detail everywhere.

Treat them exactly like the photos. For Looks with grain, a Look can't be validated unless grain was measurable on at least one input.

Exports per Look: 1 HALD + {{N}} global-only photos + {{N}} full photos. Plus {{N}} neutral photos once. Time needed: about 60–90 minutes in Lightroom Classic, mostly export time.

## Looks in this kit

| Look id | Category | Stop | Preset name | File |
|---|---|---|---|---|
{{LOOK_TABLE}}

## 1. Import

1. In **Lightroom Classic**, choose Develop → Presets panel → **+** → *Import Presets…*.
   - Select every file in `presets/full/` and `presets/global/`. These are **complete** presets: every look-relevant setting is written explicitly. `presets/original/` holds the vendor files for reference only; **do not apply them**, because some omit settings and would inherit values from a previous Look.
2. Choose *File → Import* and add `identity/hald_64_srgb16.tif` and all of `photos/`. Use **Add** (don't move or copy). **Make sure Import → "Apply During Import" has no develop preset selected.**

## Rule for every render (do not skip)

- **Every** render starts from a **fresh virtual copy of the untouched master** (the imported photo or HALD), created with *Photo → Create Virtual Copy* from the master, not from another copy.
- Before applying a Look, click **Reset** (bottom right of the Develop module) on that copy.
- **Never apply a Look to a copy that already has another Look**, and never use *Sync Settings* from a copy that had a different Look.
- If in doubt, delete the copy and make a new one from the master.

## 2. Neutrality check (no preset)

Select all {{N}} images in `photos/` (test photos plus fixture cards) and confirm none of them has any develop settings: *Reset* in the Develop module if in doubt. Then export them with the **Photo export settings** (§5), using the filename `none__{original filename}`.

## 3. Identity (HALD) render: global-only variant

For **each** Look id:
1. Create a virtual copy of the master `hald_64_srgb16.tif` and click **Reset**.
2. Apply `<look_id> [global]`.
3. Export with the **HALD export settings**, filename `<look_id>__global`.

Do not crop, straighten or touch any slider.

## 4. Photo renders: two sets per Look

For **each** Look id, do both sets. Each set uses its own fresh copies of the {{N}} **master** photos; follow the rule above.

| Set | Preset to apply | Export filename |
|---|---|---|
| Global-only | `<look_id> [global]` | `<look_id>__global__{original filename}` |
| Full | `<look_id> [full]` | `<look_id>__full__{original filename}` |

Steps for one set:
1. Create a fresh virtual copy of each of the {{N}} master photos.
2. Select the new copies and click **Reset**.
3. Apply the set's preset to all of them: select them all and click the preset with Auto Sync on.
4. Export with the **Photo export settings**.

Never reuse copies across sets or Looks.

## 5. Export settings

| Setting | HALD export | Photo export |
|---|---|---|
| Export To | Specific folder: `exports/hald` | Specific folder: `exports/photos` |
| File naming | Custom name (see above) | Custom name (see above) |
| Image Format | **TIFF** | **JPEG** |
| Compression | None | — |
| Quality | — | **100** |
| Colour Space | **sRGB** | **sRGB** |
| Bit Depth | **16 bits/component** | 8 |
| Resize to Fit | **off** | **off** |
| Output Sharpening | **off** | **off** |
| Metadata | All | All |
| Watermark | **off** | **off** |
| Post-Processing | Do nothing | Do nothing |

## 6. Return

Leave `exports/` inside this kit folder, or tell Claude where it is. Do not move or rename `photos/` or `inputs.json`. Then run `python ingest_kit.py <kit>/` from `experiments/presets/lr_kit/`. It reports, per Look:
- **global status:** extracted LUT vs your global-only exports;
- **full-recipe status:** Lightly's complete recipe vs your full exports, with any operators Lightly does not implement listed.

A Look is reported **validated** only if every one of the {{N}} inputs passes (mean ΔE00 ≤ 2 and p95 ≤ 5), every expected export exists, and the neutral baseline passes. Otherwise it is **incomplete** or **failed**, with the reason. Regenerating the kit never deletes your exports.
