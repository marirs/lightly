"""Conservative-gating study on the VALIDATION split only (never PH-1, never HO-SYN).

  python gate_study.py cache   --run runs/photo_a_001            # slow part: per-image, per-strength metrics
  python gate_study.py features --split train --limit 1000   # detector features (256 preview only)
  python gate_study.py features --split validation
  python gate_study.py fit-detector --out gating/detector_v1.json  # fitted on TRAIN, scored on validation
  python gate_study.py analyse --run runs/photo_a_001 --out results/gating_v1/validation

Data: CC0REF rows with split == "validation" (542 photos, session-disjoint from train, HO-SYN and PH-1).
Each photo is used twice:
  * as itself ("clean" case): a reference photo that needs nothing, the closest available stand-in for
    the already-good class. Any change the arm makes is harm;
  * with one synthetic degradation from the plan section 4(a) sampler, never identity (seeded from the
    file's sha256 with a salt distinct from HO-SYN): recovery is measured as dE00 to the clean photo.
Scene tags for night and sunset come from PD12M's machine captions (regex in SCENE_PATTERNS). They are noisy
and are used ONLY to report scene-specific harm on validation; no gate reads them.

The cache stores, for every case and every strength on gating.strength_grid(), the full-image metrics at
CACHE_LONG_EDGE together with the gate's own 256-preview profile. Any gate configuration can then be scored
offline exactly at grid strengths (linear interpolation between grid points for the soft-threshold
strength, which is continuous).
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import re
import time
from dataclasses import asdict

import numpy as np
from PIL import Image
from skimage import color

from lightly_auto import synthetic
from lightly_auto.arms import trained_run_arm
from lightly_auto.gating import (DETECTOR_FEATURES, GateConfig, PreviewProfile, choose_strength, detector_features,
                                 detector_probability, preview_profile, strength_grid)
from lightly_auto.manifest import load_manifest, resolve_source, verify_integrity
from lightly_auto.paths import AUTO_ROOT, ia3dlut as ia
from lightly_auto.rubric import analyse_source, compute_metrics

CACHE_LONG_EDGE = 384
DEGRADATION_SALT = b"gate-study-validation-v1"
SCENE_PATTERNS = {
    "night": r"\bnight|night ?time|dark sky|lit up at|street ?lights?|neon|fireworks",
    "sunset": r"sunset|sunrise|dusk|golden hour|twilight|setting sun|orange sky",
}
MANIFEST = "manifests/cc0ref_manifest.csv"
DETECTOR_PATH = "gating/detector_v1.json"
PROVENANCE = "manifests/cc0ref_provenance.csv"


def cache_path(run_dir: str) -> str:
    # Caches live under the git-ignored runs/ tree: they are derived numbers, rebuilt by this script.
    return os.path.join(AUTO_ROOT, "runs", "gate_study", os.path.basename(run_dir.rstrip("/")) + "_validation.jsonl")


def validation_degradation(sha256: str) -> synthetic.Degradation:
    seed = int(hashlib.sha256(DEGRADATION_SALT + sha256.encode()).hexdigest()[:16], 16)
    return synthetic.sample_degradation(np.random.default_rng(seed), identity_probability=0.0)


def load_image(path: str) -> np.ndarray:
    image = Image.open(path).convert("RGB")
    scale = CACHE_LONG_EDGE / max(image.size)
    if scale < 1.0:
        image = image.resize((round(image.width * scale), round(image.height * scale)), Image.LANCZOS)
    return np.asarray(image)


def scene_tags(caption: str) -> list[str]:
    return [tag for tag, pattern in SCENE_PATTERNS.items() if re.search(pattern, caption, re.I)]


def case_record(arm, input8: np.ndarray, clean8: np.ndarray, tags: list[str]) -> dict:
    import torch
    x256 = ia.prepare_256_antialiased(input8)
    with torch.no_grad():
        weights = arm.classifier(torch.from_numpy(x256).unsqueeze(0))[0].numpy()
    model_lut = ia.fuse_luts(arm.basis_luts, weights)
    profile = preview_profile(x256, model_lut)
    base = input8.astype(np.float32) / 255.0
    model_out = ia.apply_lut_reference(model_lut, base, binsize_numerator=1.0)
    lab_clean, lab_input = color.rgb2lab(clean8), color.rgb2lab(input8)
    # Scene metrics use the rubric's own definitions, with masks from the INPUT image (as the rubric does).
    scene_sources = {tag: analyse_source(tag, input8, []) for tag in tags}
    input_clip_hi = float((input8 >= 254).any(-1).mean())
    per_strength = []
    for strength in profile.strengths:
        out8 = ia.to_uint8(base + strength * (model_out - base))
        lab_out = color.rgb2lab(out8)
        entry = {"dE00_to_clean": float(color.deltaE_ciede2000(lab_clean, lab_out).mean()),
                 "dE00_to_input": float(color.deltaE_ciede2000(lab_input, lab_out).mean())}
        for tag, source in scene_sources.items():
            metrics = compute_metrics(source, out8)
            if tag == "night":
                entry.update(night_p50_dL=metrics["night_p50_dL"], clipLo_pp=metrics["clipLo_pp"])
            if tag == "sunset" and "warm_chroma_ratio" in metrics:
                entry.update(warm_chroma_ratio=metrics["warm_chroma_ratio"], warm_abs_dh_deg=metrics["warm_abs_dh_deg"])
        entry["clipHi_pp"] = (float((out8 >= 254).any(-1).mean()) - input_clip_hi) * 100.0  # rubric definition
        per_strength.append(entry)
    return {"profile": asdict(profile), "per_strength": per_strength, "weights": weights.round(4).tolist()}


def build_cache(run_dir: str, threads: int) -> None:
    import torch
    torch.set_num_threads(threads)
    arm = trained_run_arm(run_dir)
    rows = [r for r in load_manifest(MANIFEST) if r["split"] == "validation"]
    problems = verify_integrity(rows)
    if problems:
        raise SystemExit("integrity failure:\n" + "\n".join(problems))
    captions = {r["image_id"]: r["caption"] for r in csv.DictReader(open(PROVENANCE))}
    path = cache_path(run_dir)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    done = set()
    if os.path.exists(path):
        done = {json.loads(line)["image_id"] for line in open(path)}
    started = time.time()
    with open(path, "a") as handle:
        for index, row in enumerate(rows):
            if row["image_id"] in done:
                continue
            clean = load_image(resolve_source(row))
            degradation = validation_degradation(row["sha256"])
            degraded = synthetic.apply_degradation(clean, degradation)
            tags = scene_tags(captions[row["image_id"]])
            record = {"image_id": row["image_id"], "tags": tags,
                      "degradation": json.loads(json.dumps(degradation.__dict__, default=float)),
                      "clean_case": case_record(arm, clean, clean, tags),
                      "degraded_case": case_record(arm, degraded, clean, [])}
            handle.write(json.dumps(record) + "\n")
            handle.flush()
            if (index + 1) % 25 == 0:
                print(f"[{index + 1}/{len(rows)}] {time.time() - started:.0f}s", flush=True)


# ------------------------------------------------------------------------------------------------ detector

def features_path(run_dir: str, split: str) -> str:
    return os.path.join(AUTO_ROOT, "runs", "gate_study", f"{os.path.basename(run_dir.rstrip('/'))}_features_{split}.jsonl")


def split_degradation(sha256: str, split: str) -> synthetic.Degradation:
    # Validation keeps the cache's salt so detector features and cached metrics describe the same inputs.
    if split == "validation":
        return validation_degradation(sha256)
    seed = int(hashlib.sha256(b"gate-study-" + split.encode() + sha256.encode()).hexdigest()[:16], 16)
    return synthetic.sample_degradation(np.random.default_rng(seed), identity_probability=0.0)


def build_features(run_dir: str, split: str, limit: int, threads: int) -> None:
    import torch
    torch.set_num_threads(threads)
    arm = trained_run_arm(run_dir)
    rows = sorted((r for r in load_manifest(MANIFEST) if r["split"] == split), key=lambda r: r["sha256"])
    if limit:
        rows = rows[:limit]  # sha256 order = a fixed pseudo-random subset
    path = features_path(run_dir, split)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        for index, row in enumerate(rows):
            clean = load_image(resolve_source(row))
            degraded = synthetic.apply_degradation(clean, split_degradation(row["sha256"], split))
            for case_name, image in (("clean_case", clean), ("degraded_case", degraded)):
                x256 = ia.prepare_256_antialiased(image)
                with torch.no_grad():
                    weights = arm.classifier(torch.from_numpy(x256).unsqueeze(0))[0].numpy()
                profile = preview_profile(x256, ia.fuse_luts(arm.basis_luts, weights))
                handle.write(json.dumps({"image_id": row["image_id"], "case": case_name,
                                         "features": detector_features(x256, weights, profile)}) + "\n")
            if (index + 1) % 100 == 0:
                print(f"[{index + 1}/{len(rows)}]", flush=True)


def fit_detector(run_dir: str, out_path: str) -> None:
    from sklearn.linear_model import LogisticRegression
    from sklearn.metrics import roc_auc_score

    def load(split):
        records = [json.loads(line) for line in open(features_path(run_dir, split))]
        x = np.array([[r["features"][name] for name in DETECTOR_FEATURES] for r in records])
        y = np.array([r["case"] == "degraded_case" for r in records], int)
        return x, y

    x_train, y_train = load("train")
    x_val, y_val = load("validation")
    mean, scale = x_train.mean(0), x_train.std(0) + 1e-9
    model = LogisticRegression(C=1.0, max_iter=2000).fit((x_train - mean) / scale, y_train)
    detector = {"kind": "logistic regression: P(photo needs correction) from 256-preview features",
                "fitted_on": f"CC0REF train split, {len(y_train) // 2} photos x (clean, one synthetic degradation)",
                "run": os.path.basename(run_dir.rstrip("/")), "features": DETECTOR_FEATURES,
                "mean": mean.tolist(), "scale": scale.tolist(), "coef": model.coef_[0].tolist(),
                "intercept": float(model.intercept_[0])}
    p_train = [detector_probability(dict(zip(DETECTOR_FEATURES, row)), detector) for row in x_train]
    p_val = [detector_probability(dict(zip(DETECTOR_FEATURES, row)), detector) for row in x_val]
    detector["auc_train"] = round(float(roc_auc_score(y_train, p_train)), 4)
    detector["auc_validation"] = round(float(roc_auc_score(y_val, p_val)), 4)
    out = out_path if os.path.isabs(out_path) else os.path.join(AUTO_ROOT, out_path)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    json.dump(detector, open(out, "w"), indent=2)
    print(f"detector AUC train {detector['auc_train']}, validation {detector['auc_validation']} -> {out}")


# ------------------------------------------------------------------------------------------------ analysis

def interpolate(per_strength: list[dict], strengths: list[float], strength: float, key: str) -> float | None:
    values = [entry.get(key) for entry in per_strength]
    if any(v is None for v in values):
        return None
    return float(np.interp(strength, strengths, values))


def score_gate(records: list[dict], config: GateConfig | None, detector_p: dict | None = None) -> dict:
    """config None = ungated model (s = 1). detector_p maps (image_id, case) -> probability."""
    grid = strength_grid().tolist()
    clean_dE, clean_s, degraded_dE, degraded_in, degraded_full, degraded_s = [], [], [], [], [], []
    night_fail, night_lift, sunset_fail, clip_hi_fail = [], [], [], []
    for record in records:
        for case_name in ("clean_case", "degraded_case"):
            case = record[case_name]
            profile = PreviewProfile(**case["profile"])
            p = None if detector_p is None else detector_p.get((record["image_id"], case_name))
            strength = 1.0 if config is None else choose_strength(profile, config, p)[0]
            ps = case["per_strength"]
            if case_name == "clean_case":
                clean_dE.append(interpolate(ps, grid, strength, "dE00_to_input"))
                clean_s.append(strength)
                clip_hi_fail.append(interpolate(ps, grid, strength, "clipHi_pp") > 0.5)
                if "night" in record["tags"]:
                    lift = interpolate(ps, grid, strength, "night_p50_dL")
                    night_lift.append(lift)
                    night_fail.append(lift > 3.0 or interpolate(ps, grid, strength, "clipLo_pp") > 0.5)
                if "sunset" in record["tags"] and ps[0].get("warm_chroma_ratio") is not None:
                    ratio = interpolate(ps, grid, strength, "warm_chroma_ratio")
                    dh = interpolate(ps, grid, strength, "warm_abs_dh_deg")
                    sunset_fail.append(not (0.95 <= ratio <= 1.10) or dh > 4.0)
            else:
                degraded_dE.append(interpolate(ps, grid, strength, "dE00_to_clean"))
                degraded_in.append(ps[0]["dE00_to_clean"])
                degraded_full.append(ps[-1]["dE00_to_clean"])
                degraded_s.append(strength)
    clean_dE, degraded_dE = np.array(clean_dE), np.array(degraded_dE)
    degraded_in, degraded_full = np.array(degraded_in), np.array(degraded_full)
    full_gain = (degraded_in - degraded_full).sum()
    return {
        "gate": None if config is None else config.to_dict(),
        "clean_n": len(clean_dE),
        "clean_mean_dE00_to_input": float(clean_dE.mean()),
        "clean_share_le_0_5": float((clean_dE <= 0.5).mean()),
        "clean_share_le_1_5": float((clean_dE <= 1.5).mean()),
        "clean_share_le_3": float((clean_dE <= 3.0).mean()),
        "clean_share_untouched_s0": float(np.mean(np.array(clean_s) == 0.0)),
        "clean_share_new_highlight_clip_gt_0_5pp": float(np.mean(clip_hi_fail)),
        "degraded_n": len(degraded_dE),
        "degraded_input_mean_dE00": float(degraded_in.mean()),
        "degraded_mean_dE00_to_clean": float(degraded_dE.mean()),
        "degraded_share_improved": float((degraded_dE < degraded_in).mean()),
        "degraded_share_worse_by_gt_1": float((degraded_dE > degraded_in + 1).mean()),
        "degraded_recovery_retained": float((degraded_in - degraded_dE).sum() / full_gain) if full_gain > 0 else None,
        "degraded_mean_strength": float(np.mean(degraded_s)),
        "night_tagged_clean_n": len(night_fail),
        "night_tagged_fail_rate": float(np.mean(night_fail)) if night_fail else None,
        "night_tagged_mean_p50_dL": float(np.mean(night_lift)) if night_lift else None,
        "sunset_tagged_clean_n": len(sunset_fail),
        "sunset_tagged_fail_rate": float(np.mean(sunset_fail)) if sunset_fail else None,
    }


CANDIDATES = (
    [None]
    + [GateConfig(f"deadzone_{t:g}", predicted_change_deadzone_dE00=t) for t in (1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 5.0)]
    + [GateConfig("scene_only", use_scene_constraints=True)]
    + [GateConfig(f"deadzone_{t:g}+scene", predicted_change_deadzone_dE00=t, use_scene_constraints=True)
       for t in (1.5, 2.0, 2.5, 3.0, 3.5, 4.0)]
)


def analyse(run_dir: str, out_dir: str, extra_configs: list[str]) -> None:
    records = [json.loads(line) for line in open(cache_path(run_dir))]
    configs = list(CANDIDATES) + [GateConfig.load(path) for path in extra_configs]
    detector_p = None
    detector_file = os.path.join(AUTO_ROOT, DETECTOR_PATH)
    if os.path.exists(detector_file) and os.path.exists(features_path(run_dir, "validation")):
        detector = json.load(open(detector_file))
        detector_p = {(r["image_id"], r["case"]): detector_probability(r["features"], detector)
                      for r in map(json.loads, open(features_path(run_dir, "validation")))}
        configs += [GateConfig(f"detector_{t:g}", detector_path=DETECTOR_PATH, detector_threshold=t) for t in (0.4, 0.5, 0.6, 0.7)]
        configs += [GateConfig(f"detector_{t:g}+scene", detector_path=DETECTOR_PATH, detector_threshold=t,
                               use_scene_constraints=True) for t in (0.5, 0.6, 0.7)]
        configs += [GateConfig(f"detector_{t:g}+deadzone_{d:g}+scene", detector_path=DETECTOR_PATH, detector_threshold=t,
                               predicted_change_deadzone_dE00=d, use_scene_constraints=True)
                    for t in (0.5, 0.6) for d in (1.0, 1.5, 2.0)]
    results = [score_gate(records, config, detector_p) for config in configs]
    # Separability of the already-good gate's only input: predicted change on clean vs degraded cases.
    clean_m = np.array([r["clean_case"]["profile"]["predicted_change_dE00"] for r in records])
    degraded_m = np.array([r["degraded_case"]["profile"]["predicted_change_dE00"] for r in records])
    degraded_err = np.array([r["degraded_case"]["per_strength"][0]["dE00_to_clean"] for r in records])
    thresholds = np.linspace(0, 10, 101)
    tpr = [(degraded_m > t).mean() for t in thresholds]
    fpr = [(clean_m > t).mean() for t in thresholds]
    auc = float(-np.trapezoid(tpr, fpr))
    separability = {"clean_predicted_change_quantiles": np.percentile(clean_m, [10, 25, 50, 75, 90]).round(3).tolist(),
                    "degraded_predicted_change_quantiles": np.percentile(degraded_m, [10, 25, 50, 75, 90]).round(3).tolist(),
                    "auc_predicted_change_clean_vs_degraded": round(auc, 4),
                    "spearman_predicted_change_vs_degradation_error": round(float(
                        np.corrcoef(np.argsort(np.argsort(degraded_m)), np.argsort(np.argsort(degraded_err)))[0, 1]), 4)}
    os.makedirs(out_dir, exist_ok=True)
    summary = {"kind": "conservative-gating study, VALIDATION split only (tuning data, not an evaluation)",
               "run": os.path.basename(run_dir.rstrip("/")), "n_images": len(records),
               "n_night_tagged": sum("night" in r["tags"] for r in records),
               "n_sunset_tagged": sum("sunset" in r["tags"] for r in records),
               "cache_long_edge": CACHE_LONG_EDGE, "separability": separability, "gates": results}
    json.dump(summary, open(os.path.join(out_dir, "summary.json"), "w"), indent=2)
    lines = ["# Conservative gating: validation split only (tuning data, NOT an evaluation)", "",
             f"Run `{summary['run']}`, {len(records)} CC0REF validation photos, each scored clean (needs nothing) and "
             f"with one synthetic degradation. Night-tagged {summary['n_night_tagged']}, sunset-tagged "
             f"{summary['n_sunset_tagged']} (machine captions; noisy). Metrics at {CACHE_LONG_EDGE} px long edge.", "",
             f"Predicted change (the already-good gate's input), clean vs degraded: AUC {separability['auc_predicted_change_clean_vs_degraded']}; "
             f"clean quantiles p10/25/50/75/90 {separability['clean_predicted_change_quantiles']}, "
             f"degraded {separability['degraded_predicted_change_quantiles']}.", "",
             "| Gate | clean: mean dE00 to input | clean <= 1.5 | clean untouched | degraded: mean dE00 to clean (input "
             f"{results[0]['degraded_input_mean_dE00']:.2f}) | recovery retained | degraded improved | night-tagged fail | night mean p50 dL | sunset-tagged fail |",
             "|---|---|---|---|---|---|---|---|---|---|"]
    for r in results:
        name = "ungated model" if r["gate"] is None else r["gate"]["gate_id"]
        lines.append(f"| {name} | {r['clean_mean_dE00_to_input']:.2f} | {r['clean_share_le_1_5']:.2f} | {r['clean_share_untouched_s0']:.2f} | "
                     f"{r['degraded_mean_dE00_to_clean']:.2f} | {r['degraded_recovery_retained']:.2f} | {r['degraded_share_improved']:.2f} | "
                     f"{r['night_tagged_fail_rate']:.2f} | {r['night_tagged_mean_p50_dL']:+.2f} | {r['sunset_tagged_fail_rate']:.2f} |")
    open(os.path.join(out_dir, "summary.md"), "w").write("\n".join(lines) + "\n")
    print("\n".join(lines))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["cache", "features", "fit-detector", "analyse"])
    parser.add_argument("--split", default="validation")
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--run", default="runs/photo_a_001")
    parser.add_argument("--out", default="results/gating_v1/validation")
    parser.add_argument("--config", action="append", default=[], help="extra gate config JSON to score (analyse)")
    parser.add_argument("--threads", type=int, default=2)
    args = parser.parse_args(argv)
    run_dir = args.run if os.path.isabs(args.run) else os.path.join(AUTO_ROOT, args.run)
    if args.command == "cache":
        build_cache(run_dir, args.threads)
    elif args.command == "features":
        build_features(run_dir, args.split, args.limit, args.threads)
    elif args.command == "fit-detector":
        fit_detector(run_dir, args.out if args.out != "results/gating_v1/validation" else DETECTOR_PATH)
    else:
        out_dir = args.out if os.path.isabs(args.out) else os.path.join(AUTO_ROOT, args.out)
        analyse(run_dir, out_dir, args.config)


if __name__ == "__main__":
    main()
