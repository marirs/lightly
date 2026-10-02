"""Plan section 6.3 sizing aid: image-to-image spread of paired metric differences, and the eval-set size
needed for an MDD of half the gap between the target and the current arm's class mean.

  python estimate_mdd.py results/dev22_baselines_v1.0.0 research_auto100 original

The spread is estimated from DEV-22 (tiny, development data), so the output is a PLANNING number for sizing
the frozen T1 set, not an evaluation result. Seed-to-seed variance is not included: no real training run
exists yet.
"""
import csv
import json
import os
import sys

import numpy as np

from lightly_auto.paths import AUTO_ROOT
from lightly_auto.protocol import load_protocol
from lightly_auto.stats import images_needed_for_mdd, minimum_detectable_difference

ABSOLUTE_METRICS = {"skin_abs_dh_deg", "warm_abs_dh_deg"}


def main(result_dir, arm, baseline):
    protocol = load_protocol(verify_lock=True)
    rows = list(csv.DictReader(open(os.path.join(AUTO_ROOT, result_dir, "per_image.csv"))))
    by_arm = {}
    for row in rows:
        by_arm.setdefault(row["arm"], {})[row["image_id"]] = row
    table = []
    for rubric_class, entry in protocol["criteria"].items():
        gated = dict(entry.get("gated", {}))
        if rubric_class == "portrait":
            gated.update(protocol["criteria"]["skin"]["gated"])
        for metric, bound in gated.items():
            pairs = [(float(r[metric]), float(by_arm[baseline][image_id][metric]))
                     for image_id, r in by_arm[arm].items()
                     if r["rubric_class"] == rubric_class and r.get(metric) not in (None, "")]
            if len(pairs) < 2:
                continue
            arm_values, base_values = np.array(pairs).T
            sigma_d = float(np.std(arm_values - base_values, ddof=1))
            target = bound.get("max", bound.get("min", bound.get("min_exclusive")))
            gap = abs(float(arm_values.mean()) - target)
            half_gap = gap / 2.0
            table.append({"class": rubric_class, "metric": metric, "n_dev": len(pairs), "arm_mean": round(float(arm_values.mean()), 2),
                          "target": target, "sigma_d": round(sigma_d, 2),
                          "mdd_at_n_dev": round(minimum_detectable_difference(sigma_d, len(pairs)), 2),
                          "mdd_at_n40": round(minimum_detectable_difference(sigma_d, 40), 2),
                          "n_for_mdd_half_gap": images_needed_for_mdd(sigma_d, half_gap) if half_gap > 0 else None})
    out = os.path.join(AUTO_ROOT, result_dir, f"mdd_{arm}_vs_{baseline}.json")
    json.dump({"arm": arm, "baseline": baseline, "source": result_dir, "note": __doc__.strip().splitlines()[-3:], "rows": table},
              open(out, "w"), indent=2)
    for row in table:
        print(row)
    print(f"wrote {out}")


if __name__ == "__main__":
    main(*sys.argv[1:4])
