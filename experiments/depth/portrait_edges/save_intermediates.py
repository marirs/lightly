"""Writes the tracked intermediates of the Android replace path (stages.py) for both portraits:
MODNet alpha at the display size (1600 long edge) and the Germer foreground estimate F at the Save-copy working
size (768), sRGB-encoded 8-bit PNG. Inputs: the evidence folder's iosbg/ photos (same bytes as the emulator's)."""
import numpy as np
from PIL import Image, ImageOps
from pymatting import estimate_foreground_ml
import os
HERE=os.path.dirname(os.path.abspath(__file__))
exec(open(f'{HERE}/stages.py').read().split("if __name__")[0])
EVID='/Users/sg/Documents/Dev/Projects/lightly/experiments/depth/out/portrait-edges-2026-10-05'
RES='/Users/sg/Documents/Dev/Projects/lightly/experiments/depth/results/portrait-edges-2026-10-05'
for tag,f in (('pm02','pm02_12mp.jpg'),('pd03','pd03_full.jpg')):
  full=np.asarray(ImageOps.exif_transpose(Image.open(f'{EVID}/iosbg/{f}')).convert('RGB'))/255.; H,W,_=full.shape
  s=1600/max(W,H); dw,dh=round(W*s),round(H*s); a_d=np.clip(bil(modnet(area(full,dw,dh)),dw,dh),0,1)
  s=768/max(W,H); ww,wh=round(W*s),round(H*s); a_w=np.clip(bil(a_d,ww,wh),0,1); I_w=lin(area(full,ww,wh))
  F=np.clip(estimate_foreground_ml(I_w,a_w),0,1)
  Image.fromarray((a_d*255+.5).astype(np.uint8)).save(f'{RES}/{tag}-modnet-alpha-{dw}x{dh}.png')
  Image.fromarray((enc(F)*255+.5).astype(np.uint8)).save(f'{RES}/{tag}-foreground-estimate-{ww}x{wh}.png')
  Image.fromarray((a_w*255+.5).astype(np.uint8)).save(f'{RES}/{tag}-modnet-alpha-{ww}x{wh}.png')
