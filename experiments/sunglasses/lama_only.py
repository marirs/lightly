import sys, json, math, subprocess, numpy as np
from PIL import Image, ImageFilter
from ai_edge_litert.interpreter import Interpreter
S=sys.argv[1]
it=Interpreter('/Users/sg/Documents/Dev/Projects/lightly/experiments/inpaint/models/exported/lama_512_fp32.tflite',num_threads=8); it.allocate_tensors()
ins=it.get_input_details(); out=it.get_output_details()[0]
def lama(im, M):
    W,H=im.size; m=np.asarray(M)>127; ys,xs=np.nonzero(m)
    cx,cy=(xs.min()+xs.max())/2,(ys.min()+ys.max())/2; side=int(max(xs.max()-xs.min(),ys.max()-ys.min())*1.5); side=min(max(side,256),W,H)
    x0=int(max(0,min(W-side,cx-side/2))); y0=int(max(0,min(H-side,cy-side/2)))
    crop=im.crop((x0,y0,x0+side,y0+side)).resize((512,512),Image.LANCZOS); mc=M.crop((x0,y0,x0+side,y0+side)).resize((512,512),Image.NEAREST)
    it.set_tensor(ins[0]['index'],(np.asarray(crop,np.float32)/255).transpose(2,0,1)[None]); it.set_tensor(ins[1]['index'],(np.asarray(mc)>127).astype(np.float32)[None,None]); it.invoke()
    o=it.get_tensor(out['index'])[0].transpose(1,2,0); o=np.clip(o/255.0 if o.max()>2 else o,0,1)
    res=Image.fromarray((o*255).astype(np.uint8)).resize((side,side),Image.LANCZOS)
    full=im.copy(); full.paste(res,(x0,y0),M.filter(ImageFilter.GaussianBlur(3)).crop((x0,y0,x0+side,y0+side))); return full
def nrm(v): return v/np.linalg.norm(v)
names=['glasses_thick_deep_01','glasses_black_front_01','glasses_thin_metal_01','glasses_side_angle_01','sunglasses_round_01','glasses_pair_mixed_01']
