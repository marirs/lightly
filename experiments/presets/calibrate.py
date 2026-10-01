"""Calibrate lr_model constants on (original, Lightroom render) pairs and report held-out accuracy.

Split: by preset FAMILY (parent folder), deterministic hash -> ~20% of families held out, so no held-out preset
shares a family with a training preset. Both images get a 1 px Gaussian blur (suppresses grain and the
preview's JPEG noise); if the preset has a vignette, only the central 60% of the frame is scored.
Metric: CIEDE2000 between our render and Lightroom's, per pair (mean and p95 over pixels).
Baselines: identity (no preset applied) and the uncalibrated model.
Outputs: calibration.json, validation.csv, sheets/<id>.jpg for held-out pairs
"""
import csv, hashlib, json, random, sys
from pathlib import Path
import numpy as np
import torch
from PIL import Image, ImageFilter, ImageDraw, ImageFont
from skimage import color
import lr_model as lm

torch.manual_seed(0); random.seed(0)
here = Path(__file__).parent
pairs_dir = here / "pairs"
index = json.load(open(pairs_dir / "index.json"))["pairs"]
CURVE = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] in ("natural", "pchip") else "natural"


def family(m):
    return str(Path(m["source"]).parent)


def held_out(m):
    return int(hashlib.sha1(family(m).encode()).hexdigest(), 16) % 5 == 0


def load(m):
    d = pairs_dir / m["id"]
    s = json.load(open(d / "settings.json"))
    o = Image.open(d / "original.png").convert("RGB").filter(ImageFilter.GaussianBlur(1))
    r = Image.open(d / "lightroom.png").convert("RGB").filter(ImageFilter.GaussianBlur(1))
    o, r = np.asarray(o, np.float32) / 255, np.asarray(r, np.float32) / 255
    h, w = o.shape[:2]
    mask = np.ones((h, w), bool)
    if abs(lm._f(s, "PostCropVignetteAmount")) > 0:
        mask[:] = False; mask[int(.2 * h):int(.8 * h), int(.2 * w):int(.8 * w)] = True
    return s, o, r, mask


data = []
for m in index:
    s, o, r, mask = load(m)
    data.append({"meta": m, "settings": s, "orig": o, "lr": r, "mask": mask, "test": held_out(m),
                 "preset": lm.Preset(s, curve_method=CURVE, wb_mode="dng")})
train = [d for d in data if not d["test"]]
test = [d for d in data if d["test"]]
print(f"pairs {len(data)} train {len(train)} test {len(test)} (families held out: {len({family(d['meta']) for d in test})})")


def score(d, C):
    with torch.no_grad():
        out = lm.render(torch.from_numpy(d["orig"]), d["preset"], C).numpy()
    de = color.deltaE_ciede2000(color.rgb2lab(out), color.rgb2lab(d["lr"]))[d["mask"]]
    return float(de.mean()), float(np.percentile(de, 95)), out


def identity_score(d):
    de = color.deltaE_ciede2000(color.rgb2lab(d["orig"]), color.rgb2lab(d["lr"]))[d["mask"]]
    return float(de.mean())


def main():
    C = lm.Calib()
    init = {d["meta"]["id"]: score(d, C)[0] for d in test}
    opt = torch.optim.Adam(C.parameters(), lr=0.01)
    for step in range(1500):
        batch = random.sample(train, 24)
        loss = 0
        for d in batch:
            idx = np.flatnonzero(d["mask"].ravel())
            sel = np.random.choice(idx, 2048)
            x = torch.from_numpy(d["orig"].reshape(-1, 3)[sel]); y = torch.from_numpy(d["lr"].reshape(-1, 3)[sel])
            pred = lm.render(x, d["preset"], C)
            loss = loss + (lm.lin_to_oklab(lm.srgb_to_linear(pred)) - lm.lin_to_oklab(lm.srgb_to_linear(y))).abs().mean()
        loss = loss / len(batch)
        opt.zero_grad(); loss.backward()
        for prm in C.parameters():
            if prm.grad is not None: prm.grad.nan_to_num_(0.0)
        torch.nn.utils.clip_grad_norm_(C.parameters(), 1.0); opt.step()
        if step % 100 == 0:
            print(step, round(float(loss), 5))
    json.dump({"curve_method": CURVE, "constants": C.as_dict()}, open(here / f"calibration_{CURVE}.json", "w"), indent=1)

    rows = []
    sheets = here / "sheets"; sheets.mkdir(exist_ok=True)
    font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 14)
    for d in data:
        mean, p95, out = score(d, C)
        row = {"id": d["meta"]["id"], "split": "test" if d["test"] else "train", "family": family(d["meta"]), "name": Path(d["meta"]["source"]).stem,
               "colour_bins": d["meta"]["colour_bins_8cube"], "dE_identity": round(identity_score(d), 2),
               "dE_uncalibrated": round(init.get(d["meta"]["id"], float("nan")), 2), "dE_mean": round(mean, 2), "dE_p95": round(p95, 2)}
        rows.append(row)
        if d["test"]:
            tiles = [d["orig"], out, d["lr"]]
            im = Image.new("RGB", (3 * 260 + 10, 290), (24, 24, 26)); dr = ImageDraw.Draw(im)
            for i, (t, lab) in enumerate(zip(tiles, ("Original", f"Lightly (ΔE00 {mean:.1f})", "Lightroom"))):
                im.paste(Image.fromarray((t * 255).astype(np.uint8)).resize((256, 256)), (5 + i * 260, 30)); dr.text((5 + i * 260, 8), lab, fill=(230, 230, 230), font=font)
            im.save(sheets / f"{d['meta']['id']}.jpg", quality=85)
    with open(here / f"validation_{CURVE}.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0])); w.writeheader(); w.writerows(rows)
    for split in ("train", "test"):
        for photo in (True, False):
            r = [x for x in rows if x["split"] == split and (x["colour_bins"] >= 40) == photo]
            if not r: continue
            f = lambda k: np.median([x[k] for x in r])
            print(f"{split:5s} {'photo' if photo else 'card ':5s} n={len(r):3d}  median dE: identity {f('dE_identity'):.2f}  calibrated {f('dE_mean'):.2f}  p95 {f('dE_p95'):.2f}"
                  + (f"  uncalibrated {f('dE_uncalibrated'):.2f}" if split == 'test' else ""))


if __name__ == "__main__":
    main()
