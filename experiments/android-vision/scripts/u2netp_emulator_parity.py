"""App (emulator, LiteRT, Kotlin preprocessing) vs reference pipeline (skimage + LiteRT Python) on the SAME display
pixels the app used (VisionProbe __display.png), and vs the reference on the original photo."""
import os, json, numpy as np
from PIL import Image
from skimage import transform
from ai_edge_litert.interpreter import Interpreter
HERE = os.path.dirname(os.path.abspath(__file__)); W = os.path.join(HERE, '..', 'work')
it = Interpreter(model_path=os.path.join(HERE, '..', 'models', 'u2netp_320_fp32.tflite')); it.allocate_tensors()
i, o = it.get_input_details()[0], it.get_output_details()[0]
M = np.array([0.485, 0.456, 0.406]); SD = np.array([0.229, 0.224, 0.225])
def ref(im):
    x = transform.resize(im, (320, 320), mode='constant'); x = ((x / x.max() - M) / SD).transpose(2, 0, 1)[None].astype(np.float32)
    it.set_tensor(i['index'], x); it.invoke(); return it.get_tensor(o['index']).reshape(320, 320)
for n in ('subject_boat', 'subject_swan', 'landscape_02', 'night_03'):
    app = np.fromfile(os.path.join(W, 'u2netp-emulator', n + '__saliency.f32'), '<f4').reshape(320, 320)
    disp = np.asarray(Image.open(os.path.join(W, 'u2netp-emulator', n + '__display.png')).convert('RGB'))
    same = ref(disp); orig = ref(np.asarray(Image.open(os.path.join(W, 'u2netp-eval', 'photos', n + '.jpg')).convert('RGB')))
    a = lambda d: (d >= 0.9).mean() * 100
    print(f"{n:14} display {disp.shape[1]}x{disp.shape[0]} | app vs reference, same pixels: max {np.abs(app - same).max():.2e} mean {np.abs(app - same).mean():.1e}"
          f" | confident area app {a(app):.2f}% ref-same {a(same):.2f}% ref-original {a(orig):.2f}% | app vs ref-original max {np.abs(app - orig).max():.3f}")
