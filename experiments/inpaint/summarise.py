"""Print the markdown tables used in docs/v1/remove-evaluation.md from results/*.json."""
from __future__ import annotations

import json
import statistics
from collections import defaultdict

import inpaint_lib as lib

RESULTS = lib.EXPERIMENT_ROOT / "results"
CANDIDATES = ("lama", "lama_flex1024", "migan", "telea", "shiftmap")


def holdout_table() -> None:
    path = RESULTS / "holdout.json"
    if not path.exists():
        return
    data = json.loads(path.read_text())
    print("| Candidate | spot LPIPS ↓ | spot PSNR | stroke LPIPS ↓ | stroke PSNR | blob LPIPS ↓ | blob PSNR | wins (lowest LPIPS) |")
    print("|---|---|---|---|---|---|---|---|")
    present = [c for c in CANDIDATES if c in data and "lpips_crop" in data[c][0]]
    wins = defaultdict(int)
    by_item = defaultdict(dict)
    for candidate in present:
        for row in data[candidate]:
            by_item[(row["photo"], row["shape"])][candidate] = row["lpips_crop"]
    for scores in by_item.values():
        wins[min(scores, key=scores.get)] += 1
    for candidate in present:
        cells = []
        for shape in ("spot", "stroke", "blob"):
            rows = [r for r in data[candidate] if r["shape"] == shape]
            cells.append(f"{statistics.median(r['lpips_crop'] for r in rows):.4f}")
            cells.append(f"{statistics.median(r['psnr_masked_db'] for r in rows):.1f}")
        print(f"| {candidate} | " + " | ".join(cells) + f" | {wins[candidate]}/{len(by_item)} |")


def case_table() -> None:
    print("\n| Candidate | " + " | ".join(c.case_id for c in lib.load_cases()) + " | peak RSS MB |")
    print("|---|" + "---|" * (len(lib.load_cases()) + 1))
    for candidate in CANDIDATES:
        path = RESULTS / f"{candidate}.json"
        if not path.exists():
            continue
        data = json.loads(path.read_text())
        cells = [f"{case['inference_s_min']:.2f}" for case in data["cases"]]
        print(f"| {candidate} | " + " | ".join(cells) + f" | {data['peak_rss_mb_end']:.0f} |")


def formats_table() -> None:
    for name in ("bench_formats.json", "flops.json"):
        path = RESULTS / name
        if path.exists():
            print(f"\n{name}")
            for key, value in json.loads(path.read_text()).items():
                print(" ", key, value)
    report = lib.MODELS_DIR / "exported" / "conversion_report.json"
    if report.exists():
        print("\nconversion_report.json")
        for model, entries in json.loads(report.read_text()).items():
            for key, value in entries.items():
                print(" ", model, key, value)


if __name__ == "__main__":
    holdout_table()
    case_table()
    formats_table()
