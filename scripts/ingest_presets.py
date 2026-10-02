from __future__ import annotations
#!/usr/bin/env python3
"""
Lightly Preset Ingestion & Deduplication Pipeline
Ingests Lightroom .xmp, .lrtemplate, .dng (embedded XMP), and .cube 3D LUT files,
normalizes adjustments into Lightly recipe format, deduplicates identical recipes,
cleans preset titles, assigns categories, and outputs two structured databases:
  1. ios/Lightly/Resources/Presets/presets_photo.json (Photo recipes)
  2. ios/Lightly/Resources/Presets/luts_video.json (Video 3D LUT catalog)
"""

import os
import re
import sys
import json
import zipfile
import hashlib
from pathlib import Path
from collections import defaultdict

# ----------------------------------------------------------------------
# 1. Category Mapping Heuristics
# ----------------------------------------------------------------------

CATEGORY_KEYWORDS = {
    "aerial": ["aerial", "drone", "island", "skies", "azure", "ocean", "coast", "coastline", "sea", "altitude"],
    "landscape": ["landscape", "nature", "forest", "woodlands", "pine", "puffin", "mountain", "alpine", "nordic", "glacial", "green", "autumn", "winter", "hiking", "desert", "earth"],
    "film": ["film", "flim", "kodak", "portra", "fuji", "analog", "vintage", "retro", "35mm", "classic", "timeless", "grain", "polaroid"],
    "cinematic": ["cinematic", "cinema", "dystopia", "blade", "movie", "teal", "orange", "dark cinema", "blockbuster"],
    "golden_hour": ["golden", "sunset", "sunrise", "amber", "california", "dune", "sun", "warmth", "twilight", "dusk", "tasty"],
    "bw": ["black and white", "b&w", "black", "blvck", "mono", "monochrome", "carbon", "grey", "faded black", "noir", "dark academia"],
    "urban": ["urban", "city", "street", "metro", "neon", "lights", "night", "asphalt", "subway", "architecture", "automotive", "car"],
    "portrait": ["portrait", "skin", "nude", "editorial", "studio", "fashion", "influencer", "blogger", "fitness", "face"],
    "minimal": ["minimal", "espresso", "latte", "brown", "beige", "clean", "soft", "earthy", "home", "neutral"],
    "wedding": ["wedding", "light & airy", "light _ airy", "festive", "champagne", "romantic", "pastel", "celebration", "bride", "love"]
}

def determine_category(text: str) -> str:
    lower = text.lower()
    scores = defaultdict(int)
    for cat, keywords in CATEGORY_KEYWORDS.items():
        for kw in keywords:
            if kw in lower:
                scores[cat] += len(kw)
    
    if scores:
        best_cat = max(scores.items(), key=lambda x: x[1])[0]
        return best_cat
    return "cinematic"

# ----------------------------------------------------------------------
# 2. Name Cleaning
# ----------------------------------------------------------------------

def clean_preset_name(filename: str, parent_folder: str = "") -> str:
    name = Path(filename).stem
    
    name = re.sub(r"\.(xmp|lrtemplate|dng|cube)$", "", name, flags=re.IGNORECASE)
    name = re.sub(r"^#WL\s*-\s*\d+\s*-\s*", "", name, flags=re.IGNORECASE)
    name = re.sub(r"^#WL\s*-\s*", "", name, flags=re.IGNORECASE)
    name = re.sub(r"^(WithLuke|Huliluts|SolutionPresets)\s*-\s*", "", name, flags=re.IGNORECASE)
    name = re.sub(r"\s*(Preset|Presets|Collection|Desktop|Mobile|Android|iPhone|Mac|Windows|XMP|DNG|CUBE)\b", "", name, flags=re.IGNORECASE)
    name = re.sub(r"\s*\(\d+\)$", "", name)
    name = re.sub(r"[-_]+", " ", name)
    name = re.sub(r"\s+", " ", name).strip()
    
    if re.match(r"^\d+$", name) and parent_folder:
        clean_parent = clean_preset_name(parent_folder)
        name = f"{clean_parent} {int(name):02d}"
    
    m = re.match(r"^[A-Za-z]+\s*\d+\s*[-–]?\s*(.+)$", name)
    if m:
        name = m.group(1).strip()
        
    return name if name else Path(filename).stem

