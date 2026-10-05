import sys, numpy as np, cv2
from PIL import Image, ImageOps
S='/Users/sg/Documents/Dev/Projects/lightly/experiments/depth/out/portrait-edges-2026-10-05'
M='/Users/sg/Documents/Dev/Projects/lightly/ios/Tests/Fixtures/SubjectMattes'
def load(p): return np.asarray(ImageOps.exif_transpose(Image.open(p)).convert('RGB')).astype(np.float64)/255
cases=[('pm02','portrait_medium_02','pm02_12mp.jpg'),('pd03','portrait_deep_03','pd03_full.jpg')]
for tag,mname,src in cases:
  orig=load(f'{S}/iosbg/{src}'); h,w,_=orig.shape
  m=cv2.resize(np.asarray(Image.open(f'{M}/{mname}.png').convert('L'))/255.,(w,h))
  band=cv2.dilate(((m>0.02)&(m<0.98)).astype(np.uint8),np.ones((15,15)))>0
  ys,xs=np.where(band&(np.arange(h)[:,None]<h*0.45))  # head/hair region
  y0,x0=ys.min(),xs.min(); y1,x1=ys.max(),xs.max()
  tiles=[]
  for sc in ('dark','light'):
    row=[orig]
    files=[f'{S}/iosbg/{tag}-{sc}-saved.JPG']
    a=f'{S}/fg-{tag}-{sc}/saved.jpg'
    import os
    if os.path.exists(a): files.append(a)
    for f in files:
      im=load(f)
      if im.shape[:2]!=(h,w): im=cv2.resize(im,(w,h),interpolation=cv2.INTER_AREA)
      row.append(im)
      redx=np.clip(im[...,0]-(im[...,1]+im[...,2])/2,0,1)[band].mean()*255
      # residual old-background luminance: in band, difference from a pure F*a+repl*(1-a) can't be known; report mean band luma
      print(tag,sc,f.split('/')[-2]+'/'+f.split('/')[-1],f'{im.shape[1]}x{im.shape[0]}' ,'band red excess %.2f'%redx)
    crop=[ (r[y0:y1,x0:x1]*255).astype(np.uint8) for r in row]
    tiles.append(np.concatenate(crop,1))
  W=max(t.shape[1] for t in tiles)
  tiles=[np.pad(t,((0,0),(0,W-t.shape[1]),(0,0))) for t in tiles]
  sheet=np.concatenate(tiles,0); s=1600/sheet.shape[1]
  Image.fromarray(sheet).resize((1600,int(sheet.shape[0]*s)),Image.LANCZOS).save(f'{S}/iosbg/{tag}-sheet.png')
  # 1:1 zoom on hair edge top
  cy,cx=y0+(y1-y0)//6,(x0+x1)//2; z=[(r[cy-150:cy+150,cx-300:cx+300]*255).astype(np.uint8) for r in [orig]+[load(f'{S}/iosbg/{tag}-{sc}-saved.JPG') for sc in ('dark','light')]]
  Image.fromarray(np.concatenate(z,1)).save(f'{S}/iosbg/{tag}-zoom.png')
