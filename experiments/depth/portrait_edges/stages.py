"""Android Background replace, stage by stage (offline): display 1600 -> MODNet (packaged LiteRT fp16, letterbox 512,
(x-0.5)/0.5, pad 0) -> bilinear to display -> bilinear to the Save-copy working size (768) -> Germer foreground
estimate (pymatting, = ForegroundEstimate.kt by golden) -> full-res composite with the shift OFF / ON.
Validated against the emulator's saved JPEG (same photo, same replacement)."""
import sys, numpy as np, cv2, json
from PIL import Image, ImageOps
from ai_edge_litert.interpreter import Interpreter
from pymatting import estimate_foreground_ml
S='/Users/sg/Documents/Dev/Projects/lightly/experiments/depth/out/portrait-edges-2026-10-05'
MODEL='/Users/sg/Documents/Dev/Projects/lightly/experiments/android-vision/models/modnet_photographic_512_fp16.tflite'
def lin(e): return np.where(e<=0.04045,e/12.92,((e+0.055)/1.055)**2.4)
def enc(l): l=np.clip(l,0,1); return np.where(l<=0.0031308,l*12.92,1.055*l**(1/2.4)-0.055)
def area(img,w,h): return cv2.resize(img,(w,h),interpolation=cv2.INTER_AREA)
def bil(img,w,h): return cv2.resize(img,(w,h),interpolation=cv2.INTER_LINEAR)
it=Interpreter(model_path=MODEL); it.allocate_tensors(); I_,O_=it.get_input_details()[0],it.get_output_details()[0]
def modnet(rgb):
  h,w,_=rgb.shape; s=512/max(w,h); fw,fh=max(1,round(w*s)),max(1,round(h*s)); x0,y0=(512-fw)//2,(512-fh)//2
  x=np.zeros((512,512,3),np.float32); x[y0:y0+fh,x0:x0+fw]=area(rgb.astype(np.float32),fw,fh)*2-1
  it.set_tensor(I_['index'],x[None]); it.invoke(); o=it.get_tensor(O_['index']).reshape(512,512)
  return np.clip(o[y0:y0+fh,x0:x0+fw],0,1).astype(np.float64)
def run(tag,src,hexc,saved):
  full=np.asarray(ImageOps.exif_transpose(Image.open(src)).convert('RGB'))/255.; H,W,_=full.shape
  s=1600/max(W,H); dw,dh=round(W*s),round(H*s); disp=area(full,dw,dh)
  a_disp=np.clip(bil(modnet(disp),dw,dh),0,1)
  s=768/max(W,H); ww,wh=round(W*s),round(H*s)
  a_w=np.clip(bil(a_disp,ww,wh),0,1); I_w=lin(area(full,ww,wh))
  F_w=np.clip(estimate_foreground_ml(I_w,a_w),0,1); shift=F_w-I_w
  a=np.clip(bil(a_w,W,H),0,1)[...,None]; I=lin(full); repl=lin(np.array(hexc)/255.)
  off=enc(I*a+repl*(1-a)); on=enc(np.clip(I+bil(shift,W,H),0,1)*a+repl*(1-a))
  out={'alpha':a[...,0],'I':full,'F':enc(bil(F_w,W,H)),'off':off,'on':on}
  if saved: out['android_saved']=np.asarray(Image.open(saved).convert('RGB'))/255.
  return out
if __name__=='__main__':
  import pickle
  cases=[('pm02-dark',f'{S}/iosbg/pm02_12mp.jpg',(0x1F,0x23,0x28),f'{S}/fg-pm02-dark/saved.jpg'),
         ('pm02-light',f'{S}/iosbg/pm02_12mp.jpg',(0xF4,0xF1,0xEC),f'{S}/fg-pm02-light/saved.jpg'),
         ('pd03-light',f'{S}/iosbg/pd03_full.jpg',(0xF4,0xF1,0xEC),f'{S}/fg-pd03-light/saved.jpg'),
         ('pd03-dark',f'{S}/iosbg/pd03_full.jpg',(0x1F,0x23,0x28),None)]
  for tag,src,hexc,saved in cases:
    o=run(tag,src,hexc,saved)
    if 'android_saved' in o:
      d=np.abs(o['on']-o['android_saved'])*255; print(tag,'offline ON vs emulator saved: mean %.2f p99 %.1f'%(d.mean(),np.percentile(d,99)))
    np.savez_compressed(f'{S}/stages/{tag}.npz',**{k:(v*255+.5).astype(np.uint8) for k,v in o.items()})
