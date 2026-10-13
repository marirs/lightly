# MediaPipe selfie_multiclass per face, saved at photo size:
#   <name>.hair.npy  hair probability (class 1), from a wide crop (3.6x the face box) so long hair is included
#   <name>.bg.npy    background probability (class 0), same wide crop: the person's outline
#   <name>.acc.npy   accessory probability (class 5), from a tight crop (1.4x the face box): thin glasses rims
#                    vanish at the wide crop's resolution
import sys, json, numpy as np
from PIL import Image
from ai_edge_litert.interpreter import Interpreter
S, D = sys.argv[1], sys.argv[2]
it=Interpreter('/Users/sg/Documents/Dev/Projects/lightly/experiments/android-vision/models/selfie_multiclass_256x256.tflite'); it.allocate_tensors()
inp=it.get_input_details()[0]; out=it.get_output_details()[0]

def classes_in_crop(im, cx, cy, side):
    """Class probabilities (256x256x6) for a square crop, and the crop box in photo pixels."""
    x0,y0=int(cx-side/2),int(cy-side/2); x1,y1=int(cx+side/2),int(cy+side/2)
    crop=im.crop((x0,y0,x1,y1)).resize((256,256),Image.BILINEAR)
    it.set_tensor(inp['index'],(np.asarray(crop,np.float32)/255)[None]); it.invoke()
    o=it.get_tensor(out['index'])[0]; e=np.exp(o-o.max(-1,keepdims=True)); return e/e.sum(-1,keepdims=True),(x0,y0,x1,y1)

def paste(dst, prob, box, combine):
    x0,y0,x1,y1=box; H,W=dst.shape
    pm=np.asarray(Image.fromarray((prob*255).astype(np.uint8)).resize((x1-x0,y1-y0),Image.BILINEAR),np.float32)/255
    ax0,ay0,ax1,ay1=max(0,x0),max(0,y0),min(W,x1),min(H,y1)
    dst[ay0:ay1,ax0:ax1]=combine(dst[ay0:ay1,ax0:ax1],pm[ay0-y0:ay1-y0,ax0-x0:ax1-x0])

for n in sys.argv[3:]:
    im=Image.open(f'{D}/{n}.jpg').convert('RGB'); W,H=im.size
    hair=np.zeros((H,W),np.float32); bg=np.ones((H,W),np.float32); acc=np.zeros((H,W),np.float32)
    for f in json.load(open(f'{S}/{n}.lm.json')):
        bx,by,bw,bh=f['box']; cx,cy=bx+bw/2,by+bh/2
        pr,box=classes_in_crop(im,cx,cy,max(bw,bh)*3.6)
        paste(hair,pr[...,1],box,np.maximum); paste(bg,pr[...,0],box,np.minimum)
        pr,box=classes_in_crop(im,cx,cy-bh*0.1,max(bw,bh)*1.4)
        paste(acc,pr[...,5],box,np.maximum)
    np.save(f'{S}/{n}.hair.npy',hair.astype(np.float16)); np.save(f'{S}/{n}.bg.npy',bg.astype(np.float16)); np.save(f'{S}/{n}.acc.npy',acc.astype(np.float16))
    print(n)
