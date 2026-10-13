# Convert the two MediaPipe models Sunglasses needs on iOS to Core ML (mlprogram, iOS 17, fp16), via tflite2torch.
#   face_landmarks_detector.tflite  -> face_landmarks_256_fp16.mlpackage   in [1,256,256,3] 0..1 -> landmarks [1,1434],
#                                                                           face-presence logit [1,1]
#   selfie_multiclass_256x256.tflite -> selfie_multiclass_256_fp16.mlpackage in [1,256,256,3] 0..1 -> logits [1,256,256,6]
# Then checks Core ML against LiteRT on real face crops (landmark error in crop pixels, class agreement).
#
# Usage: python convert_coreml.py <work dir with lm.json / pose.json> <out dir> <landmarker.tflite> <multiclass.tflite>
#        <photo dir>:<name> ...
import sys, json, math, numpy as np, torch, coremltools as ct
from PIL import Image
from ai_edge_litert.interpreter import Interpreter, OpResolverType
sys.path.insert(0, __file__.rsplit('/', 1)[0])
from tflite2torch import TFLiteModule

S, OUT, LM, MC = sys.argv[1:5]
photos = [a.split(':') for a in sys.argv[5:]]


class Landmarks(torch.nn.Module):
    def __init__(self, path):
        super().__init__(); self.m = TFLiteModule(path)
    def forward(self, x):
        pts, flag, _ = self.m(x)
        return pts.reshape(1, 1434), flag.reshape(1, 1)


def convert(module, name, outputs):
    x = torch.rand(1, 256, 256, 3)
    traced = torch.jit.trace(module.eval(), x)
    model = ct.convert(traced, inputs=[ct.TensorType(name='image', shape=(1, 256, 256, 3))],
                       outputs=[ct.TensorType(name=o) for o in outputs], convert_to='mlprogram',
                       minimum_deployment_target=ct.target.iOS17, compute_precision=ct.precision.FLOAT16)
    model.short_description = name
    model.save(f'{OUT}/{name}.mlpackage'); return model


lm_ml = convert(Landmarks(LM), 'face_landmarks_256_fp16', ['landmarks', 'face_flag'])
mc_ml = convert(TFLiteModule(MC), 'selfie_multiclass_256_fp16', ['logits'])

def lite(path):
    it = Interpreter(path, experimental_op_resolver_type=OpResolverType.BUILTIN_WITHOUT_DEFAULT_DELEGATES); it.allocate_tensors(); return it

lm_tf, mc_tf = lite(LM), lite(MC)
worst_px, agree = 0.0, []
for d, n in photos:
    im = Image.open(f'{d}/{n}.jpg').convert('RGB')
    for f in json.load(open(f'{S}/{n}.lm.json')):
        P = np.array(f['pts']); lo, hi = P[:468, :2].min(0), P[:468, :2].max(0); c = (lo + hi) / 2; side = max(hi - lo) * 1.5
        crop = im.crop((int(c[0] - side / 2), int(c[1] - side / 2), int(c[0] + side / 2), int(c[1] + side / 2))).resize((256, 256))
        x = np.asarray(crop, np.float32)[None] / 255
        lm_tf.set_tensor(lm_tf.get_input_details()[0]['index'], x); lm_tf.invoke()
        ref = lm_tf.get_tensor(lm_tf.get_output_details()[0]['index']).reshape(-1, 3)
        got = lm_ml.predict({'image': x})['landmarks'].reshape(-1, 3)
        err = float(np.abs(got[:, :2] - ref[:, :2]).max()); worst_px = max(worst_px, err)
        mc_tf.set_tensor(mc_tf.get_input_details()[0]['index'], x); mc_tf.invoke()
        r = mc_tf.get_tensor(mc_tf.get_output_details()[0]['index'])[0].argmax(-1)
        g = mc_ml.predict({'image': x})['logits'][0].argmax(-1)
        agree.append(float((r == g).mean()))
        print(f'{n:28s} landmarks max err {err:.3f} px of 256   multiclass agreement {agree[-1]*100:.2f} %')
print(f'WORST landmark error {worst_px:.3f} px; mean class agreement {np.mean(agree)*100:.2f} %, min {min(agree)*100:.2f} %')
