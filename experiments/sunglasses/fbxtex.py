# Minimal binary-FBX reader: which texture file feeds which material slot, plus each material's colour values.
# Only Objects (Material, Texture) and Connections are read; geometry comes from the OBJ.
import sys, struct, zlib, json, os
def read_nodes(b, i, end, v64):
    nodes=[]
    while i < end:
        if v64: eo,np_,pl=struct.unpack_from('<QQQ',b,i); i+=24
        else: eo,np_,pl=struct.unpack_from('<III',b,i); i+=12
        nl=b[i]; i+=1
        if eo==0: break
        name=b[i:i+nl].decode('latin1'); i+=nl
        props=[]; j=i
        for _ in range(np_):
            t=chr(b[j]); j+=1
            if t in 'YCIFDL':
                fmt={'Y':'<h','C':'<?','I':'<i','F':'<f','D':'<d','L':'<q'}[t]; props.append(struct.unpack_from(fmt,b,j)[0]); j+=struct.calcsize(fmt)
            elif t in 'SR':
                l=struct.unpack_from('<I',b,j)[0]; j+=4; props.append(b[j:j+l].decode('latin1') if t=='S' else b[j:j+l]); j+=l
            elif t in 'fdlib':
                n,enc,cl=struct.unpack_from('<III',b,j); j+=12; j+=cl; props.append(None)  # arrays not needed
            else: raise ValueError(t)
        i+=pl
        children=read_nodes(b,i,eo,v64) if i<eo else []
        nodes.append((name,props,children)); i=eo
    return nodes
def parse(path):
    b=open(path,'rb').read(); assert b[:20]==b'Kaydara FBX Binary  '
    ver=struct.unpack_from('<I',b,23)[0]; return read_nodes(b,27,len(b),ver>=7500)
def main(path):
    top=parse(path); objs={}; conns=[]
    for name,props,ch in top:
        if name=='Objects':
            for n,p,c in ch:
                if n in ('Material','Texture','Video'):
                    o={'kind':n,'name':p[1].split('\x00')[0]}
                    for cn,cp,cc in c:
                        if cn in ('RelativeFilename','FileName'): o[cn]=cp[0]
                        if cn=='Properties70':
                            for pn,pp,_ in cc:
                                if pp and pp[0] in ('DiffuseColor','Opacity','TransparencyFactor','Shininess','EmissiveColor','SpecularColor','Roughness','Metalness'):
                                    o.setdefault('props',{})[pp[0]]=[x for x in pp[4:]]
                    objs[p[0]]=o
        if name=='Connections':
            for n,p,c in ch: conns.append(p)
    # Embedded textures: Video -> Texture (OO). Video names look like "Image_3.083" -> file Image_3.<ext> in the folder.
    video_of={}
    for p in conns:
        if p[0]=='OO' and p[1] in objs and p[2] in objs and objs[p[1]]['kind']=='Video' and objs[p[2]]['kind']=='Texture':
            video_of[p[2]]=objs[p[1]]['name'].rsplit('.',1)[0] if objs[p[1]]['name'].count('.') else objs[p[1]]['name']
    mats={}
    for p in conns:
        if p[0]=='OP' and p[1] in objs and p[2] in objs and objs[p[1]]['kind']=='Texture' and objs[p[2]]['kind']=='Material':
            t=objs[p[1]]; f=os.path.basename((t.get('RelativeFilename') or t.get('FileName') or '').replace('\\','/'))
            if f in ('','.') and p[1] in video_of: f=video_of[p[1]]
            mats.setdefault(objs[p[2]]['name'],{})[p[3]]=f
    for o in objs.values():
        if o['kind']=='Material': mats.setdefault(o['name'],{})

    return mats
if __name__=='__main__': print(json.dumps(main(sys.argv[1]),indent=1))
