"""U²-Netp reference evaluation (PyTorch, upstream code), before any conversion.
Provenance: model/u2net.py at xuebinqin/U-2-Net ac7e1c8 (sha256 96dd7a19…f415, byte-identical to upstream);
u2netp.pth from the README's Google Drive link (sha256 e7567cde…b854). Loaded with weights_only=True (restricted
unpickler: tensors and plain containers only). Preprocessing exactly u2net_test.py: skimage resize to 320x320
(mode='constant'), image / max, ImageNet mean/std, NCHW; output d1. Reports raw sigmoid and the upstream normPRED."""
import hashlib, sys, json, numpy as np, torch
from PIL import Image
from skimage import transform
import os
# Inputs: photos/, vision_ref/ and u2net/{u2net.py,u2netp.pth} (see convert_u2netp.py for the sources).
U=os.environ.get('U2NETP_WORK', os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'work', 'u2netp-eval'))
assert hashlib.sha256(open(f'{U}/u2net/u2netp.pth','rb').read()).hexdigest()=='e7567cde013fb64813973ce6e1ecc25a80c05c3ca7adbc5a54f3c3d90991b854'
assert hashlib.sha256(open(f'{U}/u2net/u2net.py','rb').read()).hexdigest()=='96dd7a19c7de4f13520ccfc1075ded3350ff4946493be3561b9918a46218f415'
sys.path.insert(0,f'{U}/u2net'); from u2net import U2NETP
net=U2NETP(3,1); net.load_state_dict(torch.load(f'{U}/u2net/u2netp.pth',map_location='cpu',weights_only=True)); net.eval()
def run(path):
    im=np.asarray(Image.open(path).convert('RGB'))
    x=transform.resize(im,(320,320),mode='constant'); x=x/np.max(x)
    t=np.zeros_like(x); 
    for c,(m,s) in enumerate(((0.485,0.229),(0.456,0.224),(0.406,0.225))): t[...,c]=(x[...,c]-m)/s
    with torch.no_grad(): d1=net(torch.from_numpy(t.transpose(2,0,1)[None]).float())[0][0,0].numpy()
    return im,d1
out={}
for name in ('subject_boat','subject_swan','landscape_02'):
    im,d=run(f'{U}/photos/{name}.jpg'); h,w,_=im.shape
    raw=np.asarray(Image.fromarray((d*255).astype(np.uint8)).resize((w,h),Image.BILINEAR))/255.
    r={'raw_max':float(d.max()),'raw_mean':float(d.mean()),'area_gt_0.5':float((d>0.5).mean()),'area_gt_0.9':float((d>0.9).mean())}
    try:
        ref=np.asarray(Image.open(f'{U}/vision_ref/{name}.png').convert('L').resize((w,h)))/255.
        r['iou_vs_vision']=float(((raw>.5)&(ref>.5)).sum()/((raw>.5)|(ref>.5)).sum())
    except FileNotFoundError: r['vision']='no subject (Vision .none)'
    Image.fromarray((raw*255).astype(np.uint8)).save(f'{U}/u2eval/{name}_u2netp_raw.png')
    out[name]=r; print(name, json.dumps(r))
json.dump(out,open(f'{U}/u2eval/results.json','w'),indent=1)
