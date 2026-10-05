import numpy as np
S='/Users/sg/Documents/Dev/Projects/lightly/experiments/depth/out/portrait-edges-2026-10-05'
for tag in ('pm02-dark','pm02-light','pd03-light','pd03-dark'):
  z=np.load(f'{S}/stages/{tag}.npz'); f=lambda k:z[k].astype(float)
  on,off,I,F,a=f('on'),f('off'),f('I'),f('F'),f('alpha')/255
  H=on.shape[0]; head=np.zeros(a.shape,bool); head[:int(H*.45)]=True
  band=head&(a>0.02)&(a<0.98)
  cyan=lambda x:(x[...,1]+x[...,2])/2-x[...,0]; red=lambda x:x[...,0]-(x[...,1]+x[...,2])/2
  teal=band&(cyan(on)>8)
  print(tag,'band px',band.sum(),'| teal(on) px',teal.sum(),'teal(off) px',(band&(cyan(off)>8)).sum(),
        '| band red excess off %.1f on %.1f'%(np.clip(red(off),0,None)[band].mean(),np.clip(red(on),0,None)[band].mean()))
  if teal.sum():
    print('   at teal px: alpha p10/50/90',np.percentile(a[teal],[10,50,90]).round(2),
          ' I rgb',I[teal].mean(0).round(0),' F rgb',F[teal].mean(0).round(0),' F red==0 frac %.2f'%(F[teal][:,0]<=2).mean())
  # haze: band pixels where output is darker than replacement but original was background-like
