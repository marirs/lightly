"""Parity fixture for ClosedFormMatting.kt: a 96x96 crop of pd03's hair band at the 768 working size (sRGB floats),
its trimap (MODNet, sure 0.95, eroded 3) and pymatting.estimate_alpha_cf's result. Little-endian float32 files."""
import numpy as np, cv2, json
from PIL import Image, ImageOps
from pymatting import estimate_alpha_cf
exec(open('stages.py').read().split("if __name__")[0])
OUT='/Users/sg/Documents/Dev/Projects/lightly/android/core-vision/src/test/resources/closed-form'
full=np.asarray(ImageOps.exif_transpose(Image.open(f'{S}/iosbg/pd03_full.jpg').convert('RGB')))/255.; H,W,_=full.shape
s=1600/max(W,H); dw,dh=round(W*s),round(H*s); disp=area(full,dw,dh); a0=np.clip(bil(modnet(disp),dw,dh),0,1)
s2=768/max(W,H); ww,wh=round(W*s2),round(H*s2); img=area(full,ww,wh); aw=np.clip(bil(a0,ww,wh),0,1)
k=np.ones((7,7),np.uint8); fg=cv2.erode((aw>=0.95).astype(np.uint8),k)>0; bg=cv2.erode((aw<=0.05).astype(np.uint8),k)>0
tri=np.full(aw.shape,0.5); tri[fg]=1; tri[bg]=0
unk=(tri>0)&(tri<1); ys,xs=np.nonzero(unk[:wh//2])
for i in np.linspace(0,len(ys)-1,200).astype(int):
  y0,x0=max(0,ys[i]-48),max(0,xs[i]-48); c=tri[y0:y0+96,x0:x0+96]
  if c.shape==(96,96) and (c==0).mean()>0.2 and (c==1).mean()>0.2 and ((c>0)&(c<1)).mean()>0.1: break
crop=lambda a:a[y0:y0+96,x0:x0+96]
ci,ct=crop(img),crop(tri); ca=np.clip(estimate_alpha_cf(ci,ct),0,1)
ci.astype('<f4').tofile(f'{OUT}/image.f32'); np.where(ct==0.5,np.nan,ct).astype('<f4').tofile(f'{OUT}/trimap.f32'); ca.astype('<f4').tofile(f'{OUT}/alpha.f32')
json.dump({'width':96,'height':96,'unknown':int(((ct>0)&(ct<1)).sum()),'source':'pd03_full.jpg at 768, crop (%d,%d)'%(x0,y0)},open(f'{OUT}/fixture.json','w'))
print('unknown',int(((ct>0)&(ct<1)).sum()))
