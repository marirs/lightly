# Per-object bounds and material for an OBJ (to normalise each purchased model: units, axes, lens parts).
import sys, numpy as np
def load(path):
    V=[]; objs={}; cur=None; mat=None
    for l in open(path, errors='ignore'):
        if l.startswith('v '): V.append([float(x) for x in l.split()[1:4]])
        elif l.startswith('o ') or l.startswith('g '): cur=l.split(maxsplit=1)[1].strip() if len(l.split())>1 else 'unnamed'
        elif l.startswith('usemtl'): mat=l.split(maxsplit=1)[1].strip()
        elif l.startswith('f '):
            key=(cur,mat); idx=[int(t.split('/')[0]) for t in l.split()[1:]]
            objs.setdefault(key,set()).update(i-1 if i>0 else len(V)+i for i in idx)
    return np.array(V),objs
if __name__=='__main__':
    V,objs=load(sys.argv[1]); print('all', V.min(0).round(4), V.max(0).round(4), 'n', len(V))
    for (o,m),ix in objs.items():
        P=V[sorted(ix)]; print(f'  {str(o)[:38]:38s} {str(m)[:28]:28s} n{len(ix):6d} min {P.min(0).round(3)} max {P.max(0).round(3)}')
