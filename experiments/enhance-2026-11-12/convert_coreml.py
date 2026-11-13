"""Enhance step 1c: Core ML conversion of the provisional pair for the iPhone timing check.

  general-x4v3: one fixed 256x256 tile -> 1024x1024 (the app would tile larger photos), fp16 mlprogram.
  CodeFormer:   one aligned 512x512 face, fidelity w=0.8 baked in (owner preference), fp16 mlprogram.
Inputs and outputs are float tensors in the models' own ranges ([0,1] for ESRGAN, [-1,1] for CodeFormer).
Writes coreml/<name>.mlpackage and checks each against PyTorch on a random input.
Run: .venv/bin/python convert_coreml.py [general|codeformer|codeformer-gn]  (CodeFormer runs in a child process: it needs the repo's basicsr)
"""
import subprocess
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
OUT = HERE / "coreml"


def save_and_compare(traced, example, name: str, mlmodel_inputs) -> None:
    import coremltools as ct
    import torch

    model = ct.convert(traced, inputs=mlmodel_inputs, outputs=[ct.TensorType(name="output")],
                       convert_to="mlprogram", compute_precision=ct.precision.FLOAT16,
                       minimum_deployment_target=ct.target.iOS17)
    OUT.mkdir(exist_ok=True)
    model.save(str(OUT / f"{name}.mlpackage"))
    with torch.no_grad():
        expected = traced(example).numpy()
    actual = model.predict({"input": example.numpy()})["output"]
    print(name, "saved; max abs difference vs PyTorch (fp16):", float(np.abs(actual - expected).max()),
          "mean:", float(np.abs(actual - expected).mean()), flush=True)


def convert_general() -> None:
    import coremltools as ct
    import torch
    from realesrgan.archs.srvgg_arch import SRVGGNetCompact

    net = SRVGGNetCompact(num_in_ch=3, num_out_ch=3, num_feat=64, num_conv=32, upscale=4, act_type="prelu")
    state = torch.load(HERE / "weights/realesr-general-x4v3/realesr-general-x4v3.pth", map_location="cpu")
    net.load_state_dict(state["params"])
    net.eval()
    example = torch.rand(1, 3, 256, 256)
    traced = torch.jit.trace(net, example)
    save_and_compare(traced, example, "general-x4v3-256", [ct.TensorType(name="input", shape=example.shape)])


def convert_codeformer(reshape_free_group_norm: bool = False) -> None:
    sys.path.insert(0, str(HERE / "repos" / "CodeFormer"))
    import coremltools as ct
    import torch
    from basicsr.utils.registry import ARCH_REGISTRY
    import basicsr.archs.codeformer_arch  # noqa: F401  (registers CodeFormer)

    net = ARCH_REGISTRY.get("CodeFormer")(dim_embd=512, codebook_size=1024, n_head=8, n_layers=9,
                                          connect_list=["32", "64", "128", "256"])
    net.load_state_dict(torch.load(HERE / "weights/codeformer/codeformer.pth", map_location="cpu",
                                   weights_only=False)["params_ema"])
    net.eval()
    name = "codeformer-w0.8-512"
    if reshape_free_group_norm:
        # Step 1d: same GroupNorm maths without reshaping full-size activations (4x faster on the A069 GPU).
        sys.path.insert(0, str(HERE))
        import codeformer_gpu
        torch.nn.GroupNorm.forward = codeformer_gpu.group_norm_without_big_reshape
        name = "codeformer-gn-w0.8-512"

    class FixedFidelity(torch.nn.Module):
        """CodeFormer with w=0.8 and AdaIN baked in, returning only the restored face."""

        def __init__(self, inner):
            super().__init__()
            self.inner = inner

        def forward(self, face):
            return self.inner(face, w=0.8, adain=True)[0]

    wrapped = FixedFidelity(net).eval()
    example = torch.rand(1, 3, 512, 512) * 2 - 1
    # torch.jit.trace turns CodeFormer's shape-keyed layer lookups into casts Core ML cannot convert; torch.export
    # keeps the shapes as plain numbers.
    with torch.no_grad():
        exported = torch.export.export(wrapped, (example,)).run_decompositions({})
    import coremltools as ct2
    model = ct2.convert(exported, outputs=[ct2.TensorType(name="output")], convert_to="mlprogram",
                        compute_precision=ct2.precision.FLOAT16, minimum_deployment_target=ct2.target.iOS17)
    OUT.mkdir(exist_ok=True)
    model.save(str(OUT / f"{name}.mlpackage"))
    input_name = model.get_spec().description.input[0].name
    with torch.no_grad():
        expected = wrapped(example).numpy()
    actual = model.predict({input_name: example.numpy()})["output"]
    print(name, "saved; input", input_name, "max abs difference vs PyTorch (fp16):",
          float(np.abs(actual - expected).max()), "mean:", float(np.abs(actual - expected).mean()), flush=True)


if __name__ == "__main__":
    if len(sys.argv) > 1:
        {"general": convert_general, "codeformer": convert_codeformer,
         "codeformer-gn": lambda: convert_codeformer(reshape_free_group_norm=True)}[sys.argv[1]]()
    else:
        for job in ("general", "codeformer"):
            subprocess.run([sys.executable, __file__, job], check=False)
