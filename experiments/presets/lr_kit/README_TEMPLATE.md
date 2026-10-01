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
   - Select every file in `presets/full/` and `presets/global/`. These are **complete** presets: every look-relevant setting is written explicitly. `presets/original/` holds the vendor files for reference only; **do not apply them**, because some omit settings and would inherit values from a previous Look.
2. Choose *File → Import* and add `identity/hald_64_srgb16.tif` and all of `photos/`. Use **Add** (don't move or copy). **Make sure Import → "Apply During Import" has no develop preset selected.**

## Rule for every render (do not skip)

- **Every** render starts from a **fresh virtual copy of the untouched master** (the imported photo or HALD), created with *Photo → Create Virtual Copy* from the master, not from another copy.
- Before applying a Look, click **Reset** (bottom right of the Develop module) on that copy.
- **Never apply a Look to a copy that already has another Look**, and never use *Sync Settings* from a copy that had a different Look.
- If in doubt, delete the copy and make a new one from the master.

## 2. Neutrality check (no preset)

Select the 22 photos and confirm none of them has any develop settings: *Reset* in the Develop module if in doubt. Then export them with the **Photo export settings** (§5), using the filename `none__{original filename}`.

## 3. Identity (HALD) renders

For **each** Look id:

1. Select `hald_64_srgb16.tif`, then choose *Photo → Create Virtual Copy*.
2. Click **Reset**, then apply the preset `<look_id> [full]`. Export with the **HALD export settings**, filename `<look_id>__full`.
3. Make another virtual copy **from the master**, click **Reset**, and apply `<look_id> [global]`. Export it with the same settings, filename `<look_id>__global`.

Do not crop, straighten or touch any slider.

## 4. Photo renders

For **each** Look id:
1. Create a fresh virtual copy of each of the 22 **master** photos.
2. Select the new copies and click **Reset**.
3. Apply the preset `<look_id> [full]` to all of them: select them all and click the preset in the Develop module with Auto Sync on.
4. Export with the **Photo export settings**, filename `<look_id>__{original filename}`.

Never reuse copies across Looks.

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
