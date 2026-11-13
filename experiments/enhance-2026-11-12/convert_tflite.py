"""Enhance step 1c: TFLite (LiteRT) conversion of the provisional pair for the Android timing check.

Same fixed shapes as convert_coreml.py (general-x4v3: 256x256 tile; CodeFormer: 512x512 face, w=0.8 baked in), fp32
weights (the app's other LiteRT models also run fp32/fp16 at runtime). Writes tflite/<name>.tflite and compares against
PyTorch on the same input. Run: .venv/bin/python convert_tflite.py [general|codeformer]
"""
import subprocess
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
OUT = HERE / "tflite"


def convert(module, example, name: str) -> None:
    import litert_torch as ai_edge_torch  # ai-edge-torch was renamed litert-torch
    import torch

    OUT.mkdir(exist_ok=True)
    edge_model = ai_edge_torch.convert(module.eval(), (example,))
    edge_model.export(str(OUT / f"{name}.tflite"))
    with torch.no_grad():
        expected = module(example).numpy()
    actual = edge_model(example)
    actual = actual.numpy() if hasattr(actual, "numpy") else np.asarray(actual)
    print(name, "saved;", round((OUT / f"{name}.tflite").stat().st_size / 1e6, 1), "MB; max/mean abs difference:",
          float(np.abs(actual - expected).max()), float(np.abs(actual - expected).mean()), flush=True)


def convert_general() -> None:
    import torch
    from realesrgan.archs.srvgg_arch import SRVGGNetCompact

    net = SRVGGNetCompact(num_in_ch=3, num_out_ch=3, num_feat=64, num_conv=32, upscale=4, act_type="prelu")
    net.load_state_dict(torch.load(HERE / "weights/realesr-general-x4v3/realesr-general-x4v3.pth", map_location="cpu")["params"])
    convert(net, torch.rand(1, 3, 256, 256), "general-x4v3-256")


def convert_codeformer() -> None:
    sys.path.insert(0, str(HERE / "repos" / "CodeFormer"))
    import torch
    from basicsr.utils.registry import ARCH_REGISTRY
    import basicsr.archs.codeformer_arch  # noqa: F401
    from basicsr.archs.vqgan_arch import VectorQuantizer

    def codebook_lookup(self, indices, shape):
        """Same result as CodeFormer's one-hot scatter + matmul, as a plain embedding lookup: LiteRT cannot convert
        the int64 scatter."""
        z_q = self.embedding(indices.view(-1))
        return z_q.view(shape).permute(0, 3, 1, 2).contiguous() if shape is not None else z_q

    VectorQuantizer.get_codebook_feat = codebook_lookup

    net = ARCH_REGISTRY.get("CodeFormer")(dim_embd=512, codebook_size=1024, n_head=8, n_layers=9,
                                          connect_list=["32", "64", "128", "256"])
    net.load_state_dict(torch.load(HERE / "weights/codeformer/codeformer.pth", map_location="cpu",
                                   weights_only=False)["params_ema"])

    class FixedFidelity(torch.nn.Module):
        def __init__(self, inner):
            super().__init__()
            self.inner = inner

        def forward(self, face):
            return self.inner(face, w=0.8, adain=True)[0]

    convert(FixedFidelity(net.eval()), torch.rand(1, 3, 512, 512) * 2 - 1, "codeformer-w0.8-512")


if __name__ == "__main__":
    if len(sys.argv) > 1:
        {"general": convert_general, "codeformer": convert_codeformer}[sys.argv[1]]()
    else:
        for job in ("general", "codeformer"):
            subprocess.run([sys.executable, __file__, job], check=False)
