"""Held-out synthetic-degradation evaluation (HO-SYN): objective restoration error on photos nobody tuned on.

  python eval_synthetic.py --manifest manifests/cc0ref_manifest.csv --split public_holdout_syn \
      --arms original,control_levels_greyworld,run:runs/<id> --out results/<name>

Each held-out photo (photographer-disjoint from training and validation) gets ONE degradation drawn from the
plan section 4(a) sampler with a seed derived from its sha256, so the degraded inputs are frozen by the
manifest alone (the per-image degradation is written to per_image.csv). Arms see only the degraded input,
through the deployment path (pinned 256 resize -> 33^3 LUT -> trilinear). Reported per arm:
  * degraded samples: mean dE00(output, clean) and its median/p90 across images, share improved vs input;
  * identity samples (undegraded, ~25%): mean dE00(output, input) - harm done to a photo that needed nothing.
'Original' here means "return the degraded input unchanged".

This measures how well an arm inverts SYNTHETIC global degradations of good photos. It is a held-out number,
but it is not the rubric and not human preference, and synthetic degradations are not real phone failures
(plan section 8). Report it next to, never instead of, the PH-1 rubric run.
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import time

import numpy as np
from PIL import Image
from skimage import color

from lightly_auto import synthetic
from lightly_auto.arms import build_arm
from lightly_auto.manifest import load_manifest, manifest_hash, resolve_source, verify_integrity
from lightly_auto.paths import AUTO_ROOT, REPO_ROOT
from run_eval import cap_threads, git_commit

EVAL_LONG_EDGE = 768  # held-out reference files are 960 px thumbnails; 768 keeps dE00 cheap and exact


def frozen_degradation(sha256: str) -> synthetic.Degradation:
    return synthetic.sample_degradation(np.random.default_rng(int(sha256[:16], 16)))


def load_clean(path: str) -> np.ndarray:
    image = Image.open(path).convert("RGB")
    scale = EVAL_LONG_EDGE / max(image.size)
    if scale < 1.0:
        image = image.resize((round(image.width * scale), round(image.height * scale)), Image.LANCZOS)
    return np.asarray(image)


def mean_de00(a8: np.ndarray, b8: np.ndarray) -> float:
    return float(color.deltaE_ciede2000(color.rgb2lab(a8), color.rgb2lab(b8)).mean())


def bootstrap_ci(values: list[float], seed: int = 20261002, resamples: int = 10000) -> list[float]:
    if not values:
        return [float("nan"), float("nan")]
    rng = np.random.default_rng(seed)
    data = np.asarray(values)
    means = data[rng.integers(0, len(data), (resamples, len(data)))].mean(1)
    return [float(np.percentile(means, 2.5)), float(np.percentile(means, 97.5))]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--split", default="public_holdout_syn")
    parser.add_argument("--arms", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--threads", type=int, default=4)
    args = parser.parse_args(argv)
    cap_threads(args.threads)
    rows = [r for r in load_manifest(args.manifest) if r["split"] == args.split]
    problems = verify_integrity(rows)
    if problems:
        raise SystemExit("integrity failure:\n" + "\n".join(problems))
    arms = [build_arm(spec.strip()) for spec in args.arms.split(",") if spec.strip()]
    per_image, started = [], time.time()
    for index, row in enumerate(rows):
        clean = load_clean(resolve_source(row))
        degradation = frozen_degradation(row["sha256"])
        degraded = synthetic.apply_degradation(clean, degradation)
        entry = {"image_id": row["image_id"], "identity": degradation.identity,
                 "degradation": json.dumps({k: v for k, v in degradation.__dict__.items()}, default=float),
                 "input_dE00_vs_clean": round(mean_de00(degraded, clean), 4)}
        for arm in arms:
            output = arm.render(degraded).image
            entry[f"{arm.name}::dE00_vs_clean"] = round(mean_de00(output, clean), 4)
        per_image.append(entry)
        if (index + 1) % 20 == 0:
            print(f"[{index + 1}/{len(rows)}] {time.time() - started:.0f}s", flush=True)

    summary = {"run_name": os.path.basename(args.out.rstrip("/")), "kind": "held-out synthetic-degradation evaluation (HO-SYN)",
               "manifest": {"path": os.path.relpath(os.path.abspath(args.manifest), REPO_ROOT), "split": args.split,
                            "rows_hash": manifest_hash(rows), "n_images": len(rows)},
               "n_identity": sum(e["identity"] for e in per_image), "eval_long_edge": EVAL_LONG_EDGE,
               "code_commit": git_commit(), "arms": []}
    degraded_rows = [e for e in per_image if not e["identity"]]
    identity_rows = [e for e in per_image if e["identity"]]
    for arm in arms:
        key = f"{arm.name}::dE00_vs_clean"
        degraded_values = [e[key] for e in degraded_rows]
        identity_values = [e[key] for e in identity_rows]
        summary["arms"].append({
            "arm": arm.describe(),
            "degraded_n": len(degraded_values),
            "degraded_mean_dE00_vs_clean": float(np.mean(degraded_values)),
            "degraded_mean_ci95": bootstrap_ci(degraded_values),
            "degraded_median_dE00_vs_clean": float(np.median(degraded_values)),
            "degraded_p90_dE00_vs_clean": float(np.percentile(degraded_values, 90)),
            "share_improved_vs_input": float(np.mean([e[key] < e["input_dE00_vs_clean"] for e in degraded_rows])),
            "share_worse_by_more_than_1_dE00": float(np.mean([e[key] > e["input_dE00_vs_clean"] + 1 for e in degraded_rows])),
            "identity_n": len(identity_values),
            "identity_mean_dE00_vs_input": float(np.mean(identity_values)) if identity_values else None,
            "identity_mean_ci95": bootstrap_ci(identity_values),
            "identity_share_le_1_5": float(np.mean([v <= 1.5 for v in identity_values])) if identity_values else None})
    out_dir = args.out if os.path.isabs(args.out) else os.path.join(AUTO_ROOT, args.out)
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, "per_image.csv"), "w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(per_image[0]))
        writer.writeheader()
        writer.writerows(per_image)
    json.dump(summary, open(os.path.join(out_dir, "summary.json"), "w"), indent=2)
    lines = [f"# HO-SYN: {summary['run_name']}", "",
             "**Held-out synthetic-degradation evaluation.** Photographer-disjoint CC0/PD photos, frozen per-image "
             "degradations. Measures inversion of synthetic global degradations, NOT the rubric and NOT preference.", "",
             f"Manifest `{summary['manifest']['path']}` split `{args.split}` rows hash {summary['manifest']['rows_hash'][:12]}, "
             f"{len(rows)} images ({len(degraded_rows)} degraded, {len(identity_rows)} identity).", "",
             "| Arm | degraded: mean dE00 to clean (95% CI) | median | p90 | share improved | share worse >1 | identity: mean dE00 to input (95% CI) | identity share <= 1.5 |",
             "|---|---|---|---|---|---|---|---|"]
    input_values = [e["input_dE00_vs_clean"] for e in degraded_rows]
    lines.append(f"| (degraded input itself) | {np.mean(input_values):.2f} | {np.median(input_values):.2f} | "
                 f"{np.percentile(input_values, 90):.2f} | - | - | 0.00 | 1.00 |")
    for a in summary["arms"]:
        lines.append(f"| {a['arm']['label']} | {a['degraded_mean_dE00_vs_clean']:.2f} ({a['degraded_mean_ci95'][0]:.2f}-{a['degraded_mean_ci95'][1]:.2f}) | "
                     f"{a['degraded_median_dE00_vs_clean']:.2f} | {a['degraded_p90_dE00_vs_clean']:.2f} | {a['share_improved_vs_input']:.2f} | "
                     f"{a['share_worse_by_more_than_1_dE00']:.2f} | "
                     + (f"{a['identity_mean_dE00_vs_input']:.2f} ({a['identity_mean_ci95'][0]:.2f}-{a['identity_mean_ci95'][1]:.2f})" if a["identity_n"] else "-")
                     + f" | {a['identity_share_le_1_5'] if a['identity_share_le_1_5'] is None else round(a['identity_share_le_1_5'], 2)} |")
    open(os.path.join(out_dir, "summary.md"), "w").write("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
