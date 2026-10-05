"""Converted U²-Netp (LiteRT fp32) on every desk fixture with a Vision verdict; two preprocessings:
'ref' = u2net_test.py (skimage anti-aliased resize), 'android' = SubjectSaliency.input (plain bilinear stretch).
Features of the raw 320x320 sigmoid: area >= 0.5, area >= 0.9, crisp = area>=0.9 / area>=0.5, peak."""
import numpy as np, cv2, json
from PIL import Image
from skimage import transform
from ai_edge_litert.interpreter import Interpreter
import os
# Inputs: photos/, vision_ref/ and u2net/{u2net.py,u2netp.pth} (see convert_u2netp.py for the sources).
U=os.environ.get('U2NETP_WORK', os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'work', 'u2netp-eval'))
it=Interpreter(model_path='/Users/sg/Documents/Dev/Projects/lightly/experiments/android-vision/models/u2netp_320_fp32.tflite'); it.allocate_tensors()
i,o=it.get_input_details()[0],it.get_output_details()[0]
M=np.array([0.485,0.456,0.406]); SD=np.array([0.229,0.224,0.225])
def run(x):
    x=((x/x.max()-M)/SD).transpose(2,0,1)[None].astype(np.float32); it.set_tensor(i['index'],x); it.invoke(); return it.get_tensor(o['index']).reshape(320,320)
truth={'subject_boat':1,'subject_swan':1,'portrait_medium_02':1,'portrait_deep_02':1,'portrait_deep_03':1,'portrait_light_01':1,'group_three_01':1,'backlit_02':1,
       'landscape_02':0,'landscape_03':0,'sunset_02':0,'night_03':0}
import os
rows={}
for n,t in truth.items():
    p=f'{U}/photos/{n}.jpg'
    if not os.path.exists(p): p=f'/Users/sg/Documents/Dev/Projects/lightly/docs/ui/assets/photos/{n}.jpg'
    if not os.path.exists(p): print(n,'missing'); continue
    im=np.asarray(Image.open(p).convert('RGB'))
    r={'vision_subject':t}
    for k,x in (('ref',transform.resize(im,(320,320),mode='constant')),('android',cv2.resize(im.astype(np.float32)/255,(320,320),interpolation=cv2.INTER_LINEAR))):
        d=run(x); a5=(d>=.5).mean(); a9=(d>=.9).mean()
        r[k]=dict(area50=round(float(a5),4),area90=round(float(a9),4),crisp=round(float(a9/max(a5,1e-6)),3),peak=round(float(d.max()),3)); r[k+'_d']=d
    r['ref_vs_android_maxdiff']=round(float(np.abs(r['ref_d']-r['android_d']).max()),3); del r['ref_d'],r['android_d']
    rows[n]=r; print(n.ljust(20),t,'ref',r['ref'],'android',r['android'],'maxdiff',r['ref_vs_android_maxdiff'])
json.dump(rows,open(f'{U}/u2eval/calibration.json','w'),indent=1)
