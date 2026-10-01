# Lightly — Lightroom export kit (provisional shortlist)

Purpose: get Lightroom's own renders of the provisional V1 Looks, so Lightly can:
1. extract each Look's global colour/tone transform from an identity image;
2. measure how well that extracted transform reproduces Lightroom on real photographs.

Point 2 decides whether the extraction is faithful. It is **not assumed**.

Time needed: about 30–45 minutes in Lightroom Classic (most of it is waiting for exports).

## Looks in this kit

| Look id | Category | Stop | Preset name | File |
|---|---|---|---|---|
{{LOOK_TABLE}}

## 1. Import

1. In **Lightroom Classic**, choose Develop → Presets panel → **+** → *Import Presets…*.
   - Select every file in `presets/original/` and `presets/global/`.
   - `.dng` presets: import them as photos instead. Then, from each, create a preset with *Develop → New Preset* (all settings ticked) and give it the same name as the file.
2. Choose *File → Import* and add `identity/hald_64_srgb16.tif` and all of `photos/`. Use **Add** (don't move or copy). **Make sure Import → "Apply During Import" has no develop preset selected.**

## 2. Neutrality check (no preset)

Select the 22 photos and confirm none of them has any develop settings: *Reset* in the Develop module if in doubt. Then export them with the **Photo export settings** (§5), using the filename `none__{original filename}`.

## 3. Identity (HALD) renders

For **each** Look id:

1. Select `hald_64_srgb16.tif`, then choose *Photo → Create Virtual Copy*.
2. Apply the preset `<look_id>` (from `presets/original`). Export with the **HALD export settings**, filename `<look_id>__full`.
3. Make another virtual copy and apply `<look_id> [global]`. Export it with the same settings, filename `<look_id>__global`.

Do not crop, straighten or touch any slider.

## 4. Photo renders

For **each** Look id, select the 22 photos, apply the preset `<look_id>` (from `presets/original`), and export with the **Photo export settings**, filename `<look_id>__{original filename}`. Batch-apply with *Sync Settings* (all boxes ticked) after applying to one photo.

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

Zip the `exports/` folder and put it back in this kit folder, or tell Claude where it is. Then run `python ingest_kit.py <kit>/` from `experiments/presets/lr_kit/`. That:
- extracts LUTs from the HALD exports;
- applies them to the original photos;
- compares the result with your photo exports (ΔE00 per image);
- writes a report with side-by-side sheets.

Acceptance and failures are reported per Look. Nothing is marked validated automatically unless it meets the stated thresholds.
