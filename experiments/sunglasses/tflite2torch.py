# Rebuild a TFLite model as a PyTorch module (op for op, weights copied), so it can be converted to Core ML.
#
# Why not tf2onnx: it needs a full TensorFlow install. The TFLite flatbuffer schema ships with ai-edge-litert, which
# is enough to read the graph, the op options and the weights.
#
# Tensors stay in TFLite's NHWC layout throughout, so RESHAPE / TRANSPOSE / SUM keep their exact meaning; convolutions
# permute to NCHW and back (coremltools folds those transposes). Only the ops used by the MediaPipe face landmarker
# and selfie-multiclass models are implemented; anything else raises.
import sys, numpy as np, torch, torch.nn.functional as F
from ai_edge_litert import schema_py_generated as tfl

OPS = {v: k for k, v in vars(tfl.BuiltinOperator).items() if not k.startswith('_')}
ACT = {v: k for k, v in vars(tfl.ActivationFunctionType).items() if not k.startswith('_')}


def _same_pads(size, kernel, stride, dilation=1):
    """TensorFlow SAME padding (extra pixel at the end), as (before, after)."""
    eff = (kernel - 1) * dilation + 1
    out = -(-size // stride)
    total = max((out - 1) * stride + eff - size, 0)
    return total // 2, total - total // 2


def _act(x, kind):
    name = ACT[kind]
    if name == 'NONE': return x
    if name == 'RELU': return F.relu(x)
    if name == 'RELU6': return torch.clamp(x, 0, 6)
    raise NotImplementedError(f'activation {name}')


class TFLiteModule(torch.nn.Module):
    def __init__(self, path):
        super().__init__()
        buf = open(path, 'rb').read()
        self.m = tfl.ModelT.InitFromPackedBuf(buf, 0)
        self.g = self.m.subgraphs[0]
        self.consts = {}
        for i, t in enumerate(self.g.tensors):
            data = self.m.buffers[t.buffer].data
            if data is not None and len(data):
                dt = {tfl.TensorType.FLOAT32: np.float32, tfl.TensorType.FLOAT16: np.float16,
                      tfl.TensorType.INT32: np.int32, tfl.TensorType.INT64: np.int64}[t.type]
                arr = np.frombuffer(bytes(data), dt).reshape(t.shape if t.shape is not None and len(t.shape) else -1)
                self.consts[i] = arr
        # Weights as buffers (fp32), keyed by tensor index; DEQUANTIZE outputs are precomputed here.
        for op in self.g.operators:
            if OPS[self.m.operatorCodes[op.opcodeIndex].builtinCode] == 'DEQUANTIZE' and op.inputs[0] in self.consts:
                self.consts[op.outputs[0]] = self.consts[op.inputs[0]].astype(np.float32)
        for i, arr in self.consts.items():
            if arr.dtype != np.float16:
                self.register_buffer(f'c{i}', torch.from_numpy(arr.astype(np.float32) if arr.dtype.kind == 'f' else arr.astype(np.int64)))

    def const(self, i):
        return getattr(self, f'c{i}')

    def forward(self, x):
        env = {self.g.inputs[0]: x}
        get = lambda i: env[i] if i in env else self.const(i)
        for op in self.g.operators:
            name = OPS[self.m.operatorCodes[op.opcodeIndex].builtinCode]
            o = op.builtinOptions; ins = op.inputs; out = op.outputs[0]
            if name == 'DEQUANTIZE':
                if out in self.consts: continue
                env[out] = get(ins[0]).float(); continue
            # Static NHWC shapes from the graph: tracing must not read runtime sizes (coremltools rejects them).
            shp = [int(v) for v in self.g.tensors[ins[0]].shape] if len(ins) and ins[0] >= 0 and self.g.tensors[ins[0]].shape is not None else None
            if name in ('CONV_2D', 'DEPTHWISE_CONV_2D'):
                inp = get(ins[0]).permute(0, 3, 1, 2); w = self.const(ins[1])
                b = self.const(ins[2]) if len(ins) > 2 and ins[2] >= 0 else None
                if name == 'CONV_2D':
                    weight = w.permute(0, 3, 1, 2); groups = 1           # OHWI -> OIHW
                else:
                    weight = w.permute(3, 0, 1, 2); groups = shp[3]  # 1HW(C*M) -> (C*M)1HW
                kh, kw = int(self.consts[ins[1]].shape[1]), int(self.consts[ins[1]].shape[2])
                dh, dw = getattr(o, 'dilationHFactor', 1) or 1, getattr(o, 'dilationWFactor', 1) or 1
                if o.padding == tfl.Padding.SAME:
                    ph = _same_pads(shp[1], kh, o.strideH, dh); pw = _same_pads(shp[2], kw, o.strideW, dw)
                    inp = F.pad(inp, (pw[0], pw[1], ph[0], ph[1]))
                y = F.conv2d(inp, weight, b, (o.strideH, o.strideW), 0, (dh, dw), groups)
                env[out] = _act(y, o.fusedActivationFunction).permute(0, 2, 3, 1); continue
            if name == 'TRANSPOSE_CONV':
                # inputs: output_shape, weights (OHWI), input, [bias]
                shape = self.consts[ins[0]].tolist(); w = self.const(ins[1]); inp = get(ins[2]).permute(0, 3, 1, 2)
                weight = w.permute(3, 0, 1, 2)  # OHWI -> I O H W for conv_transpose (in=I(last), out=O)
                y = F.conv_transpose2d(inp, weight, None, (o.strideH, o.strideW))
                oh, ow = shape[1], shape[2]
                if o.padding == tfl.Padding.SAME:
                    kh, kw = int(self.consts[ins[1]].shape[1]), int(self.consts[ins[1]].shape[2])
                    xh, xw = [int(v) for v in self.g.tensors[ins[2]].shape][1:3]
                    th, tw = (xh - 1) * o.strideH + kh - oh, (xw - 1) * o.strideW + kw - ow
                    y = y[:, :, th // 2: th // 2 + oh, tw // 2: tw // 2 + ow]
                else:
                    y = y[:, :, :oh, :ow]
                if len(ins) > 3 and ins[3] >= 0: y = y + self.const(ins[3]).view(1, -1, 1, 1)
                env[out] = y.permute(0, 2, 3, 1); continue
            if name == 'PRELU':
                a = get(ins[1]); env[out] = torch.where(get(ins[0]) >= 0, get(ins[0]), get(ins[0]) * a); continue
            if name in ('ADD', 'MUL'):
                y = get(ins[0]) + get(ins[1]) if name == 'ADD' else get(ins[0]) * get(ins[1])
                env[out] = _act(y, o.fusedActivationFunction if o is not None else 0); continue
            if name == 'MAX_POOL_2D':
                inp = get(ins[0]).permute(0, 3, 1, 2)
                if o.padding == tfl.Padding.SAME:
                    ph = _same_pads(shp[1], o.filterHeight, o.strideH); pw = _same_pads(shp[2], o.filterWidth, o.strideW)
                    inp = F.pad(inp, (pw[0], pw[1], ph[0], ph[1]), value=float('-inf'))
                y = F.max_pool2d(inp, (o.filterHeight, o.filterWidth), (o.strideH, o.strideW))
                env[out] = _act(y, o.fusedActivationFunction).permute(0, 2, 3, 1); continue
            if name == 'PAD':
                p = self.consts[ins[1]]  # [[b0,a0],[b1,a1],...] over NHWC
                flat = []
                for d in reversed(range(p.shape[0])): flat += [int(p[d, 0]), int(p[d, 1])]
                env[out] = F.pad(get(ins[0]), flat); continue
            if name == 'LOGISTIC':
                env[out] = torch.sigmoid(get(ins[0])); continue
            if name == 'SOFTMAX':
                env[out] = torch.softmax(get(ins[0]) * (o.beta if o else 1.0), dim=-1); continue
            if name == 'RESHAPE':
                shape = [int(v) for v in self.g.tensors[out].shape]
                env[out] = get(ins[0]).reshape(shape); continue
            if name == 'TRANSPOSE':
                env[out] = get(ins[0]).permute(*[int(v) for v in self.consts[ins[1]]]); continue
            if name == 'SUM':
                axes = [int(v) for v in np.atleast_1d(self.consts[ins[1]])]
                env[out] = get(ins[0]).sum(dim=axes, keepdim=bool(o.keepDims)); continue
            if name in ('RESIZE_BILINEAR', 'RESIZE_NEAREST_NEIGHBOR'):
                size = [int(v) for v in self.consts[ins[1]]]; inp = get(ins[0]).permute(0, 3, 1, 2)
                if name == 'RESIZE_BILINEAR':
                    if o.alignCorners: y = F.interpolate(inp, size=size, mode='bilinear', align_corners=True)
                    else: y = F.interpolate(inp, size=size, mode='bilinear', align_corners=False)  # half_pixel_centers
                else:
                    y = F.interpolate(inp, size=size, mode='nearest')
                env[out] = y.permute(0, 2, 3, 1); continue
            raise NotImplementedError(name)
        outs = [env[i] for i in self.g.outputs]
        return tuple(outs) if len(outs) > 1 else outs[0]