# ----------------------------------------------------------------------
# 3. XMP & LRTEMPLATE Parsers
# ----------------------------------------------------------------------

def parse_xmp_text(xml_text: str) -> dict:
    adjustments = {}
    for match in re.finditer(r'crs:([A-Za-z0-9_]+)="([^"]+)"', xml_text):
        key, val = match.group(1), match.group(2)
        adjustments[key] = val
        
    for curve_match in re.finditer(r'<crs:([A-Za-z0-9_]*ToneCurve[A-Za-z0-9_]*)>(.*?)</crs:\1>', xml_text, re.DOTALL):
        tag, body = curve_match.group(1), curve_match.group(2)
        points = re.findall(r'<rdf:li>([^<]+)</rdf:li>', body)
        if points:
            adjustments[tag] = [p.strip() for p in points]
            
    return adjustments

def parse_lrtemplate_text(lua_text: str) -> dict:
    adjustments = {}
    settings_match = re.search(r'settings\s*=\s*\{(.*?)\n\s*\}', lua_text, re.DOTALL)
    if not settings_match:
        return adjustments
        
    body = settings_match.group(1)
    for line in body.splitlines():
        line = line.strip().rstrip(",")
        if "=" in line:
            parts = line.split("=", 1)
            key = parts[0].strip()
            val = parts[1].strip().strip('"').strip("'")
            if key and val:
                adjustments[key] = val
                
    return adjustments

def extract_xmp_from_dng(dng_bytes: bytes) -> str | None:
    match = re.search(rb"<x:xmpmeta.*?</x:xmpmeta>", dng_bytes, re.DOTALL)
    if match:
        try:
            return match.group(0).decode("utf-8", errors="ignore")
        except:
            return None
    return None

def normalize_float(val, default=0.0):
    try:
        if isinstance(val, (int, float)):
            return float(val)
        if isinstance(val, str):
            return float(val.replace("+", "").strip())
    except:
        pass
    return default

