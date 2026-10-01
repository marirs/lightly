"""Verify the Python port against the upstream C kernel (compiled verbatim) and the demo image.

Usage: python verify_port.py <path to libtri.dylib built from upstream trilinear.cpp TriLinearForwardCpu>
"""
import ctypes, os, sys
import numpy as np
from PIL import Image
import ia3dlut as ia

here = os.path.dirname(os.path.abspath(__file__))
lib = ctypes.CDLL(sys.argv[1])
fp = ctypes.POINTER(ctypes.c_float)
lib.TriLinearForwardCpu.argtypes = [fp, fp, fp, ctypes.c_int, ctypes.c_int, ctypes.c_float, ctypes.c_int, ctypes.c_int, ctypes.c_int]

model = ia.load_reference_model(os.path.join(here, "upstream/pretrained_models/sRGB"))
img = np.asarray(Image.open(os.path.join(here, "upstream/demo_images/sRGB/a1629.jpg")).convert("RGB"))
w = ia.predict_weights_reference(model, img)
lut = ia.fuse_luts(model.basis_luts, w)
rgb01 = img.astype(np.float32) / 255.0

# C kernel expects planar CHW. Note upstream passes W=x.size(2) (=H) and H=x.size(3) (=W); only W*H matters.
chw = np.ascontiguousarray(rgb01.transpose(2, 0, 1))
out = np.zeros_like(chw)
dim = 33
lib.TriLinearForwardCpu(np.ascontiguousarray(lut).ctypes.data_as(fp), chw.ctypes.data_as(fp), out.ctypes.data_as(fp),
                        dim, dim**3, ctypes.c_float(1.0001 / (dim - 1)), img.shape[0], img.shape[1], 3)
c_result = out.transpose(1, 2, 0)
py_result = ia.apply_lut_reference(lut, rgb01)
print("image", img.shape, "weights", w)
print("port vs C kernel: max abs diff", float(np.abs(c_result - py_result).max()),
      "uint8 mismatches", int((ia.to_uint8(c_result) != ia.to_uint8(py_result)).sum()))
ident = ia.apply_lut_reference(ia.identity_lut(), rgb01, binsize_numerator=1.0)
print("exact identity LUT (numerator 1.0) max err", float(np.abs(ident - rgb01).max()))
q = ia.apply_lut_reference(ia.identity_lut(), rgb01)
print("identity LUT with upstream 1.0001 quirk: max err", float(np.abs(q - rgb01).max()), "in 8-bit:", float(np.abs(q - rgb01).max() * 255))
print("LUT0 distance from identity (mean abs)", float(np.abs(model.basis_luts[0] - ia.identity_lut()).mean()))
