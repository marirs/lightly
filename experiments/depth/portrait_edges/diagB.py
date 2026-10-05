# At teal pixels (pm02-dark, working res): the estimate's background B vs the real wall next to the hair, and the alpha
# that would make F neutral given that B (i.e. how far MODNet's alpha would have to move).
import numpy as np, cv2
from PIL import Image, ImageOps
from pymatting import estimate_foreground_ml
import importlib.util; spec=importlib.util.spec_from_file_location('st',f'{S}/stages/stages.py') if False else None
S='/Users/sg/Documents/Dev/Projects/lightly/experiments/depth/out/portrait-edges-2026-10-05'
import sys; sys.argv=['x']; exec(open(f'{S}/stages/stages.py').read().split("if __name__")[0])
full=np.asarray(ImageOps.exif_transpose(Image.open(f'{S}/iosbg/pm02_12mp.jpg')).convert('RGB'))/255.; H,W,_=full.shape
s=1600/max(W,H); dw,dh=round(W*s),round(H*s); disp=area(full,dw,dh); a_d=np.clip(bil(modnet(disp),dw,dh),0,1)
s=768/max(W,H); ww,wh=round(W*s),round(H*s); a=np.clip(bil(a_d,ww,wh),0,1); I=lin(area(full,ww,wh))
F,B=estimate_foreground_ml(I,a,return_background=True); F=np.clip(F,0,1); B=np.clip(B,0,1)
head=np.zeros(a.shape,bool); head[:int(wh*.45)]=True
Fs=enc(F)*255; teal=head&(a>0.02)&(a<0.98)&((Fs[...,1]+Fs[...,2])/2-Fs[...,0]>8)
wall=head&(a<0.02)&(enc(I)[...,0]*255-(enc(I)[...,1]+enc(I)[...,2])*127.5>60)
print('teal px (working)',teal.sum())
print('B at teal (sRGB)',(enc(B[teal])*255).mean(0).round(0),' real red wall (sRGB, a<0.02)',(enc(I[wall])*255).mean(0).round(0))
# alpha that makes F_r = F_g given I and B: I_c = a F_c + (1-a) B_c, F_r=F_g -> (I_r-(1-a)B_r)=(I_g-(1-a)B_g)
# -> 1-a = (I_r-I_g)/(B_r-B_g)
need=1-np.clip((I[...,0]-I[...,1])/np.maximum(B[...,0]-B[...,1],1e-4),0,1)
print('MODNet alpha at teal p50 %.3f; alpha giving neutral F p50 %.3f (p10 %.3f, p90 %.3f)'%(np.median(a[teal]),np.median(need[teal]),*np.percentile(need[teal],[10,90])))
