"""Enhance step 2c: RetinaFace MobileNet-0.25 (step 2b) for the phones, Core ML (fp32) and TFLite (fp32).

Fixed square canvases, multiples of 32 so the FPN's nearest upsampling stays exact: 1024 for the 640 pass and 1536 for
the 960 pass (photos up to 1.6:1; the photo is drawn at the top left, the rest filled with the network's mean colour,
which is zero after its mean subtraction, the same value the convolutions pad with).

Model input "image": [1, 3, S, S] RGB in [0, 1] (the BGR order, x255 and mean subtraction are inside). Outputs:
"loc" [1, N, 4], "score" [1, N] (softmax face probability), "landmarks" [1, N, 10]; priors and decoding are done on
the phone (phone_pipeline.py decode_detections). Weights: weights/retinaface-mobilenet (README).
Run: .venv/bin/python export_face_detector.py
"""
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
CANVASES = {"640": 1024, "960": 1536}


class DetectorForPhones:
    """Wraps facexlib's RetinaFace so the phones feed plain RGB in [0, 1]."""

    def __new__(cls):
        import torch

        class Wrapped(torch.nn.Module):
            def __init__(self, retinaface):
                super().__init__()
                self.retinaface = retinaface
                self.register_buffer("mean_bgr", torch.tensor([104.0, 117.0, 123.0]).view(1, 3, 1, 1))

            def forward(self, image):
                bgr = image.flip(1) * 255.0 - self.mean_bgr
                loc, confidence, landmarks = self.retinaface(bgr)
                return loc, confidence[..., 1], landmarks

        sys.path.insert(0, str(HERE / "repos" / "CodeFormer"))
        from facelib.detection.retinaface.retinaface import RetinaFace
        net = RetinaFace(network_name="mobile0.25", half=False, phase="test")
        state = torch.load(HERE / "weights/retinaface-mobilenet/detection_mobilenet0.25_Final.pth", map_location="cpu")
        net.load_state_dict({k[7:] if k.startswith("module.") else k: v for k, v in state.items()}, strict=True)
        # facexlib moves the network to its module-level device (MPS on the Mac); conversion traces on the CPU.
        return Wrapped(net.cpu().eval()).eval()


def main() -> None:
    import coremltools as ct
    import litert_torch
    import torch

    module = DetectorForPhones()
    (HERE / "coreml").mkdir(exist_ok=True)
    (HERE / "tflite").mkdir(exist_ok=True)
    rng = np.random.default_rng(0)
    for name, side in CANVASES.items():
        example = torch.from_numpy(rng.random((1, 3, side, side), dtype=np.float32))
        with torch.no_grad():
            expected = [t.numpy() for t in module(example)]

        traced = torch.jit.trace(module, example)
        mlmodel = ct.convert(traced, inputs=[ct.TensorType(name="image", shape=example.shape)],
                             outputs=[ct.TensorType(name=n) for n in ("loc", "score", "landmarks")],
                             convert_to="mlprogram", compute_precision=ct.precision.FLOAT32,
                             minimum_deployment_target=ct.target.iOS16)
        path = HERE / "coreml" / f"face-detector-{name}.mlpackage"
        mlmodel.save(str(path))
        predicted = mlmodel.predict({"image": example.numpy()})
        print(name, "Core ML max difference:",
              [float(np.abs(predicted[n] - e).max()) for n, e in zip(("loc", "score", "landmarks"), expected)])

        edge = litert_torch.convert(module, (example,))
        tflite_path = HERE / "tflite" / f"face-detector-{name}.tflite"
        edge.export(str(tflite_path))
        actual = [np.asarray(t) for t in edge(example)]
        print(name, "TFLite", round(tflite_path.stat().st_size / 1e6, 2), "MB, max difference:",
              [float(np.abs(a - e).max()) for a, e in zip(actual, expected)], flush=True)


if __name__ == "__main__":
    main()
