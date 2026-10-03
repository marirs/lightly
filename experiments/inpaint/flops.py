"""Count multiply-accumulates at the 512x512 app input (load-independent cost measure).

The desktop host was heavily contended during this evaluation, so GMACs are the stable number
to compare candidates by; wall-clock results are reported alongside with their load average.
LaMa is counted with the export graph (FFT replaced by exact DFT matmuls), i.e. what ships.
"""
from __future__ import annotations

import json

import torch
from torch.utils.flop_counter import FlopCounterMode

import convert
import inpaint_lib as lib


def gmacs(module: torch.nn.Module) -> float:
    image = torch.rand(1, 3, 512, 512)
    mask = torch.zeros(1, 1, 512, 512)
    mask[..., 180:330, 200:300] = 1
    counter = FlopCounterMode(display=False)
    with counter, torch.no_grad():
        module(image, mask)
    return round(counter.get_total_flops() / 2 / 1e9, 2)  # FlopCounter counts 2 FLOPs per MAC


def main() -> None:
    torch.set_num_threads(4)
    report = {}
    migan = convert.MiganExportWrapper(lib.build_migan_generator(512)).eval()
    report["migan"] = {"gmacs_512": gmacs(migan), "parameters_m": round(sum(p.numel() for p in migan.parameters()) / 1e6, 2)}
    lama_generator = lib.build_lama_generator()
    convert.patch_lama_for_export()
    lama = convert.LamaExportWrapper(lama_generator).eval()
    report["lama"] = {"gmacs_512": gmacs(lama), "parameters_m": round(sum(p.numel() for p in lama.parameters()) / 1e6, 2)}
    (lib.EXPERIMENT_ROOT / "results").mkdir(exist_ok=True)
    (lib.EXPERIMENT_ROOT / "results" / "flops.json").write_text(json.dumps(report, indent=2) + "\n")
    print(report)


if __name__ == "__main__":
    main()
