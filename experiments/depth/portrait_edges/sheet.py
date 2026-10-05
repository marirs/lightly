import numpy as np, cv2
from PIL import Image, ImageOps, ImageDraw, ImageFont
S='/Users/sg/Documents/Dev/Projects/lightly/experiments/depth/out/portrait-edges-2026-10-05'
L=lambda p: np.asarray(ImageOps.exif_transpose(Image.open(p)).convert('RGB'))
font=ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc',26)
# head crop (x0,y0,x1,y1 as fractions) and a 1:1 detail window centre (fractions) per portrait
geo={'pm02':((0.08,0.06,0.72,0.36),(0.30,0.12)),'pd03':((0.18,0.04,0.82,0.36),(0.33,0.10))}
src={'pm02':'iosbg/pm02_12mp.jpg','pd03':'iosbg/pd03_full.jpg'}
rows=[]
for tag in ('pm02','pd03'):
  o=L(f'{S}/{src[tag]}'); H,W,_=o.shape
  m=cv2.resize(np.asarray(Image.open('/Users/sg/Documents/Dev/Projects/lightly/ios/Tests/Fixtures/SubjectMattes/'+{'pm02':'portrait_medium_02','pd03':'portrait_deep_03'}[tag]+'.png').convert('L'))/255.,(W,H))
  band=(m>0.02)&(m<0.98); band[int(H*.45):]=False; ys,xs=np.where(band)
  fy0,fy1,fx0,fx1=max(0,ys.min()-60)/H,min(H,ys.max()+60)/H,max(0,xs.min()-60)/W,min(W,xs.max()+60)/W
  cx,cy=(xs.min()+0.22*(xs.max()-xs.min()))/W,(ys.min()+0.30*(ys.max()-ys.min()))/H
  if tag=='pd03':  # dark-on-dark: the band is wide; window on the hair edge at the top-left of the head
    top=np.where((m>0.5).any(1))[0][0]; row=np.where(m[top+120]>0.5)[0]; cx,cy=(row[0]+40)/W,(top+120)/H
    fy0,fy1=max(0,top-200)/H,min(H,top+1500)/H; c0=np.where(m[top+600]>0.5)[0]; fx0,fx1=max(0,c0[0]-300)/W,min(W,c0[-1]+300)/W
  for sc in ('dark','light'):
    ims=[('Original',o),('iOS saved (recorded Mac Vision matte)',L(f'{S}/iosbg/{tag}-{sc}-saved.JPG')),('Android saved (MODNet + fg estimate)',L(f'{S}/fg-{tag}-{sc}/saved.jpg'))]
    tiles=[]
    for name,im in ims:
      c=im[int(H*fy0):int(H*fy1),int(W*fx0):int(W*fx1)]; c=cv2.resize(c,(560,int(560*c.shape[0]/c.shape[1])),interpolation=cv2.INTER_AREA)
      z=im[int(H*cy)-140:int(H*cy)+140,int(W*cx)-140:int(W*cx)+140]
      z=cv2.resize(z,(c.shape[0],c.shape[0]),interpolation=cv2.INTER_NEAREST)  # 1:1 window, enlarged
      t=Image.fromarray(np.concatenate([c,z],1)); d=ImageDraw.Draw(t); d.rectangle([0,0,t.width,34],fill=(255,255,255)); d.text((6,3),f'{tag} {sc} | {name}',fill=(0,0,0),font=font)
      tiles.append(np.asarray(t))
    rows.append(np.concatenate(tiles,1))
w=max(r.shape[1] for r in rows); sheet=np.concatenate([np.pad(r,((0,8),(0,w-r.shape[1]),(0,0)),constant_values=255) for r in rows],0)
Image.fromarray(sheet).save('/Users/sg/Documents/Dev/Projects/lightly/experiments/depth/results/portrait-edges-2026-10-05.jpg',quality=90)
print(sheet.shape)
