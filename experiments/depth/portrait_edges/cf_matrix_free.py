"""Matrix-free closed-form matting (the Kotlin design), checked against pymatting.estimate_alpha_cf on the same input.
L x over 3x3 windows: for window k with mean mu, covariance S, M = (S + eps/9 I)^-1:
(Lx)_i += x_i - (sum_j x_j + (I_i - mu)^T M sum_j (I_j - mu) x_j) / 9 for i, j in the window.
Unknown pixels are solved (known ones fixed at the trimap), Jacobi-preconditioned CG, windows touching an unknown only."""
import numpy as np, cv2, time, sys
from PIL import Image, ImageOps
from pymatting import estimate_alpha_cf
exec(open('stages.py').read().split("if __name__")[0])
EPS=1e-7
def windows(img, active):
  h,w,_=img.shape; ks=[]
  for y in range(1,h-1):
    for x in range(1,w-1):
      if active[y-1:y+2,x-1:x+2].any(): ks.append((y,x))
  return ks
def solve(img, tri, iters=2000, tol=1e-6, warm=None):
  h,w,_=img.shape; unknown=(tri>0)&(tri<1); n=h*w
  # windows touching an unknown pixel, with their mean and inverse regularised covariance
  uy,ux=np.nonzero(cv2.dilate(unknown.astype(np.uint8),np.ones((3,3)))>0)
  sel=(uy>=1)&(uy<h-1)&(ux>=1)&(ux<w-1); cy,cx=uy[sel],ux[sel]
  offs=[(dy,dx) for dy in (-1,0,1) for dx in (-1,0,1)]
  P=np.stack([img[cy+dy,cx+dx] for dy,dx in offs],1)          # K x 9 x 3
  mu=P.mean(1); D=P-mu[:,None,:]; S=np.einsum('kni,knj->kij',D,D)/9
  M=np.linalg.inv(S+EPS/9*np.eye(3)); idx=np.stack([(cy+dy)*w+(cx+dx) for dy,dx in offs],1)  # K x 9
  G=np.einsum('kni,kij,kmj->knm',D,M,D)                         # K x 9 x 9: (I_i-mu)^T M (I_j-mu)
  diag=np.zeros(n); np.add.at(diag,idx.ravel(),(1-(1+np.einsum('knn->kn',G))/9).ravel())
  def Lx(x):
    xs=x[idx]; out=np.zeros(n)
    np.add.at(out,idx.ravel(),(xs-(xs.sum(1,keepdims=True)+np.einsum('knm,km->kn',G,xs))/9).ravel())
    return out
  u=unknown.ravel(); x0=tri.ravel().astype(float).copy(); x0[u]=0
  b=-Lx(x0)[u]; x=np.zeros(u.sum()) if warm is None else warm.ravel()[u].astype(float).copy()
  full=x0.copy(); full[:]=0; full[u]=x; r=b-Lx(full)[u]; Minv=1/np.maximum(diag[u],1e-12); z=r*Minv; p=z.copy(); rz=r@z; bn=np.linalg.norm(b)
  for it in range(iters):
    full[:]=0; full[u]=p; Ap=Lx(full)[u]; a=rz/(p@Ap); x+=a*p; r-=a*Ap
    if np.linalg.norm(r)<=tol*bn: break
    z=r*Minv; rz2=r@z; p=z+(rz2/rz)*p; rz=rz2
  out=x0.copy(); out[u]=x; return np.clip(out.reshape(h,w),0,1), it+1
full=np.asarray(ImageOps.exif_transpose(Image.open(f'{S}/iosbg/pd03_full.jpg').convert('RGB')))/255.; H,W,_=full.shape
s=1600/max(W,H); dw,dh=round(W*s),round(H*s); disp=area(full,dw,dh); a0=np.clip(bil(modnet(disp),dw,dh),0,1)
s2=768/max(W,H); ww,wh=round(W*s2),round(H*s2); img=area(full,ww,wh); aw=np.clip(bil(a0,ww,wh),0,1)
k=np.ones((7,7),np.uint8); fg=cv2.erode((aw>=0.95).astype(np.uint8),k)>0; bg=cv2.erode((aw<=0.05).astype(np.uint8),k)>0
tri=np.full(aw.shape,0.5); tri[fg]=1; tri[bg]=0
print('unknown px',int(((tri>0)&(tri<1)).sum()),'of',tri.size)
ref,_=solve(img,tri,iters=5000,tol=1e-10)
U=(tri>0)&(tri<1)
def coarse_start(img,aw,levels):
  if levels==0: return aw
  h,w=aw.shape; hs,ws=h//2,w//2
  im2=area(img,ws,hs); a2=np.clip(bil(aw,ws,hs),0,1)
  fg=cv2.erode((a2>=0.95).astype(np.uint8),np.ones((5,5),np.uint8))>0; bg=cv2.erode((a2<=0.05).astype(np.uint8),np.ones((5,5),np.uint8))>0
  t2=np.full(a2.shape,0.5); t2[fg]=1; t2[bg]=0
  st=coarse_start(im2,a2,levels-1)
  sol,n=solve(im2,t2,iters=5000,tol=1e-5,warm=st); print('  level %dx%d: %d iters, %d unknown'%(ws,hs,n,int(((t2>0)&(t2<1)).sum())))
  return np.clip(bil(sol,w,h),0,1)
for levels in (0,1,2):
  st=coarse_start(img,aw,levels)
  for tol in (1e-4,1e-5):
    mine,n=solve(img,tri,iters=5000,tol=tol,warm=st); d=np.abs(mine-ref)[U]
    print('levels %d tol %g: full-res %d iters, max |diff| %.4f p99 %.4f'%(levels,tol,n,d.max(),np.percentile(d,99)))
