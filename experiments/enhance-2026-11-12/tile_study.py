"""Enhance step 2e: general-x4v3 tile layouts against one pass over the whole photo (PyTorch fp32 on MPS).

The phones run the background on fixed-size tiles (step 2c: 256 px, 10 px kept overlap, windows clamped inside the
photo, so the last column/row of tiles keeps only a sliver). Each layout's 2x result (4x averaged 2 x 2, as the
phones) is compared with the same model run once on the whole photo, and its cost is counted as tile pixels (the GPU
time per tile scales with its pixels).
Layouts: `clamped` (step 2c) and `even` (the fewest windows that keep at least the same overlap, spread evenly; each
pixel comes from the window whose centre is nearest).
Run: .venv/bin/python tile_study.py
"""
import math
from pathlib import Path

import cv2
import numpy as np
import torch

HERE = Path(__file__).resolve().parent


def load():
    from realesrgan.archs.srvgg_arch import SRVGGNetCompact
    net = SRVGGNetCompact(num_in_ch=3, num_out_ch=3, num_feat=64, num_conv=32, upscale=4, act_type="prelu")
    net.load_state_dict(torch.load(HERE / "weights/realesr-general-x4v3/realesr-general-x4v3.pth", map_location="cpu")["params"])
    return net.eval().to("mps")


def run(net, rgb01: np.ndarray) -> np.ndarray:
    with torch.no_grad():
        up = net(torch.from_numpy(rgb01.transpose(2, 0, 1)[None].astype(np.float32)).to("mps"))[0].cpu().numpy()
    return np.clip(up, 0, 1).transpose(1, 2, 0)


def to_2x(up4: np.ndarray) -> np.ndarray:
    h, w = up4.shape[0] // 2, up4.shape[1] // 2
    return up4.reshape(h, 2, w, 2, 3).mean((1, 3)) * 255


def axis_clamped(size, tile, pad):
    keep = tile - 2 * pad
    return [(x, min(keep, size - x), min(max(x - pad, 0), size - tile)) for x in range(0, size, keep)]


def axis_even(size, tile, pad):
    """(kept start, kept length, window start): n windows spread evenly, overlaps split at their middle."""
    if size <= tile:
        return [(0, size, 0)]
    n = math.ceil((size - tile) / (tile - 2 * pad)) + 1
    starts = [round(i * (size - tile) / (n - 1)) for i in range(n)]
    cuts = [0] + [(starts[i] + tile + starts[i + 1]) // 2 for i in range(n - 1)] + [size]
    return [(cuts[i], cuts[i + 1] - cuts[i], starts[i]) for i in range(n)]


def tiled(net, rgb01, tile, pad, layout):
    h, w = rgb01.shape[:2]
    axis = axis_clamped if layout == "clamped" else axis_even
    out = np.zeros((h * 2, w * 2, 3), np.float32)
    xs, ys = axis(w, tile, pad), axis(h, tile, pad)
    for y, ch, wy in ys:
        for x, cw, wx in xs:
            up = run(net, rgb01[wy:wy + tile, wx:wx + tile])
            region = up[(y - wy) * 4:(y - wy + ch) * 4, (x - wx) * 4:(x - wx + cw) * 4]
            out[y * 2:(y + ch) * 2, x * 2:(x + cw) * 2] = to_2x(region)
    return out, len(xs) * len(ys)


def main() -> None:
    net = load()
    layouts = [(256, 10, "clamped"), (256, 10, "even"), (256, 16, "even"), (384, 16, "even"), (512, 16, "even")]
    totals = {l: [] for l in layouts}
    for folder in sorted((HERE / "outputs" / "real").iterdir()):
        if not (folder / "input.png").exists():
            continue
        rgb01 = cv2.cvtColor(cv2.imread(str(folder / "input.png")), cv2.COLOR_BGR2RGB) / 255
        whole = to_2x(run(net, rgb01))
        line = [f"{folder.name} {rgb01.shape[1]}x{rgb01.shape[0]}"]
        for tile, pad, layout in layouts:
            out, count = tiled(net, rgb01, tile, pad, layout)
            d = np.abs(out - whole).mean(2)
            cost = count * tile * tile / (rgb01.shape[0] * rgb01.shape[1])
            totals[(tile, pad, layout)].append((count, cost, float(d.mean()), float(np.percentile(d, 99.9)), float(d.max())))
            line.append(f"{tile}/{pad}/{layout}: {count} tiles, {cost:.2f}x px, mean {d.mean():.3f}, 99.9% {np.percentile(d, 99.9):.2f}")
        print(" | ".join(line), flush=True)
    for layout, values in totals.items():
        v = np.array(values)
        print(f"{layout}: tiles {v[:, 0].sum():.0f}, pixels {v[:, 1].mean():.2f}x photo, vs one pass mean {v[:, 2].mean():.3f}, "
              f"worst 99.9% {v[:, 3].max():.2f}, worst max {v[:, 4].max():.1f}")


if __name__ == "__main__":
    main()
