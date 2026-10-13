# Normalise each purchased sunglasses model into one convention the renderer can rely on:
#   metres; x across (wearer's left = +x), y up, z forward; origin at the centre of the lenses.
#   Every OBJ material group is renamed to a role key listed in model.json: "lens" (front lenses, the compositor
#   tints the photo through them) or "frame" (textured or plain PBR). Parts listed in "drop" are removed.
import sys, os, glob, json, numpy as np
sys.path.insert(0, os.path.dirname(__file__))
from fbxtex import main as fbx_materials
from objinfo import load as load_obj
from PIL import Image
ROOT=os.path.expanduser('~/Downloads/Sunglasses 3D'); OUT=sys.argv[1]
FRONT_WIDTH=0.148  # used only for models not authored in metres
# Worn arms flex outward to rest on the head. Models are authored unworn (arms 68-76 mm from the centre), which
# puts narrow arms inside the head occluders, so the arms are splayed to ARM_X, ramping in over the first SPLAY_LEN
# behind the hinge. Only arm vertices (|x| > 40 mm, behind the front) move.
ARM_X=0.080; SPLAY_START=0.005; SPLAY_LEN=0.025
CONFIG={
 'Kurt Cobain Round': dict(by_object=True, lens_objects=['Lens','Cap_1','Cap_2'],
     plain={'frame':dict(color=[0.93,0.91,0.86],roughness=0.18,metalness=0.0)}),  # glossy cream acetate
 'Tom Ford FT0711': dict(axes='-z,y,x', drop=['Plane'], by_object=False, lens_materials=['Glass'],
     plain={'Plastic':dict(color=[0.02,0.02,0.02],roughness=0.15,metalness=0.0),
            'Golden':dict(color=[1.0,0.77,0.34],roughness=0.25,metalness=1.0),
            'Golden.001':dict(color=[1.0,0.77,0.34],roughness=0.25,metalness=1.0)}),
 'Z1576E 490559': dict(single_mesh_lv='png/Black/PBR/LV SUNGLASSES_Mat_'),
 'Z1576E 490560': dict(single_mesh_lv='png/Black/PBR/LV LINK MASK SUNGLASSES_Mat_'),
}
# Colour variants of the single-mesh LV models: same geometry, other texture sets (normalize.py --variants).
VARIANTS={
 'Z1576E 490559 White': ('Z1576E 490559', dict(single_mesh_lv='png/White/PBR/LV SUNGLASSES_Mat_')),
 'Z1576E 490560 White': ('Z1576E 490560', dict(single_mesh_lv='png/White/PBR/LV LINK MASK SUNGLASSES_Mat_')),
 'Z1576E 490560 Red':   ('Z1576E 490560', dict(single_mesh_lv='png/Red/PBR/LV LINK MASK SUNGLASSES_Mat_')),
}
AXES={'x,y,z':np.eye(3),'-z,y,x':np.array([[0,0,-1],[0,1,0],[1,0,0]],float)}

def find_tex(folder,stem):
    hits=[f for f in glob.glob(folder+'/**/'+stem+'.*',recursive=True) if f.lower().endswith(('.png','.jpg','.jpeg'))]
    return hits[0] if hits else None

