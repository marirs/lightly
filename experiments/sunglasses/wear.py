# Put the 3D pair on each face: frame pass with the model's textures, lenses composited as tinted glass over the
# real photo (so eyes show through), soft contact shadow. Faces already wearing glasses get theirs painted out first.
import sys, json, math, subprocess, numpy as np
from PIL import Image, ImageFilter, ImageChops
S, MODEL, TEX, OUT = sys.argv[1:5]; jobs=[j.split(':') for j in sys.argv[5:]]  # dir:name
TRIS=np.load(S+'/facemesh_tris.npy'); EYE_DEPTH=0.015  # lens plane ~15 mm in front of the irises (12 mm vertex distance + cornea to iris)
TINT=np.array([0.20,0.23,0.21])  # G-15 style grey-green, about 20 % transmission
lama=None
def remove(im,M):
    global lama
    if lama is None:
        sys.argv=[None,S,MODEL,'x','0']; import importlib.util
        spec=importlib.util.spec_from_file_location('r2',S+'/lama_only.py'); lama=importlib.util.module_from_spec(spec); spec.loader.exec_module(lama)
    return lama.lama(im,M)
def nrm(v): return v/np.linalg.norm(v)
rows=[]
import os
GENERIC=os.path.isdir(MODEL)  # a normalize.py model folder -> render_glasses3
TAG=os.environ.get('WEAR_TAG','')
OVERHANG=0.008  # lens fronts stand ~8 mm proud of the nose bridge on a profile
MIN_FACE_SCORE=0.0  # landmarker face-presence logit; below this the mesh is not trusted and the face is skipped
PROFILE_MARGIN=0.007; PROFILE_YAW=math.radians(85)
def rotate_about(v,axis,ang):
    axis=nrm(axis); return v*math.cos(ang)+np.cross(axis,v)*math.sin(ang)+axis*np.dot(axis,v)*(1-math.cos(ang))
def profile_corrected_axes(P,ex,ey,ez,s,bg):
    """The face landmarker cannot report more than ~65 degrees of turn: on a profile it guesses the hidden far eye
    at the nose bridge. The photo itself tells us the far eye is at (or behind) the face outline, so when the far eye
    is within PROFILE_MARGIN of the outline the turn is raised toward PROFILE_YAW in proportion."""
    yaw=math.atan2(ez[0],ez[2]); near,far=(473,468) if yaw<0 else (468,473)
    d=nrm(P[far,:2]-P[near,:2]); x,y=P[far,:2]; H,W=bg.shape; margin=None
    for t in range(0,int(PROFILE_MARGIN*s)+1):
        xi,yi=int(x+d[0]*t),int(y+d[1]*t)
        if not(0<=xi<W and 0<=yi<H) or bg[yi,xi]>0.5: margin=t/s; break
    if margin is None or abs(yaw)>=PROFILE_YAW: return ex,ey,ez,False
    target=abs(yaw)+(PROFILE_YAW-abs(yaw))*(1-margin/PROFILE_MARGIN)
    ang=(target-abs(yaw))*math.copysign(1,yaw)
    # rotate the head about its own up axis; positive yaw turns ez toward +x (camera right)
    return rotate_about(ex,ey,ang),ey,rotate_about(ez,ey,ang),True
