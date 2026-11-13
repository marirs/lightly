"""Enhance step 1c: TFLite (LiteRT) conversion of the provisional pair for the Android timing check.

Same fixed shapes as convert_coreml.py (general-x4v3: 256x256 tile; CodeFormer: 512x512 face, w=0.8 baked in), fp32
weights (the app's other LiteRT models also run fp32/fp16 at runtime). Writes tflite/<name>.tflite and compares against
PyTorch on the same input. Run: .venv/bin/python convert_tflite.py [general|codeformer|codeformer-gpu|codeformer-split]
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


def convert_codeformer(gpu_friendly: bool = False) -> None:
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

    name = "codeformer-w0.8-512"
    if gpu_friendly:
        # Step 1d: codebook pick as sharpened softmax x codebook, so the GPU delegate gets the whole graph.
        import types
        sys.path.insert(0, str(HERE))
        import codeformer_gpu
        net.forward = types.MethodType(codeformer_gpu.forward_gpu_friendly, net)
        torch.nn.GroupNorm.forward = codeformer_gpu.group_norm_without_big_reshape
        from basicsr.archs.vqgan_arch import AttnBlock
        AttnBlock.forward = codeformer_gpu.attention_block_4d
        name = "codeformer-gpu-w0.8-512"
    convert(FixedFidelity(net.eval()), torch.rand(1, 3, 512, 512) * 2 - 1, name)


def convert_codeformer_split() -> None:
    """Step 1d: encoder (GPU) / middle (CPU) / decoder (GPU), see codeformer_split.py. Checks the chained TFLite
    models against the original CodeFormer on a real aligned face."""
    sys.path.insert(0, str(HERE / "repos" / "CodeFormer"))
    sys.path.insert(0, str(HERE))
    import litert_torch
    import torch
    from basicsr.utils.registry import ARCH_REGISTRY
    import basicsr.archs.codeformer_arch  # noqa: F401
    from basicsr.archs.vqgan_arch import AttnBlock
    import codeformer_gpu
    import codeformer_split

    net = ARCH_REGISTRY.get("CodeFormer")(dim_embd=512, codebook_size=1024, n_head=8, n_layers=9,
                                          connect_list=["32", "64", "128", "256"])
    net.load_state_dict(torch.load(HERE / "weights/codeformer/codeformer.pth", map_location="cpu",
                                   weights_only=False)["params_ema"])
    net.eval()
    face = torch.from_numpy(np.fromfile(HERE / "outputs/phone-faces/sepia.bin", dtype="<f4").reshape(1, 3, 512, 512))
    with torch.no_grad():
        reference = net(face, w=0.8, adain=True)[0].numpy()

    torch.nn.GroupNorm.forward = codeformer_gpu.group_norm_without_big_reshape
    AttnBlock.forward = codeformer_gpu.attention_block_4d
    parts = {}
    with torch.no_grad():
        encoded = codeformer_split.Encoder(net).eval()(face)
        quantised = codeformer_split.Middle(net).eval()(encoded[0])
    for name, module, example in (("encoder", codeformer_split.Encoder(net), (face,)),
                                  ("middle", codeformer_split.Middle(net), (encoded[0],)),
                                  ("decoder", codeformer_split.Decoder(net), (quantised,) + tuple(encoded[1:]))):
        parts[name] = litert_torch.convert(module.eval(), example)
        parts[name].export(str(OUT / f"codeformer-{name}.tflite"))
        print("saved", name, round((OUT / f"codeformer-{name}.tflite").stat().st_size / 1e6, 1), "MB", flush=True)

    def as_tuple(result):
        return tuple(result) if isinstance(result, (tuple, list)) else (result,)

    encoded_tflite = as_tuple(parts["encoder"](face))
    quantised_tflite = as_tuple(parts["middle"](torch.from_numpy(np.asarray(encoded_tflite[0]))))[0]
    restored = as_tuple(parts["decoder"](*(torch.from_numpy(np.asarray(t)) for t in (quantised_tflite,) + encoded_tflite[1:])))[0]
    difference = np.abs(np.asarray(restored) - reference) * 127.5
    print("chained TFLite vs original CodeFormer (0-255): mean", float(difference.mean()), "max", float(difference.max()))


if __name__ == "__main__":
    if len(sys.argv) > 1:
        {"general": convert_general, "codeformer": convert_codeformer,
         "codeformer-gpu": lambda: convert_codeformer(gpu_friendly=True), "codeformer-split": convert_codeformer_split}[sys.argv[1]]()
    else:
        for job in ("general", "codeformer"):
            subprocess.run([sys.executable, __file__, job], check=False)
