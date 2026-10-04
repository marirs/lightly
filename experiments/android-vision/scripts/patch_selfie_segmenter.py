"""MediaPipe selfie_segmenter.tflite -> the same model with its one MediaPipe custom op
(Convolution2DTransposeBias, the final 2x upsample) replaced by the builtin TRANSPOSE_CONV with bias,
so it runs on LiteRT's built-in kernels (the arm64 emulator cannot use XNNPACK, which is what implements
the custom op). Weights and every other op are untouched; the output is checked against the original.

    python3.11 -m venv .venv_litert && .venv_litert/bin/pip install ai-edge-litert numpy
    .venv_litert/bin/python scripts/patch_selfie_segmenter.py models/selfie_segmenter.tflite models/selfie_segmenter_builtin.tflite

Output SHA-256 400dd25939e56f7374f2aa2345ddf31ded21f525627cbeb707a4f022ba90ef2d (max abs difference 1.6e-12)."""
import hashlib, struct, sys, numpy as np
from ai_edge_litert.tools import flatbuffer_utils as fu
from ai_edge_litert import schema_py_generated as s
from ai_edge_litert.interpreter import Interpreter, OpResolverType
SRC, DST = sys.argv[1], sys.argv[2]
m = fu.read_model(SRC); g = m.subgraphs[0]
custom = [i for i, c in enumerate(m.operatorCodes) if c.customCode == b'Convolution2DTransposeBias']
assert len(custom) == 1
code = s.OperatorCodeT(); code.builtinCode = s.BuiltinOperator.TRANSPOSE_CONV; code.deprecatedBuiltinCode = s.BuiltinOperator.TRANSPOSE_CONV; code.version = 3
m.operatorCodes.append(code); new_index = len(m.operatorCodes) - 1
for op in g.operators:
    if op.opcodeIndex != custom[0]: continue
    padding, stride_w, stride_h = struct.unpack('<iii', bytes(op.customOptions))
    x, w, b = op.inputs; out = op.outputs[0]
    # output_shape: a new constant int32 [4] tensor = the custom op's static output shape.
    buf = s.BufferT(); buf.data = np.array(g.tensors[out].shape, np.int32).tobytes(); m.buffers.append(buf)
    t = s.TensorT(); t.shape = [4]; t.type = s.TensorType.INT32; t.buffer = len(m.buffers) - 1; t.name = b'segment/output_shape'
    g.tensors.append(t)
    op.opcodeIndex = new_index
    op.inputs = [len(g.tensors) - 1, w, x, b]
    opts = s.TransposeConvOptionsT(); opts.padding = s.Padding.SAME if padding == 1 else s.Padding.VALID
    opts.strideW, opts.strideH = stride_w, stride_h; opts.fusedActivationFunction = s.ActivationFunctionType.NONE
    op.builtinOptionsType = s.BuiltinOptions.TransposeConvOptions; op.builtinOptions = opts
    op.customOptions = None; op.customOptionsFormat = 0
fu.write_model(m, DST)
rng = np.random.default_rng(0); x = rng.random((1, 256, 256, 3), np.float32)
def run(path, resolver):
    it = Interpreter(model_path=path, experimental_op_resolver_type=resolver); it.allocate_tensors()
    it.set_tensor(it.get_input_details()[0]['index'], x); it.invoke()
    return it.get_tensor(it.get_output_details()[0]['index'])
ref = run(SRC, OpResolverType.AUTO)  # XNNPACK implements the custom op
got = run(DST, OpResolverType.BUILTIN_WITHOUT_DEFAULT_DELEGATES)
print('max abs diff', float(np.abs(ref - got).max()), 'sha256', hashlib.sha256(open(DST, 'rb').read()).hexdigest())
