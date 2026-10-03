"""Write the recipe→LUT parity vectors and the parity subset from a built pack.

    python shared/look-pack/make_golden.py [--pack shared/look-pack/out] [--out shared/fixtures/look-pack]

Selection is deterministic (no hand-picked ids): the first preset of every category, then greedily the
preset that covers the most still-uncovered features (every operator, coverage code, completeness class,
process version, vignette style, 2-point and spline curves, legacy split toning, grayscale), until each
feature is covered twice or the case limit is reached; then categories are topped up evenly to the target.

Expected values come from reference_model (the executable spec, float64). Each case is also checked
against lr_model (the calibrated source of truth) and the agreement is recorded.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(HERE))

import build_pack  # noqa: E402
import convert  # noqa: E402
import reference_model as rm  # noqa: E402

DEFAULT_OUT = REPO / "shared/fixtures/look-pack"
TARGET_CASES = 40
GOLDEN_LUT_DIMENSION = 17
# Tolerances for the native ports (max absolute difference per channel, encoded sRGB in [0, 1]).
TOLERANCES = {
    "lutNode": 1e-3,          # golden LUT is float16: quantisation ≤ 2.5e-4, the rest is float32 headroom
    "probeDirect": 5e-4,      # develop.global evaluated directly on a probe, float32 port vs float64 reference
    "probeViaLut33": 1e-3,    # bake 33³ then trilinear lookup, vs the same done in float64
}
# Probe colours: neutrals, primaries/secondaries, skin, sky, foliage, near-black/near-white, saturated edges.
PROBES = [
    [0.0, 0.0, 0.0], [0.02, 0.02, 0.02], [0.18, 0.18, 0.18], [0.5, 0.5, 0.5], [0.82, 0.82, 0.82], [0.98, 0.98, 0.98],
    [1.0, 1.0, 1.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0], [1.0, 1.0, 0.0], [0.0, 1.0, 1.0],
    [1.0, 0.0, 1.0], [0.87, 0.67, 0.55], [0.55, 0.38, 0.28], [0.36, 0.24, 0.18], [0.45, 0.62, 0.86],
    [0.25, 0.42, 0.16], [0.9, 0.55, 0.15], [0.12, 0.05, 0.25], [0.7, 0.1, 0.12], [0.33, 0.66, 0.6],
    [0.95, 0.9, 0.7], [0.05, 0.1, 0.08],
]


def features(entry: dict) -> set[str]:
    out = {f"op:{op}" for op in entry["operators"]}
    for kind in ("approximated", "unsupported", "notApplied"):
        out |= {f"code:{c['code']}" for c in entry[kind]}
    out.add(f"completeness:{entry['completeness']}")
    out.add(f"pv:{entry['processVersion']}")
    finishing = entry["recipe"]["finishing"]
    if "vignette" in finishing:
        out.add(f"vignetteStyle:{finishing['vignette']['style']}")
        out.add("vignette:" + ("lighten" if finishing["vignette"]["amount"] > 0 else "darken"))
    curves = entry["recipe"]["global"].get("toneCurve", {})
    for channel, points in curves.items():
        out.add(f"curve:{channel}:{'linear' if len(points) == 2 else 'spline'}")
    grading = entry["recipe"]["global"].get("colorGrading")
    if grading:
        out |= {f"grading:{zone}" for zone in ("shadows", "midtones", "highlights", "global")
                if grading[zone]["saturation"] or grading[zone]["luminance"]}
    if entry["recipe"]["global"].get("vibranceSaturation", {}).get("saturation") == -100:
        out.add("desaturated:-100")
    return out


def select(manifest: dict, target: int = TARGET_CASES) -> list[tuple[str, dict]]:
    pool = [(c["id"], p) for c in manifest["categories"] for p in c["presets"]]
    chosen: list[tuple[str, dict]] = []
    seen_ids = set()

    def take(item):
        chosen.append(item)
        seen_ids.add(item[1]["id"])

    for category in manifest["categories"]:
        take((category["id"], category["presets"][0]))
    wanted = set().union(*(features(p) for _, p in pool))
    coverage = {f: sum(1 for _, p in chosen if f in features(p)) for f in wanted}
    while len(chosen) < target:
        def gain(item):
            return sum(1 for f in features(item[1]) if coverage[f] < 2)
        candidates = [item for item in pool if item[1]["id"] not in seen_ids]
        best = max(candidates, key=lambda item: (gain(item), -int(item[1]["id"][5:13], 16)))
        if gain(best) == 0:
            break
        take(best)
        for f in features(best[1]):
            coverage[f] += 1
    # Top up evenly across categories (by stop order) so every category has several cases.
    while len(chosen) < target:
        counts = {c["id"]: sum(1 for cid, _ in chosen if cid == c["id"]) for c in manifest["categories"]}
        for category in sorted(manifest["categories"], key=lambda c: (counts[c["id"]], c["id"])):
            remaining = [p for p in category["presets"] if p["id"] not in seen_ids]
            if remaining:
                take((category["id"], remaining[len(remaining) // 2]))
                break
        else:
            break
    uncovered = sorted(f for f in wanted if not any(f in features(p) for _, p in chosen))
    if uncovered:
        raise RuntimeError(f"golden selection misses features: {uncovered}")
    return chosen


def lut_f16_bytes(lut: np.ndarray) -> bytes:
    """(N, N, N, 3) float -> little-endian float16, layout [b][g][r][rgb] (red fastest)."""
    return np.ascontiguousarray(lut, dtype="<f2").tobytes()


def write(pack_dir: Path, out: Path, target: int = TARGET_CASES) -> dict:
    manifest = json.loads((pack_dir / "manifest.json").read_text())
    contract = json.loads(rm.RENDERING_CONTRACT.read_text())
    model = contract["developModel"]
    if manifest["developModel"]["constantsSha256"] != model["constantsSha256"]:
        raise RuntimeError("the pack was built with different develop constants; rebuild it first")
    chosen = select(manifest, target)
    if out.exists():
        shutil.rmtree(out / "luts", ignore_errors=True)
    (out / "luts").mkdir(parents=True, exist_ok=True)
    probes = np.array(PROBES, dtype=np.float64)
    cases, worst_vs_model = [], 0.0
    for category_id, entry in chosen:
        recipe = entry["recipe"]
        lut17 = rm.bake_global_lut(recipe, model, GOLDEN_LUT_DIMENSION)
        data = lut_f16_bytes(lut17)
        lut_file = f"luts/{entry['id']}.lut17.f16"
        (out / lut_file).write_bytes(data)
        direct = rm.develop_global(probes, recipe, model)
        via33 = rm.apply_lut_trilinear(rm.bake_global_lut(recipe, model, 33), probes)
        cases.append({
            "presetId": entry["id"], "category": category_id, "stop": entry["stop"], "displayName": entry["displayName"],
            "lookVersion": entry["lookVersion"], "completeness": entry["completeness"],
            "covers": sorted(features(entry)),
            "lutFile": lut_file, "lutSha256": hashlib.sha256(data).hexdigest(),
            "probesDirect": np.round(direct, 7).tolist(),
            "probesViaLut33": np.round(via33, 7).tolist(),
        })
        worst_vs_model = max(worst_vs_model, _agreement_with_model(entry, probes, direct, model))
    parity = _parity_manifest(manifest, {e["id"] for _, e in chosen})
    (out / "manifest-parity.json").write_text(json.dumps(parity, ensure_ascii=False, indent=1) + "\n")
    golden = {
        "format": "lightly-look-pack-golden", "formatVersion": 1,
        "renderingContract": {"version": contract["version"], "constantsSha256": model["constantsSha256"]},
        "packManifest": "manifest-parity.json",
        "lut": {"dimension": GOLDEN_LUT_DIMENSION, "encoding": "float16 little-endian", "layout": "[b][g][r][rgb], red fastest",
                "grid": "linspace(0, 1, 17) per axis", "bytes": GOLDEN_LUT_DIMENSION ** 3 * 3 * 2},
        "probes": PROBES,
        "tolerances": TOLERANCES,
        "expectedFrom": "shared/look-pack/reference_model.py (float64)",
        "agreementWithLrModel": {"maxAbs": round(worst_vs_model, 7),
                                 "note": "same probes rendered by experiments/presets/lr_model.py from the original settings"},
        "portableRandom": portable_random_vectors(),
        "cases": cases,
    }
    (out / "golden.json").write_text(json.dumps(golden, ensure_ascii=False, indent=1) + "\n")
    return golden


_ORACLE: list = []  # one lr_model oracle, created on first use


def _agreement_with_model(entry, probes, direct, model) -> float:
    """lr_model needs the original settings, which only exist with the private library."""
    binding = _bindings().get(entry["id"])
    if binding is None:
        return 0.0
    import lrsettings  # noqa: PLC0415
    data = (build_pack.DEFAULT_PRESETS / binding["sourceFile"]).read_bytes()
    settings = lrsettings.parse_bytes(data, binding["sourceFile"], ".xmp").settings
    if not _ORACLE:
        _ORACLE.append(build_pack.ModelOracle(model))
    return float(np.abs(_ORACLE[0].render(settings, probes) - direct).max())


_BINDINGS: dict = {}


def _bindings() -> dict:
    if not _BINDINGS:
        path = build_pack.DEFAULT_PRESETS / "develop-design-catalogue.json"
        if path.exists():
            catalogue = json.loads(path.read_text())
            _BINDINGS.update({p["id"]: p for c in catalogue["categories"] for p in c["presets"]})
    return _BINDINGS


def portable_random_vectors() -> dict:
    """Grain's random source (rendering-v2.md §F2) must be identical on every platform: exact vectors."""
    inputs = [0, 1, 2, 255, 0x9E3779B1, 0xFFFFFFFF]
    field = rm.gaussian_field(2880154539, 1, 3, 4)
    return {"lowbias32": [[x, int(rm._lowbias32(x))] for x in inputs],
            "gaussianField": {"seed": 2880154539, "layer": 1, "rows": 3, "cols": 4,
                              "values": np.round(field, 9).tolist(), "tolerance": 1e-6}}


def _parity_manifest(manifest: dict, ids: set[str]) -> dict:
    """The full manifest's format restricted to the parity presets (categories keep their order and stops)."""
    subset = {k: v for k, v in manifest.items() if k not in ("categories", "summary")}
    subset["categories"] = [{"id": c["id"], "name": c["name"], "presets": [p for p in c["presets"] if p["id"] in ids]}
                            for c in manifest["categories"]]
    subset["subset"] = {"of": "full pack", "presets": len(ids),
                        "note": "stops are the full catalogue's stops (not contiguous); use for native parity tests only"}
    return subset


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pack", type=Path, default=build_pack.DEFAULT_OUT)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--cases", type=int, default=TARGET_CASES)
    args = parser.parse_args()
    golden = write(args.pack, args.out, args.cases)
    size = sum(p.stat().st_size for p in args.out.rglob("*") if p.is_file())
    print(f"{len(golden['cases'])} cases, lr_model agreement {golden['agreementWithLrModel']['maxAbs']:.2e}, "
          f"{size / 1e6:.2f} MB -> {args.out}")


if __name__ == "__main__":
    main()