def map_adjustments_to_recipe(adj: dict) -> dict:
    recipe = {
        "exposure": normalize_float(adj.get("Exposure2012", adj.get("Exposure", 0))) / 5.0,
        "contrast": normalize_float(adj.get("Contrast2012", adj.get("Contrast", 0))) / 100.0,
        "highlights": normalize_float(adj.get("Highlights2012", adj.get("Highlights", 0))) / 100.0,
        "shadows": normalize_float(adj.get("Shadows2012", adj.get("Shadows", 0))) / 100.0,
        "whites": normalize_float(adj.get("Whites2012", adj.get("Whites", 0))) / 100.0,
        "blacks": normalize_float(adj.get("Blacks2012", adj.get("Blacks", 0))) / 100.0,
        "vibrance": normalize_float(adj.get("Vibrance", 0)) / 100.0,
        "saturation": normalize_float(adj.get("Saturation", 0)) / 100.0,
        "clarity": normalize_float(adj.get("Clarity2012", adj.get("Clarity", 0))) / 100.0,
        "dehaze": normalize_float(adj.get("Dehaze", 0)) / 100.0,
        "sharpening": normalize_float(adj.get("Sharpness", 0)) / 150.0,
        "noiseReduction": normalize_float(adj.get("LuminanceSmoothing", 0)) / 100.0,
        "temperature": normalize_float(adj.get("Temperature", 0)),
        "tint": normalize_float(adj.get("Tint", 0)),
        
        "toneCurve": adj.get("ToneCurvePV2012", []),
        "toneCurveRed": adj.get("ToneCurvePV2012Red", []),
        "toneCurveGreen": adj.get("ToneCurvePV2012Green", []),
        "toneCurveBlue": adj.get("ToneCurvePV2012Blue", []),
        
        "hsl": {
            "hue": {
                "red": normalize_float(adj.get("HueAdjustmentRed", 0)),
                "orange": normalize_float(adj.get("HueAdjustmentOrange", 0)),
                "yellow": normalize_float(adj.get("HueAdjustmentYellow", 0)),
                "green": normalize_float(adj.get("HueAdjustmentGreen", 0)),
                "aqua": normalize_float(adj.get("HueAdjustmentAqua", 0)),
                "blue": normalize_float(adj.get("HueAdjustmentBlue", 0)),
                "purple": normalize_float(adj.get("HueAdjustmentPurple", 0)),
                "magenta": normalize_float(adj.get("HueAdjustmentMagenta", 0)),
            },
            "saturation": {
                "red": normalize_float(adj.get("SaturationAdjustmentRed", 0)),
                "orange": normalize_float(adj.get("SaturationAdjustmentOrange", 0)),
                "yellow": normalize_float(adj.get("SaturationAdjustmentYellow", 0)),
                "green": normalize_float(adj.get("SaturationAdjustmentGreen", 0)),
                "aqua": normalize_float(adj.get("SaturationAdjustmentAqua", 0)),
                "blue": normalize_float(adj.get("SaturationAdjustmentBlue", 0)),
                "purple": normalize_float(adj.get("SaturationAdjustmentPurple", 0)),
                "magenta": normalize_float(adj.get("SaturationAdjustmentMagenta", 0)),
            },
            "luminance": {
                "red": normalize_float(adj.get("LuminanceAdjustmentRed", 0)),
                "orange": normalize_float(adj.get("LuminanceAdjustmentOrange", 0)),
                "yellow": normalize_float(adj.get("LuminanceAdjustmentYellow", 0)),
                "green": normalize_float(adj.get("LuminanceAdjustmentGreen", 0)),
                "aqua": normalize_float(adj.get("LuminanceAdjustmentAqua", 0)),
                "blue": normalize_float(adj.get("LuminanceAdjustmentBlue", 0)),
                "purple": normalize_float(adj.get("LuminanceAdjustmentPurple", 0)),
                "magenta": normalize_float(adj.get("LuminanceAdjustmentMagenta", 0)),
            }
        },
        
        "colorGrading": {
            "shadowHue": normalize_float(adj.get("SplitToningShadowHue", adj.get("ColorGradeShadowHue", 0))),
            "shadowSat": normalize_float(adj.get("SplitToningShadowSaturation", adj.get("ColorGradeShadowSat", 0))),
            "highlightHue": normalize_float(adj.get("SplitToningHighlightHue", adj.get("ColorGradeHighlightHue", 0))),
            "highlightSat": normalize_float(adj.get("SplitToningHighlightSaturation", adj.get("ColorGradeHighlightSat", 0))),
            "balance": normalize_float(adj.get("SplitToningBalance", 0))
        },
        
        "grain": {
            "amount": normalize_float(adj.get("GrainAmount", 0)) / 100.0,
            "size": normalize_float(adj.get("GrainSize", 25)) / 100.0,
            "frequency": normalize_float(adj.get("GrainFrequency", 50)) / 100.0
        },
        "vignette": {
            "amount": normalize_float(adj.get("PostCropVignetteAmount", 0)) / 100.0,
            "midpoint": normalize_float(adj.get("PostCropVignetteMidpoint", 50)) / 100.0
        }
    }
    return recipe

def compute_recipe_hash(recipe: dict) -> str:
    s = json.dumps(recipe, sort_keys=True)
    return hashlib.sha256(s.encode("utf-8")).hexdigest()

# ----------------------------------------------------------------------
# 4. Ingestion Engine
# ----------------------------------------------------------------------

