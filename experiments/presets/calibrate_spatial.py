"""Stage 2: fit the Clarity/Texture operator on whole images with the global constants frozen.

Same family-level split as calibrate.py. Reports held-out ΔE00 with and without the spatial operator for
presets that use Clarity or Texture, and writes the final per-pair validation (global + spatial).
Usage: python calibrate_spatial.py natural
"""
import csv, json, random, sys
from pathlib import Path
import numpy as np, torch
from skimage import color
import lr_model as lm
from calibrate import data, family, held_out  # reuses loaded pairs and split (calibrate.py guards its training under __main__)

CURVE = sys.argv[1] if len(sys.argv) > 1 else "natural"
here = Path(__file__).parent
C = lm.Calib()
C.load_state_dict({k: torch.tensor(v) for k, v in json.load(open(here / f"calibration_{CURVE}.json"))["constants"].items()})
for prm in C.parameters():
    prm.requires_grad_(False)
S = lm.SpatialCalib()


def amounts(d):
    return lm._f(d["settings"], "Clarity2012"), lm._f(d["settings"], "Texture")


def full_render(d, use_spatial=True):
    x = torch.from_numpy(d["orig"])
    y = lm.render(x, d["preset"], C)
    if use_spatial:
        y = lm.apply_local_contrast(y, *amounts(d), S)
    return y


train = [d for d in data if not d["test"] and any(amounts(d))]
opt = torch.optim.Adam(S.parameters(), lr=0.005)
for step in range(300):
    loss = 0
    for d in random.sample(train, 8):
        pred = full_render(d)
        tgt = torch.from_numpy(d["lr"])
        m = torch.from_numpy(d["mask"])
        loss = loss + (lm.lin_to_oklab(lm.srgb_to_linear(pred)) - lm.lin_to_oklab(lm.srgb_to_linear(tgt)))[m].abs().mean()
    opt.zero_grad(); (loss / 8).backward(); opt.step()
    with torch.no_grad():
        S.r_clarity.clamp_(0.002, 0.1); S.r_texture.clamp_(0.0005, 0.02)
    if step % 50 == 0:
        print(step, round(float(loss / 8), 5), S.as_dict())
json.dump(S.as_dict(), open(here / f"calibration_spatial_{CURVE}.json", "w"), indent=1)

rows = []
for d in data:
    with torch.no_grad():
        a = full_render(d, False).numpy(); b = full_render(d, True).numpy()
    lab_t = color.rgb2lab(d["lr"])
    de_a = color.deltaE_ciede2000(color.rgb2lab(a), lab_t)[d["mask"]]
    de_b = color.deltaE_ciede2000(color.rgb2lab(b), lab_t)[d["mask"]]
    rows.append({"id": d["meta"]["id"], "split": "test" if d["test"] else "train", "family": family(d["meta"]), "photo": d["meta"]["colour_bins_8cube"] >= 40,
                 "uses_local_contrast": bool(any(amounts(d))), "dE_global": round(float(de_a.mean()), 2), "dE_global_spatial": round(float(de_b.mean()), 2),
                 "dE_p95_global_spatial": round(float(np.percentile(de_b, 95)), 2)})
with open(here / f"validation_spatial_{CURVE}.csv", "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0])); w.writeheader(); w.writerows(rows)
for split in ("train", "test"):
    for photo in (True, False):
        for lc in (True, False):
            r = [x for x in rows if x["split"] == split and x["photo"] == photo and x["uses_local_contrast"] == lc]
            if r:
                print(f"{split:5s} {'photo' if photo else 'card '} clarity/texture={'yes' if lc else 'no '} n={len(r):3d}  median ΔE global {np.median([x['dE_global'] for x in r]):.2f}  +spatial {np.median([x['dE_global_spatial'] for x in r]):.2f}")
