"""MODNet photographic portrait matting -> LiteRT fp16 at a fixed 1x512x512x3 input (Android person matte).

Source: Xenova/modnet onnx/model.onnx (huggingface.co/Xenova/modnet, Apache-2.0; an ONNX export of
github.com/ZHKKKe/MODNet's photographic portrait matting model, Apache-2.0), sha256
07c308cf0fc7e6e8b2065a12ed7fc07e1de8febb7dc7839d7b7f15dd66584df9. Training data: not documented by the
repository; licence review with counsel before release (as LaMa's Places2 and U^2-Netp's DUTS-TR).

    python3.11 -m venv .venv_modnet && .venv_modnet/bin/pip install onnx onnxsim onnx2tf 'tensorflow>=2.17' \
        tf_keras onnx_graphsurgeon sng4onnx psutil ai_edge_litert onnxruntime opencv-python pillow
    curl -sL -o work/modnet/model.onnx https://huggingface.co/Xenova/modnet/resolve/main/onnx/model.onnx
    .venv_modnet/bin/python scripts/convert_modnet.py work/modnet/model.onnx models/modnet_photographic_512_fp16.tflite

Steps: fix the dynamic input to 1x3x512x512 -> onnxsim -> onnx2tf (fp16 weights). onnx2tf downloads a pickled
sample-image file to check shapes; it is replaced here by two of our portraits letterboxed to 512, so nothing is
unpickled. The fp16 model is checked against the ONNX model (max |difference| measured 0.014, mean 3e-5).

Input NHWC 1x512x512x3: the photo letterboxed into 512x512 (long edge 512, centred, black padding), RGB in
[0, 1] then (x - 0.5) / 0.5. Output 1x512x512x1: alpha in [0, 1].
"""
import hashlib, pathlib, shutil, subprocess, sys, tempfile
import numpy as np, cv2, onnx
from PIL import Image

REPO = pathlib.Path(__file__).resolve().parents[3]
SOURCE_SHA256 = "07c308cf0fc7e6e8b2065a12ed7fc07e1de8febb7dc7839d7b7f15dd66584df9"


def letterboxed(name: str) -> np.ndarray:
    rgb = np.asarray(Image.open(REPO / f"docs/ui/assets/photos/{name}.jpg").convert("RGB")).astype(np.float32) / 255
    h, w, _ = rgb.shape; s = 512 / max(h, w); nh, nw = round(h * s), round(w * s)
    canvas = np.zeros((512, 512, 3), np.float32); y0, x0 = (512 - nh) // 2, (512 - nw) // 2
    canvas[y0:y0 + nh, x0:x0 + nw] = cv2.resize(rgb, (nw, nh), interpolation=cv2.INTER_AREA)
    return canvas


def main(source: str, out: str) -> None:
    assert hashlib.sha256(pathlib.Path(source).read_bytes()).hexdigest() == SOURCE_SHA256, "unexpected source model"
    work = pathlib.Path(tempfile.mkdtemp())
    model = onnx.load(source)
    for dim, value in zip(model.graph.input[0].type.tensor_type.shape.dim, (1, 3, 512, 512)):
        dim.ClearField("dim_param"); dim.dim_value = value
    onnx.save(model, work / "fixed.onnx")
    subprocess.run([sys.executable, "-m", "onnxsim", str(work / "fixed.onnx"), str(work / "sim.onnx")], check=True)

    import onnx2tf.utils.common_functions as common
    import onnx2tf.onnx2tf as converter
    samples = lambda: np.stack([letterboxed(n) for n in ("portrait_medium_02", "portrait_deep_03")])
    common.download_test_image_data = samples
    converter.download_test_image_data = samples
    converter.convert(input_onnx_file_path=str(work / "sim.onnx"), output_folder_path=str(work / "tf"), non_verbose=True)
    shutil.copy(work / "tf" / "sim_float16.tflite", out)

    import onnxruntime as ort
    from ai_edge_litert.interpreter import Interpreter
    reference = ort.InferenceSession(str(work / "fixed.onnx"))
    lite = Interpreter(model_path=out); lite.allocate_tensors()
    i, o = lite.get_input_details()[0], lite.get_output_details()[0]
    for name in ("portrait_medium_02", "portrait_deep_03"):
        x = (letterboxed(name) - 0.5) / 0.5
        expected = reference.run(None, {"input": x.transpose(2, 0, 1)[None]})[0][0, 0]
        lite.set_tensor(i["index"], x[None]); lite.invoke()
        got = lite.get_tensor(o["index"]).reshape(512, 512)
        print(f"{name}: max |d| {np.abs(got - expected).max():.4f}, mean |d| {np.abs(got - expected).mean():.6f}")
    print(out, hashlib.sha256(pathlib.Path(out).read_bytes()).hexdigest())


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
