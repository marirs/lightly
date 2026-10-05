# Does area-average downsampling (cv2 INTER_AREA = PortraitMatting.areaDownsample for these ratios) reproduce
# the reference (skimage anti-aliased) output closely enough for the no-subject rule?
import numpy as np, cv2
from PIL import Image
from skimage import transform
exec(open(__file__.replace('u2netp_area_check.py','u2netp_calibrate.py')).read().split('truth=')[0])
import os
for n in ('subject_boat','subject_swan','backlit_02','group_three_01','landscape_02','landscape_03','sunset_02','night_03','portrait_light_01'):
    im=np.asarray(Image.open(f'{U}/photos/{n}.jpg').convert('RGB'))
    ref=run(transform.resize(im,(320,320),mode='constant')); ar=run(cv2.resize(im.astype(np.float32)/255,(320,320),interpolation=cv2.INTER_AREA))
    print(n.ljust(18),'max|area-ref| %.3f mean %.4f'%(np.abs(ar-ref).max(),np.abs(ar-ref).mean()),' area90 ref %.4f area %.4f'%((ref>=.9).mean(),(ar>=.9).mean()))
