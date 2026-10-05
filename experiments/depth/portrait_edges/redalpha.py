import numpy as np, cv2
from PIL import Image, ImageOps
S='/Users/sg/Documents/Dev/Projects/lightly/experiments/depth/out/portrait-edges-2026-10-05'
o=np.asarray(ImageOps.exif_transpose(Image.open(f'{S}/iosbg/pm02_12mp.jpg')).convert('RGB'))/255.
h,w,_=o.shape
m=cv2.resize(np.asarray(Image.open('/Users/sg/Documents/Dev/Projects/lightly/ios/Tests/Fixtures/SubjectMattes/portrait_medium_02.png').convert('L'))/255.,(w,h))
ios=np.asarray(Image.open(f'{S}/iosbg/pm02-dark-saved.JPG').convert('RGB'))/255.
redo=o[...,0]-(o[...,1]+o[...,2])/2
redi=ios[...,0]-(ios[...,1]+ios[...,2])/2
sel=(redi>0.2)&(np.arange(h)[:,None]<h*0.4)
print('iOS output red pixels in head region:',sel.sum())
print('fixture alpha at those pixels: percentiles 10/50/90',np.percentile(m[sel],[10,50,90]).round(3))
print('fixture size',Image.open('/Users/sg/Documents/Dev/Projects/lightly/ios/Tests/Fixtures/SubjectMattes/portrait_medium_02.png').size)