for d,n in jobs:
    im=Image.open(f'{d}/{n}.jpg').convert('RGB'); W,H=im.size
    base=im
    try:
        g=np.load(f'{S}/{n}.glasses.npy'); M=Image.fromarray(g.astype(np.uint8)*255).resize((W,H),Image.BILINEAR)
        try:  # sharper accessory mask from the face-sized crop (thin rims are lost at whole-photo resolution)
            acc=np.load(f'{S}/{n}.acc.npy').astype(np.float32)
            # only accessories in each face's eye band (brows to nose tip, temples included): keeps earrings,
            # hats and watches out while catching thin rims far from the coarse whole-photo mask
            band=np.zeros((H,W),bool)
            for fc in json.load(open(f'{S}/{n}.lm.json')):
                Q=np.array(fc['pts']); eyes=Q[[33,263,468,473]]; d=np.linalg.norm(Q[263,:2]-Q[33,:2])
                x0,x1=int(Q[:468,0].min()-0.15*d),int(Q[:468,0].max()+0.15*d); y0,y1=int(eyes[:,1].min()-0.55*d),int(Q[1,1]+0.1*d)
                band[max(0,y0):max(0,y1),max(0,x0):max(0,x1)]=True
            M=Image.fromarray(np.maximum(np.asarray(M),((acc>0.35)&band)*255).astype(np.uint8))
        except FileNotFoundError: pass
        Mr=M.filter(ImageFilter.MaxFilter(15)).filter(ImageFilter.MaxFilter(15)).filter(ImageFilter.MaxFilter(15)).filter(ImageFilter.MaxFilter(9))  # thin rims are under-segmented; widen
        base=remove(im,Mr)
    except FileNotFoundError: pass
    res=np.asarray(base,np.float32)/255
    faces=json.load(open(f'{S}/{n}.lm.json'))
    try: bg=np.load(f'{S}/{n}.bg.npy').astype(np.float32)
    except FileNotFoundError: bg=np.zeros((H,W),np.float32)
    # Glasses may overhang the person's outline by at most OVERHANG (lens fronts on a profile); anything further is
    # a pose error, so it is clipped. Dilation is done at quarter resolution to keep the filter small.
    person_small=Image.fromarray(((bg<0.5)*255).astype(np.uint8)).resize((W//4,H//4),Image.BILINEAR)
    for f in faces:
        if f.get('scores',[1])[0]<MIN_FACE_SCORE: print('skip face, landmark score',f['scores'][0]); continue
        P=np.array(f['pts']); w=lambda i: np.array([P[i,0],-P[i,1],-P[i,2]])
        ex=nrm(w(263)-w(33)); up=w(10)-w(152); ez=nrm(np.cross(ex,up)); ey=np.cross(ez,ex)
        s=float(np.linalg.norm(w(263)-w(33))/0.093)
        ex,ey,ez,is_profile=profile_corrected_axes(P,ex,ey,ez,s,bg)
        # Scene units: x right, y up, z toward the camera, origin at the photo centre (the renderer's frame).
        sc=np.stack([P[:,0]-W/2,H/2-P[:,1],-P[:,2]],1); iris_sc=(sc[468]+sc[473])/2
        # The lens plane sits EYE_DEPTH in front of the irises along the head's own forward axis (not the camera's),
        # so on a turned head the pair shifts toward the nose. The model's origin is 6 mm below its lens centres.
        origin=iris_sc+s*(EYE_DEPTH*ez-(0.0 if GENERIC else 0.006)*ey)
        c=np.array([origin[0]+W/2,-(H/2-origin[1])])  # (x, -y) in pixels, as the renderer call below expects
        # Face occluder: the face mesh exactly where it is in the photo; depth shifted so the holder sits at z = 0.
        # Pushed back 6 mm along the camera axis: landmark depth is noisy and the nose bridge must stay behind the frame bridge.
        mesh=sc[:468]-np.array([0,0,origin[2]+0.006*s])
        with open(f'{S}/{n}.face.obj','w') as fo:
            fo.write(''.join(f'v {x:.2f} {y:.2f} {z:.2f}\n' for x,y,z in mesh)); fo.write(''.join(f'f {a+1} {b+1} {d+1}\n' for a,b,d in TRIS))
        for mode in ('frame','front','lens'):
            geo=[str(W),str(H),str(c[0]),str(-c[1]),str(s)]+[str(v) for v in (*ex,*ey,*ez)]+[mode,f'{S}/{n}.face.obj']
            if GENERIC: subprocess.run([f'{S}/render_glasses3',MODEL,f'{S}/{n}.r']+geo,check=True,capture_output=True)
            else: subprocess.run([f'{S}/render_glasses2',MODEL,TEX,f'{S}/{n}.r']+geo,check=True,capture_output=True)
        fr=Image.open(f'{S}/{n}.r.frame.png').convert('RGBA').resize((W,H)); ln=Image.open(f'{S}/{n}.r.lens.png').convert('RGBA').resize((W,H))
        lens=(np.asarray(ln,np.float32)[...,0]/255)*(np.asarray(ln,np.float32)[...,3]/255)
        dpx=float(np.linalg.norm(P[263,:2]-P[33,:2]))
        lens_clip_k=max(3,int(OVERHANG*s/4)|1); lens=lens*(1 if not is_profile else np.asarray(person_small.filter(ImageFilter.MaxFilter(min(lens_clip_k,61))).resize((W,H),Image.BILINEAR),np.float32)>127)
        # Contact shadow of frame + lenses on the skin, offset down a little.
        cover=Image.fromarray((np.maximum(np.asarray(fr)[...,3]/255,lens)*255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(max(1.0,dpx*0.035)))
        sh=np.roll(np.asarray(cover,np.float32)/255,(int(dpx*0.05),int(dpx*0.01)),(0,1))*0.28
        res=res*(1-(sh*(bg<0.5))[...,None])
        # Glass: photo seen through the tint, plus a soft sky reflection strongest at the top of each lens.
        ys=np.arange(H)[:,None]; yb=np.nonzero(lens.max(1)>0.5)[0]
        refl=np.zeros((H,1),np.float32)
        if len(yb): t=np.clip((ys-yb.min())/max(1,yb.max()-yb.min()),0,1); refl=(0.16*(1-t)**2+0.03).astype(np.float32)
        glass=res*TINT+refl[...,None]*np.array([0.85,0.9,1.0])
        res=res*(1-lens[...,None])+glass*lens[...,None]
        # Hair in front of the arms: arm pixels (frame minus the front 2 cm) give way to the hair mask.
        fa=np.asarray(fr,np.float32)/255; front=np.asarray(Image.open(f'{S}/{n}.r.front.png').convert('RGBA').resize((W,H)),np.float32)[...,3]/255
        try: hair=np.load(f'{S}/{n}.hair.npy').astype(np.float32)
        except FileNotFoundError: hair=np.zeros((H,W),np.float32)
        hair=np.asarray(Image.fromarray((hair*255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(2)),np.float32)/255
        armpx=np.clip(fa[...,3]-front,0,1); alpha=front+armpx*(1-np.clip((hair-0.3)/0.4,0,1)); alpha=np.minimum(alpha,fa[...,3])
        k=max(3,int(OVERHANG*s/4)|1); near_person=(np.asarray(person_small.filter(ImageFilter.MaxFilter(min(k,61))).resize((W,H),Image.BILINEAR),np.float32)>127).astype(np.float32)
        if is_profile: alpha=alpha*near_person
        res=res*(1-alpha[...,None])+fa[...,:3]*alpha[...,None]
    out=Image.fromarray((np.clip(res,0,1)*255).astype(np.uint8)); out.save(f'{S}/{n}.worn{TAG}.png')
    bx,by,bw,bh=max(faces,key=lambda e:e['box'][2])['box']; cx_,cy_=bx+bw/2,by+bh*0.45; r=bw*0.85
    box=(int(max(0,cx_-r)),int(max(0,cy_-r*0.75)),int(min(W,cx_+r)),int(min(H,cy_+r*0.95)))
    pair=[]
    for img in (im,out):
        cc=img.crop(box); cc.thumbnail((340,340)); pair.append(cc)
    rows.append(pair)
cw=max(c.width for r in rows for c in r); ch=max(c.height for r in rows for c in r); cols=2; nr=(len(rows)+1)//2
sheet=Image.new('RGB',(cols*(2*cw+25)+10,nr*(ch+10)+10),(40,40,40))
for i,(a,b) in enumerate(rows):
    x=10+(i%cols)*(2*cw+25); y=10+(i//cols)*(ch+10); sheet.paste(a,(x,y)); sheet.paste(b,(x+cw+5,y))
sheet.save(OUT); print('ok',OUT)
