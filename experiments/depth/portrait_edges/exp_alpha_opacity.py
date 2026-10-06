"""A4 diagnostic (2026-10-06): the teal comes from MODNet alpha too low in dense curls (median 0.62 where the
compositing equation needs ~0.99), so the foreground estimate over-subtracts the wall. Variants of the alpha, applied
before the estimate and the composite, fixed in advance (not tuned): shipped; levels 0.1 -> 0, 0.7 -> 1; gamma 0.6.
Everything else as the Android pipeline (stages.py). Metrics as exp_guided.py: head soft band teal px (cyan > 8) and
red excess; haze = mean |output - replacement| in a ring just outside Vision's matte."""
import numpy as np, cv2
from PIL import Image, ImageOps
from pymatting import estimate_foreground_ml
exec(open('stages.py').read().split("if __name__")[0])
M='/Users/sg/Documents/Dev/Projects/lightly/ios/Tests/Fixtures/SubjectMattes'
SELFIE='/Users/sg/Documents/Dev/Projects/lightly/experiments/android-vision/models/selfie_segmenter.tflite'
def selfie(rgb):
  it2=Interpreter(model_path=SELFIE); it2.allocate_tensors()
  x=cv2.resize(rgb.astype(np.float32),(256,256),interpolation=cv2.INTER_LINEAR)
  it2.set_tensor(it2.get_input_details()[0]['index'],x[None]); it2.invoke()
  return it2.get_tensor(it2.get_output_details()[0]['index'])[0,:,:,0].astype(np.float64)
import sys
ONLY=sys.argv[1:] or None
VARIANTS={'shipped':lambda a:a, 'levels.1-.7':lambda a:np.clip((a-0.1)/0.6,0,1), 'gamma.6':lambda a:a**0.6,
          'min-selfie-head':None, 'closed-form':'cf', 'closed-form+noclip':'cf'}
from pymatting import estimate_alpha_cf
for tag,src,mname in (('pm02',f'{S}/iosbg/pm02_12mp.jpg','portrait_medium_02'),('pd03',f'{S}/iosbg/pd03_full.jpg','portrait_deep_03')):
  full=np.asarray(ImageOps.exif_transpose(Image.open(src)).convert('RGB'))/255.; H,W,_=full.shape
  s=1600/max(W,H); dw,dh=round(W*s),round(H*s); disp=area(full,dw,dh)
  a0=np.clip(bil(modnet(disp),dw,dh),0,1)
  vis=bil(np.asarray(Image.open(f'{M}/{mname}.png').convert('L'))/255.,dw,dh); vfull=bil(vis,W,H)
  head=np.zeros((H,W),bool); head[:int(H*.45)]=True
  ring=head&(cv2.dilate((vfull>0.5).astype(np.uint8),np.ones((61,61)))>0)&(vfull<0.05)
  I=lin(full); s2=768/max(W,H); ww,wh=round(W*s2),round(H*s2); Iw=lin(area(full,ww,wh))
  person=np.clip(bil(selfie(disp),dw,dh),0,1); headd=np.zeros((dh,dw),bool); headd[:int(dh*.45)]=True
  for vname,f in VARIANTS.items():
    if ONLY and vname not in ONLY: continue
    if f == 'cf':
      # Closed-form matting (Levin et al.) at the working size; trimap from MODNet: sure fg >= 0.95 (eroded 3 px),
      # sure bg <= 0.05 (eroded 3 px), the rest unknown. Solved on the sRGB working image.
      a_w0=np.clip(bil(a0,ww,wh),0,1); k=np.ones((7,7),np.uint8)
      fg=cv2.erode((a_w0>=0.95).astype(np.uint8),k)>0; bg=cv2.erode((a_w0<=0.05).astype(np.uint8),k)>0
      tri=np.full(a_w0.shape,0.5); tri[fg]=1; tri[bg]=0
      aw=np.clip(estimate_alpha_cf(area(full,ww,wh),tri),0,1)
    else:
      ad=np.where(headd,np.minimum(a0,person),a0) if f is None else f(a0); aw=np.clip(bil(ad,ww,wh),0,1)
    Fr=estimate_foreground_ml(Iw,aw); shift=np.clip(Fr,0,1)-Iw
    if vname.endswith('noclip'):
      # where the estimate had to be clipped (a channel outside [0,1]), no colour shift at that pixel
      clipped=((Fr<0)|(Fr>1)).any(-1); shift[clipped]=0
    a=np.clip(bil(aw,W,H),0,1)[...,None]
    band=head&(a[...,0]>0.02)&(a[...,0]<0.98)
    row=[]
    for sc,hexc in (('dark',(0x1F,0x23,0x28)),('light',(0xF4,0xF1,0xEC))):
      repl=lin(np.array(hexc)/255.); on=enc(np.clip(I+bil(shift,W,H),0,1)*a+repl*(1-a))*255
      cy=(on[...,1]+on[...,2])/2-on[...,0]; rd=on[...,0]-(on[...,1]+on[...,2])/2
      row.append(f'{sc}: teal {int((band&(cy>8)).sum()):6d} red {np.clip(rd,0,None)[band].mean():5.1f} haze {np.abs(on[ring]-enc(repl)*255).mean():5.1f}')
      Image.fromarray(on.astype(np.uint8)).save(f'{S}/stages/alpha-{tag}-{sc}-{vname}.png')
    print(f'{tag} {vname:12s} ' + ' | '.join(row), flush=True)
