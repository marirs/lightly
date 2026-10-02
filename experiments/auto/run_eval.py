"""Reproducible evaluation runner for the frozen Auto protocol (PROTOCOL.json, locked by PROTOCOL.lock).

  python run_eval.py --manifest eval/dev22_manifest.csv \
      --arms original,control_levels_greyworld,research_auto100,research_guard75_hp[,run:runs/<id>] \
      --out results/<name>

Writes <out>/per_image.csv, <out>/summary.json and <out>/summary.md. Results are deterministic for a given
protocol version, manifest hash, arm set and faces.json (recorded in summary.json).
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import platform
import subprocess
import sys
import time
from dataclasses import asdict

import numpy as np
from PIL import Image

from lightly_auto.arms import build_arm
from lightly_auto.manifest import file_sha256, load_manifest, manifest_hash, resolve_source, verify_integrity
from lightly_auto.paths import AUTO_ROOT, FACES_JSON, REPO_ROOT
from lightly_auto.protocol import current_fingerprint, load_protocol
from lightly_auto.rubric import analyse_source, compute_metrics, judge_image
from lightly_auto.stats import summarise_class


def cap_threads(threads: int) -> None:
    # The machine is shared with simulator/emulator test runs; keep this process modest.
    os.environ.setdefault("OMP_NUM_THREADS", str(threads))
    import torch
    torch.set_num_threads(threads)


def load_proxy(path: str, long_edge: int) -> np.ndarray:
    image = Image.open(path).convert("RGB")
    scale = long_edge / max(image.size)
    if scale < 1.0:
        image = image.resize((round(image.width * scale), round(image.height * scale)), Image.LANCZOS)
    return np.asarray(image)


def git_commit() -> str:
    try:
        return subprocess.check_output(["git", "-C", REPO_ROOT, "rev-parse", "HEAD"], text=True).strip()
    except Exception:  # noqa: BLE001 - provenance is best-effort, never fatal
        return "unknown"


def format_bound(bound: dict) -> str:
    parts = []
    if "min" in bound:
        parts.append(f">= {bound['min']}")
    if "min_exclusive" in bound:
        parts.append(f"> {bound['min_exclusive']}")
    if "max" in bound:
        parts.append(f"<= {bound['max']}")
    return " and ".join(parts)


def render_markdown(summary: dict) -> str:
    splits = summary["manifest"]["splits"]
    if splits == ["frozen_eval"]:
        data_banner = "Data: FROZEN HELD-OUT evaluation set."
    else:
        # Coordinator/reviewer rule: development data is never reported as an evaluation result.
        data_banner = (f"Data: splits {splits} - NOT the frozen held-out set (DEV-22 is development data that M1 tuned on). "
                       "Pipeline verification only; NOT an evaluation result and NOT evidence of quality.")
    lines = [f"# Rubric run: {summary['run_name']}", "", f"**{data_banner}**", "",
             f"Protocol {summary['protocol']['version']} (lock {summary['protocol']['combined_sha256'][:12]}), "
             f"manifest `{summary['manifest']['path']}` hash {summary['manifest']['hash'][:12]}, "
             f"{summary['manifest']['n_images']} images, analysis long edge {summary['analysis_long_edge']} px.", ""]
    for arm in summary["arms"]:
        lines += [f"## {arm['arm']['name']}", "", f"**{arm['arm']['label']}**", "",
                  "| Class | n scorable | pass | pass rate | 95% CI bootstrap | 95% CI exact | S1 |",
                  "|---|---|---|---|---|---|---|"]
        for c in arm["classes"]:
            rate = "-" if c["pass_rate"] is None else f"{c['pass_rate']:.2f}"
            boot = "-" if c["pass_rate"] is None else f"{c['pass_rate_bootstrap_ci'][0]:.2f}-{c['pass_rate_bootstrap_ci'][1]:.2f}"
            exact = "-" if c["pass_rate"] is None else f"{c['pass_rate_exact_ci'][0]:.2f}-{c['pass_rate_exact_ci'][1]:.2f}"
            s1 = "not gated" if not c["gated"] else ("PASS" if c["class_passes_S1"] else "FAIL")
            unscorable = f" (+{len(c['unscorable_images'])} unscorable)" if c["unscorable_images"] else ""
            lines.append(f"| {c['rubric_class']} | {c['n_scorable']}{unscorable} | {c['n_pass']} | {rate} | {boot} | {exact} | {s1} |")
        lines += ["", "| Class | Criterion | target | n | class mean | 95% CI | mean meets |", "|---|---|---|---|---|---|---|"]
        for c in arm["classes"]:
            for k in c["criteria"]:
                lines.append(f"| {c['rubric_class']} | {k['name']} | {format_bound(k['bound'])} | {k['n']} | {k['mean']:+.2f} | "
                             f"{k['ci'][0]:+.2f} to {k['ci'][1]:+.2f} | {'yes' if k['mean_meets_target'] else 'no'} |")
        lines.append("")
    return "\n".join(lines) + "\n"


def main(argv=None) -> dict:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--arms", required=True, help="comma-separated arm specs")
    parser.add_argument("--out", required=True)
    parser.add_argument("--faces", default=FACES_JSON)
    parser.add_argument("--limit", type=int, default=0, help="first N images only (tests)")
    parser.add_argument("--threads", type=int, default=4)
    args = parser.parse_args(argv)
    cap_threads(args.threads)

    protocol = load_protocol(verify_lock=True)
    rows = load_manifest(args.manifest)
    if args.limit:
        rows = rows[: args.limit]
    integrity_problems = verify_integrity(rows)
    if integrity_problems:
        sys.exit("manifest integrity failure:\n" + "\n".join(integrity_problems))
    faces = json.load(open(args.faces)) if os.path.exists(args.faces) else {}
    arms = [build_arm(spec.strip()) for spec in args.arms.split(",") if spec.strip()]
    long_edge = protocol["analysis_resolution"]["long_edge_px"]

    per_arm_rows: dict[str, list] = {arm.name: [] for arm in arms}
    csv_rows = []
    started = time.time()
    for index, row in enumerate(rows):
        proxy = load_proxy(resolve_source(row), long_edge)
        source = analyse_source(row["rubric_class"], proxy, faces.get(row["image_id"], []))
        for arm in arms:
            output = arm.render(proxy)
            metrics = compute_metrics(source, output.image)
            verdict = judge_image(protocol, row["rubric_class"], metrics, row["labels_dict"])
            per_arm_rows[arm.name].append({"image_id": row["image_id"], "rubric_class": row["rubric_class"],
                                           "metrics": metrics, "verdict": verdict, "labels": row["labels_dict"]})
            csv_rows.append({"image_id": row["image_id"], "rubric_class": row["rubric_class"], "arm": arm.name,
                             "scorable": verdict.scorable, "passed": verdict.passed,
                             "failed_criteria": ";".join(verdict.failed_criteria),
                             "missing_criteria": ";".join(verdict.missing_criteria),
                             **{k: round(v, 4) for k, v in metrics.items()},
                             "arm_info": json.dumps(output.info, sort_keys=True)})
        print(f"[{index + 1}/{len(rows)}] {row['image_id']} ({time.time() - started:.0f}s)", flush=True)

    out_dir = os.path.join(AUTO_ROOT, args.out) if not os.path.isabs(args.out) else args.out
    os.makedirs(out_dir, exist_ok=True)
    fieldnames = sorted({k for r in csv_rows for k in r},
                        key=lambda k: (k not in ("image_id", "rubric_class", "arm", "scorable", "passed", "failed_criteria", "missing_criteria"), k == "arm_info", k))
    with open(os.path.join(out_dir, "per_image.csv"), "w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(csv_rows)

    class_order = [c for c in protocol["criteria"] if c != "skin"]
    summary = {
        "run_name": os.path.basename(out_dir.rstrip("/")),
        "protocol": current_fingerprint(),
        "manifest": {"path": os.path.relpath(os.path.abspath(args.manifest), REPO_ROOT), "hash": manifest_hash(rows), "n_images": len(rows),
                     "splits": sorted({r["split"] for r in rows})},
        "faces_json_sha256": file_sha256(args.faces) if os.path.exists(args.faces) else None,
        "analysis_long_edge": long_edge,
        "code_commit": git_commit(),
        "environment": {"python": platform.python_version(), "numpy": np.__version__,
                        "torch": __import__("torch").__version__, "skimage": __import__("skimage").__version__},
        "elapsed_s": round(time.time() - started, 1),
        "arms": [],
    }
    for arm in arms:
        classes = []
        for rubric_class in class_order:
            class_rows = [r for r in per_arm_rows[arm.name] if r["rubric_class"] == rubric_class]
            if class_rows:
                classes.append(asdict(summarise_class(protocol, rubric_class, class_rows)))
        summary["arms"].append({"arm": arm.describe(), "classes": classes})
    with open(os.path.join(out_dir, "summary.json"), "w") as handle:
        json.dump(summary, handle, indent=2, default=float)
    with open(os.path.join(out_dir, "summary.md"), "w") as handle:
        handle.write(render_markdown(summary))
    print(f"wrote {out_dir}")
    return summary


if __name__ == "__main__":
    main()
