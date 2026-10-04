"""U^2-Netp (github.com/xuebinqin/U-2-Net @ ac7e1c8, Apache-2.0) -> LiteRT fp32. Offline; NOT run by the agent.

The permission system refused to let the agent run this (upstream model code plus pickled weights), so the
owner runs it, or allows it, after reviewing docs/v1/android-vision-evaluation.md section 5.

    python3.11 -m venv .venv_convert && .venv_convert/bin/pip install torch litert-torch numpy
    curl -sL -o work/u2net/u2net.py https://raw.githubusercontent.com/xuebinqin/U-2-Net/ac7e1c817ecab7c7dff5ce6b1abba61cd213ff29/model/u2net.py
    # weights: README link (Google Drive id 1rbSTGKAE-MTxBYHd-51l2hMOQPT_7EPy) -> models/u2netp.pth
    cd work/u2net && ../../.venv_convert/bin/python ../../scripts/convert_u2netp.py ../../models/u2netp.pth ../../models/converted

Input NCHW 1x3x320x320: RGB resized to 320x320, divided by its max, ImageNet mean/std (u2net_test.py RescaleT(320)
+ ToTensorLab(flag=0)). Output 1x1x320x320: the sigmoid saliency d0.
"""
import hashlib, pathlib, sys
import numpy as np, torch

CODE_SHA256 = "96dd7a19c7de4f13520ccfc1075ded3350ff4946493be3561b9918a46218f415"
WEIGHTS_SHA256 = "e7567cde013fb64813973ce6e1ecc25a80c05c3ca7adbc5a54f3c3d90991b854"


def sha256(path) -> str:
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()


def main(weights: str, out_dir: str) -> None:
    assert sha256("u2net.py") == CODE_SHA256, "model/u2net.py is not the reviewed ac7e1c8 file"
    assert sha256(weights) == WEIGHTS_SHA256, "u2netp.pth does not match the README weights"
    from u2net import U2NETP  # plain nn.Module definitions (reviewed: imports only torch)
    import litert_torch

    net = U2NETP(3, 1)
    net.load_state_dict(torch.load(weights, map_location="cpu", weights_only=True))
    net.eval()

    class SaliencyOnly(torch.nn.Module):
        """The fused output d0 only; the six side outputs are training aids."""
        def __init__(self, model): super().__init__(); self.model = model
        def forward(self, x): return self.model(x)[0]

    model = SaliencyOnly(net).eval()
    sample = (torch.randn(1, 3, 320, 320),)
    edge = litert_torch.convert(model, sample)
    out = pathlib.Path(out_dir); out.mkdir(parents=True, exist_ok=True)
    target = out / "u2netp_320_fp32.tflite"
    edge.export(str(target))
    with torch.no_grad():
        reference = model(*sample).numpy()
    converted = edge(*[s.numpy() for s in sample])
    print("max abs difference vs torch:", float(np.abs(reference - converted).max()))
    print("sha256", sha256(target))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
