"""One targeted correction: MODNet alpha refined by a colour guided filter (He et al., guide = display sRGB photo,
r = 0.5 % of the long edge = 8 px at 1600, eps = 1e-4), clipped to [0,1]; everything else as the Android pipeline
(stages.py). Fixed a priori, not tuned. Metrics on the head region; Vision's macOS matte is a reference, not truth."""
import numpy as np, cv2, json
from PIL import Image, ImageOps
from pymatting import estimate_foreground_ml
S='/Users/sg/Documents/Dev/Projects/lightly/experiments/depth/out/portrait-edges-2026-10-05'
exec(open(f'{S}/stages/stages.py').read().split("if __name__")[0])
exec(open(f'{S}/matte_lab.py').read().split("def plate")[0].split("def box")[1].join(["def box",""]) if False else "")
def box(x,r): return cv2.boxFilter(x,-1,(2*r+1,2*r+1),normalize=True,borderType=cv2.BORDER_REFLECT)
def guided_rgb(I,p,r,eps):
  h,w,_=I.shape; mI=np.stack([box(I[...,c],r) for c in range(3)],-1); mp=box(p,r)
  cov=np.stack([box(I[...,c]*p,r) for c in range(3)],-1)-mI*mp[...,None]
  var=np.zeros((h,w,3,3))
  for i in range(3):
    for j in range(3): var[...,i,j]=box(I[...,i]*I[...,j],r)-mI[...,i]*mI[...,j]
  var+=eps*np.eye(3); a=np.linalg.solve(var,cov[...,None])[...,0]; b=mp-(a*mI).sum(-1)
  return (np.stack([box(a[...,c],r) for c in range(3)],-1)*I).sum(-1)+box(b,r)
M='/Users/sg/Documents/Dev/Projects/lightly/ios/Tests/Fixtures/SubjectMattes'
res={}
for tag,src,mname in (('pm02',f'{S}/iosbg/pm02_12mp.jpg','portrait_medium_02'),('pd03',f'{S}/iosbg/pd03_full.jpg','portrait_deep_03')):
  full=np.asarray(ImageOps.exif_transpose(Image.open(src)).convert('RGB'))/255.; H,W,_=full.shape
  s=1600/max(W,H); dw,dh=round(W*s),round(H*s); disp=area(full,dw,dh)
  a0=np.clip(bil(modnet(disp),dw,dh),0,1); a1=np.clip(guided_rgb(disp,a0,8,1e-4),0,1)
  vis=bil(np.asarray(Image.open(f'{M}/{mname}.png').convert('L'))/255.,dw,dh)
  for vname,ad in (('modnet',a0),('modnet+cgf',a1)):
    s2=768/max(W,H); ww,wh=round(W*s2),round(H*s2); aw=np.clip(bil(ad,ww,wh),0,1); Iw=lin(area(full,ww,wh))
    shift=np.clip(estimate_foreground_ml(Iw,aw),0,1)-Iw; a=np.clip(bil(aw,W,H),0,1)[...,None]; I=lin(full)
    head=np.zeros((H,W),bool); head[:int(H*.45)]=True; band=head&(a[...,0]>0.02)&(a[...,0]<0.98)
    vfull=bil(vis,W,H); ring=head&(cv2.dilate((vfull>0.5).astype(np.uint8),np.ones((61,61)))>0)&(vfull<0.05)
    r={'iou_vs_vision_display':float(((ad>.5)&(vis>.5)).sum()/((ad>.5)|(vis>.5)).sum()),'soft_px_display':int(((ad>.05)&(ad<.95)).sum())}
    for sc,hexc in (('dark',(0x1F,0x23,0x28)),('light',(0xF4,0xF1,0xEC))):
      repl=lin(np.array(hexc)/255.); on=enc(np.clip(I+bil(shift,W,H),0,1)*a+repl*(1-a))*255
      cy=(on[...,1]+on[...,2])/2-on[...,0]; rd=on[...,0]-(on[...,1]+on[...,2])/2
      r[f'{sc}_teal_px']=int((band&(cy>8)).sum()); r[f'{sc}_red_excess']=float(np.clip(rd,0,None)[band].mean())
      r[f'{sc}_ring_dev']=float(np.abs(on[ring]-enc(repl)*255).mean())  # haze: departure from replacement just outside Vision's edge
      np.save(f'{S}/stages/{tag}-{sc}-{vname}.npy',on.astype(np.uint8))
    res[f'{tag} {vname}']=r
for k,v in res.items(): print(k.ljust(18),' '.join(f'{a}={b:.3f}' if isinstance(b,float) else f'{a}={b}' for a,b in v.items()))