def normalise(name, source=None, cfg=None):
    folder=os.path.join(ROOT,source or name); cfg=cfg if cfg is not None else CONFIG.get(name,{})
    obj=[f for f in glob.glob(folder+'/**/*.obj',recursive=True)][0]
    V,groups=load_obj(obj); A=AXES[cfg.get('axes','x,y,z')]; Vn=V@A.T
    drop=set(cfg.get('drop',[]))
    # role per (object, material) group
    fbx=[f for f in glob.glob(folder+'/**/*.fbx',recursive=True)+glob.glob(folder+'/**/*.FBX',recursive=True)]
    fmats=fbx_materials(fbx[0]) if fbx and 'single_mesh_lv' not in cfg and name in ('',) or (fbx and not cfg) else {}
    roles={}; materials={}
    # extent of each material across all its groups (a pair's lenses are often two separate objects)
    by_mat={}
    for (o,m),ix in groups.items():
        if o not in drop: by_mat.setdefault(m,set()).update(ix)
    for (o,m),ix in groups.items():
        if o in drop: continue
        P=Vn[sorted(ix)]
        if cfg.get('by_object'): lens = o in cfg['lens_objects']; key='lens' if lens else 'frame'
        elif 'lens_materials' in cfg: lens = m in cfg['lens_materials']; key='lens' if lens else m
        elif 'single_mesh_lv' in cfg: key='lv'
        else:
            fm=fmats.get(m) or fmats.get((m or '').replace('_',' ',1)) or {}
            Pm=Vn[sorted(by_mat[m])]; ext=Pm.max(0)-Pm.min(0)
            # Lens: transparent material, thin front-to-back, wide, at the front of the frame.
            lens='TransparencyFactor' in fm and ext[2]<0.03 and ext[0]>0.08 and Pm[:,2].max()>Vn[:,2].max()-0.03
            key='lens' if lens else 'frame_'+(m or 'x')
            if not lens and key not in materials:
                materials[key]=dict(role='frame',diffuse=find_tex(folder,fm['DiffuseColor']) if fm.get('DiffuseColor') else None,
                                    normal=find_tex(folder,fm['NormalMap']) if fm.get('NormalMap') else None,roughness=0.25,metalness=0.0,
                                    translucent='TransparencyFactor' in fm)
        roles[(o,m)]=key
    for k in set(roles.values()):
        if k=='lens': materials['lens']=dict(role='lens')
        elif k=='frame' and 'frame' in cfg.get('plain',{}): materials['frame']=dict(role='frame',**cfg['plain']['frame'])
        elif k in cfg.get('plain',{}): materials[k]=dict(role='frame',**cfg['plain'][k])
    if 'single_mesh_lv' in cfg:
        base=os.path.join(folder,cfg['single_mesh_lv'])
        col=Image.open(base+'BaseColor.png').convert('RGB'); op=np.asarray(Image.open(base+'Opacity.png').convert('L'),np.float32)/255
        lensmask=(op<0.9)
        rgba=np.dstack([np.asarray(col),(~lensmask*255).astype(np.uint8)]); os.makedirs(f'{OUT}/{name}',exist_ok=True)
        Image.fromarray(rgba,'RGBA').save(f'{OUT}/{name}/frame_rgba.png')
        Image.fromarray((lensmask*255).astype(np.uint8)).convert('RGB').save(f'{OUT}/{name}/lens_mask.png')
        materials['lv']=dict(role='lv',diffuse=f'{OUT}/{name}/frame_rgba.png',lens_mask=f'{OUT}/{name}/lens_mask.png',
                             normal=base+'Normal.png' if os.path.exists(base+'Normal.png') else None,roughness=0.2,metalness=0.0)
    # scale and origin from the lens parts (or, for single-mesh models, from the whole front)
    lens_ix=sorted(set().union(*[ix for g,ix in groups.items() if roles.get(g)=='lens'])) if any(v=='lens' for v in roles.values()) else None
    keep_ix=sorted(set().union(*[ix for g,ix in groups.items() if g in roles]))
    K=Vn[keep_ix]; width=K[:,0].max()-K[:,0].min()
    scale=1.0 if 0.12<width<0.18 else FRONT_WIDTH/width
    if lens_ix is not None: L=Vn[lens_ix]
    else:  # single mesh: lens centre ~ the front 25 % of the depth
        L=K[K[:,2]>K[:,2].max()-0.25*(K[:,2].max()-K[:,2].min())]
    centre=(L.min(0)+L.max(0))/2
    Kn=(K-centre)*scale; arm=Kn[(Kn[:,2]<-0.04)&(np.abs(Kn[:,0])>0.04)]
    splay=max(0.0,ARM_X-np.abs(arm[:,0]).max()) if len(arm) else 0.0
    def place(p):
        v=(p@A.T-centre)*scale
        if v[2]<-SPLAY_START and abs(v[0])>0.04:
            t=min(1.0,(-v[2]-SPLAY_START)/SPLAY_LEN); v[0]+=np.sign(v[0])*splay*t
        return v
    os.makedirs(f'{OUT}/{name}',exist_ok=True)
    out=open(f'{OUT}/{name}/model.obj','w'); cur=None; mat=None; skip=False
    for l in open(obj,errors='ignore'):
        t=l.split(maxsplit=1)
        if not t: continue
        if t[0]=='mtllib': continue
        if t[0]=='v': v=place(np.array([float(x) for x in l.split()[1:4]])); out.write(f'v {v[0]:.6f} {v[1]:.6f} {v[2]:.6f}\n'); continue
        if t[0]=='vn': n=np.array([float(x) for x in l.split()[1:4]])@A.T; out.write(f'vn {n[0]:.5f} {n[1]:.5f} {n[2]:.5f}\n'); continue
        if t[0] in ('o','g'): cur=t[1].strip() if len(t)>1 else 'unnamed'; out.write(l); 
        if t[0]=='usemtl': mat=t[1].strip()
        if t[0] in ('o','g','usemtl'):
            key=roles.get((cur,mat)); skip=key is None
            if key: out.write(f'usemtl {key}\n')
            continue
        if t[0]=='f' and skip: continue
        out.write(l)
    out.close()
    json.dump(dict(name=name,scale=scale,materials=materials),open(f'{OUT}/{name}/model.json','w'),indent=1)
    print(f'{name:38s} scale {scale:.4f} width {width*scale:.3f} arm splay {splay*1000:.1f}mm roles {sorted(set(roles.values()))}')
if '--variants' in sys.argv:
    for name,(source,cfg) in VARIANTS.items(): normalise(name,source,cfg)
else:
    for d in sorted(os.listdir(ROOT)):
        if os.path.isdir(os.path.join(ROOT,d)): normalise(d)