def run_ingestion(source_dir: Path, output_dir: Path):
    print(f"Starting Ingestion from: {source_dir}")
    output_dir.mkdir(parents=True, exist_ok=True)
    
    photo_presets_by_hash = {}
    video_luts_by_hash = {}
    total_scanned = 0
    
    for path in source_dir.rglob("*"):
        if not path.is_file():
            continue
            
        ext = path.suffix.lower()
        total_scanned += 1
        
        rel_path = str(path.relative_to(source_dir))
        category_context = " ".join(path.relative_to(source_dir).parts)
        category = determine_category(category_context)
        
        # A. XMP Files
        if ext == ".xmp":
            try:
                xml_text = path.read_text(errors="ignore")
                adj = parse_xmp_text(xml_text)
                if adj:
                    recipe = map_adjustments_to_recipe(adj)
                    r_hash = compute_recipe_hash(recipe)
                    clean_name = clean_preset_name(path.name, path.parent.name)
                    
                    if r_hash not in photo_presets_by_hash:
                        photo_presets_by_hash[r_hash] = {
                            "id": f"{category}.{clean_name.lower().replace(' ', '-')}-{r_hash[:6]}",
                            "name": clean_name,
                            "category": category,
                            "isIncludedInFreeTier": False,
                            "sourceFormat": "xmp",
                            "recipe": recipe,
                            "originPath": rel_path
                        }
            except:
                pass
                
        # B. LRTEMPLATE Files
        elif ext == ".lrtemplate":
            try:
                lua_text = path.read_text(errors="ignore")
                adj = parse_lrtemplate_text(lua_text)
                if adj:
                    recipe = map_adjustments_to_recipe(adj)
                    r_hash = compute_recipe_hash(recipe)
                    clean_name = clean_preset_name(path.name, path.parent.name)
                    
                    if r_hash not in photo_presets_by_hash:
                        photo_presets_by_hash[r_hash] = {
                            "id": f"{category}.{clean_name.lower().replace(' ', '-')}-{r_hash[:6]}",
                            "name": clean_name,
                            "category": category,
                            "isIncludedInFreeTier": False,
                            "sourceFormat": "lrtemplate",
                            "recipe": recipe,
                            "originPath": rel_path
                        }
            except:
                pass

        # C. DNG Files
        elif ext == ".dng":
            try:
                with open(path, "rb") as f:
                    data = f.read()
                xml_text = extract_xmp_from_dng(data)
                if xml_text:
                    adj = parse_xmp_text(xml_text)
                    if adj:
                        recipe = map_adjustments_to_recipe(adj)
                        r_hash = compute_recipe_hash(recipe)
                        clean_name = clean_preset_name(path.name, path.parent.name)
                        
                        if r_hash not in photo_presets_by_hash:
                            photo_presets_by_hash[r_hash] = {
                                "id": f"{category}.{clean_name.lower().replace(' ', '-')}-{r_hash[:6]}",
                                "name": clean_name,
                                "category": category,
                                "isIncludedInFreeTier": False,
                                "sourceFormat": "dng",
                                "recipe": recipe,
                                "originPath": rel_path
                            }
            except:
                pass

        # D. CUBE Files (3D LUTs for Video)
        elif ext == ".cube":
            try:
                content = path.read_text(errors="ignore")
                size_match = re.search(r"LUT_3D_SIZE\s+(\d+)", content)
                lut_size = int(size_match.group(1)) if size_match else 32
                lut_hash = hashlib.sha256(content.encode("utf-8")).hexdigest()
                clean_name = clean_preset_name(path.name, path.parent.name)
                
                if lut_hash not in video_luts_by_hash:
                    video_luts_by_hash[lut_hash] = {
                        "id": f"video.{category}.{clean_name.lower().replace(' ', '-')}-{lut_hash[:6]}",
                        "name": clean_name,
                        "category": category,
                        "lut3DSize": lut_size,
                        "lutHash": lut_hash,
                        "fileSizeBytes": path.stat().st_size,
                        "originPath": rel_path
                    }
            except:
                pass

        # E. ZIP Archives
        elif ext == ".zip":
            try:
                with zipfile.ZipFile(path, "r") as zf:
                    for zip_info in zf.infolist():
                        z_name = zip_info.filename
                        z_ext = Path(z_name).suffix.lower()
                        z_context = f"{rel_path} {z_name}"
                        z_cat = determine_category(z_context)
                        
                        if z_ext == ".xmp":
                            xml_text = zf.read(zip_info).decode("utf-8", errors="ignore")
                            adj = parse_xmp_text(xml_text)
                            if adj:
                                recipe = map_adjustments_to_recipe(adj)
                                r_hash = compute_recipe_hash(recipe)
                                clean_name = clean_preset_name(Path(z_name).name, Path(z_name).parent.name)
                                if r_hash not in photo_presets_by_hash:
                                    photo_presets_by_hash[r_hash] = {
                                        "id": f"{z_cat}.{clean_name.lower().replace(' ', '-')}-{r_hash[:6]}",
                                        "name": clean_name,
                                        "category": z_cat,
                                        "isIncludedInFreeTier": False,
                                        "sourceFormat": "xmp_zip",
                                        "recipe": recipe,
                                        "originPath": f"{rel_path} -> {z_name}"
                                    }
                        elif z_ext == ".dng":
                            dng_bytes = zf.read(zip_info)
                            xml_text = extract_xmp_from_dng(dng_bytes)
                            if xml_text:
                                adj = parse_xmp_text(xml_text)
                                if adj:
                                    recipe = map_adjustments_to_recipe(adj)
                                    r_hash = compute_recipe_hash(recipe)
                                    clean_name = clean_preset_name(Path(z_name).name, Path(z_name).parent.name)
                                    if r_hash not in photo_presets_by_hash:
                                        photo_presets_by_hash[r_hash] = {
                                            "id": f"{z_cat}.{clean_name.lower().replace(' ', '-')}-{r_hash[:6]}",
                                            "name": clean_name,
                                            "category": z_cat,
                                            "isIncludedInFreeTier": False,
                                            "sourceFormat": "dng_zip",
                                            "recipe": recipe,
                                            "originPath": f"{rel_path} -> {z_name}"
                                        }
                        elif z_ext == ".cube":
                            content = zf.read(zip_info).decode("utf-8", errors="ignore")
                            size_match = re.search(r"LUT_3D_SIZE\s+(\d+)", content)
                            lut_size = int(size_match.group(1)) if size_match else 32
                            lut_hash = hashlib.sha256(content.encode("utf-8")).hexdigest()
                            clean_name = clean_preset_name(Path(z_name).name, Path(z_name).parent.name)
                            if lut_hash not in video_luts_by_hash:
                                video_luts_by_hash[lut_hash] = {
                                    "id": f"video.{z_cat}.{clean_name.lower().replace(' ', '-')}-{lut_hash[:6]}",
                                    "name": clean_name,
                                    "category": z_cat,
                                    "lut3DSize": lut_size,
                                    "lutHash": lut_hash,
                                    "fileSizeBytes": zip_info.file_size,
                                    "originPath": f"{rel_path} -> {z_name}"
                                }
            except:
                pass

    photo_presets = list(photo_presets_by_hash.values())
    photo_by_cat = defaultdict(list)
    for p in photo_presets:
        photo_by_cat[p["category"]].append(p)
        
    free_tier_count = 0
    for cat, items in photo_by_cat.items():
        for item in items[:1]:
            item["isIncludedInFreeTier"] = True
            free_tier_count += 1
            
    video_luts = list(video_luts_by_hash.values())
    
    photo_db_path = output_dir / "presets_photo.json"
    video_db_path = output_dir / "luts_video.json"
    
    with open(photo_db_path, "w", encoding="utf-8") as f:
        json.dump({
            "version": "1.0",
            "type": "photo_presets",
            "totalCount": len(photo_presets),
            "freeTierCount": free_tier_count,
            "presets": photo_presets
        }, f, indent=2)
        
    with open(video_db_path, "w", encoding="utf-8") as f:
        json.dump({
            "version": "1.0",
            "type": "video_luts",
            "totalCount": len(video_luts),
            "luts": video_luts
        }, f, indent=2)
        
    print("\n" + "="*60)
    print("INGESTION & DEDUPLICATION COMPLETED SUCCESSFULLY")
    print("="*60)
    print(f"Total files scanned across directory: {total_scanned}")
    print(f"Total Unique Photo Presets:          {len(photo_presets)}")
    print(f"  -> Free Tier Presets:              {free_tier_count}")
    print(f"  -> Pro Presets:                    {len(photo_presets) - free_tier_count}")
    print(f"Total Unique Video 3D LUTs:          {len(video_luts)}")
    print("\nPhoto Presets Breakdown by Category:")
    for cat, items in sorted(photo_by_cat.items()):
        print(f"  • {cat:<15}: {len(items):>4} presets")
        
    print(f"\nSaved Photo Presets DB: {photo_db_path}")
    print(f"Saved Video LUTs DB:     {video_db_path}")

# Derived from this file's location so the script works from any checkout.
# The source packs live outside the repository (licensing, size), so there is
# no portable default for them: the caller must name the directory.
REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT_DIR = REPO_ROOT / "ios" / "Lightly" / "Resources" / "Presets"

if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(
            "usage: ingest_presets.py <source-presets-dir> [output-dir]\n"
            f"  output-dir defaults to {DEFAULT_OUTPUT_DIR.relative_to(REPO_ROOT)} in this repository"
        )
    src = Path(sys.argv[1])
    out = Path(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_OUTPUT_DIR
    run_ingestion(src, out)
