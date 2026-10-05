import sys, numpy as np, torch
from PIL import Image
from skimage import transform
from ai_edge_litert.interpreter import Interpreter
import os
# Inputs: photos/, vision_ref/ and u2net/{u2net.py,u2netp.pth} (see convert_u2netp.py for the sources).
U=os.environ.get('U2NETP_WORK', os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'work', 'u2netp-eval'))
sys.path.insert(0,f'{U}/u2net'); from u2net import U2NETP
net=U2NETP(3,1); net.load_state_dict(torch.load(f'{U}/u2net/u2netp.pth',map_location='cpu',weights_only=True)); net.eval()
it=Interpreter(model_path='/Users/sg/Documents/Dev/Projects/lightly/experiments/android-vision/models/u2netp_320_fp32.tflite'); it.allocate_tensors()
i,o=it.get_input_details()[0],it.get_output_details()[0]; print('tflite in',i['shape'],'out',o['shape'])
for n in ('subject_boat','subject_swan','landscape_02'):
    im=np.asarray(Image.open(f'{U}/photos/{n}.jpg').convert('RGB')); x=transform.resize(im,(320,320),mode='constant'); x=x/x.max()
    x=((x-[0.485,0.456,0.406])/[0.229,0.224,0.225]).transpose(2,0,1)[None].astype(np.float32)
    with torch.no_grad(): ref=net(torch.from_numpy(x))[0].numpy()
    it.set_tensor(i['index'],x); it.invoke(); got=it.get_tensor(o['index'])
    print(n,'max |tflite-torch| %.2e'%np.abs(got.reshape(ref.shape)-ref).max())
