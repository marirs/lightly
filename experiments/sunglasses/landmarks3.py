# Face landmarks (MediaPipe face_landmarks_detector, 478 points with irises) for each face found by Apple's detector.
# Pass 1 crops around Apple's face box, upright along Apple's eye line. Passes 2-3 re-crop around the previous
# landmarks, upright along the forehead-chin line (as MediaPipe's own tracker does): on profiles Apple's eye line is
# unreliable and a tilted crop gives a wrong mesh.
import sys, json, math, numpy as np
from PIL import Image
from ai_edge_litert.interpreter import Interpreter
S, D = sys.argv[1], sys.argv[2]
it=Interpreter(f'{S}/fl/face_landmarks_detector.tflite'); it.allocate_tensors()
inp=it.get_input_details()[0]; outs=it.get_output_details()
def run(im, centre, size, roll):
    ca,sa=math.cos(roll),math.sin(roll); k=size/256
    A=(k*ca,-k*sa,centre[0]-k*(ca*128-sa*128), k*sa,k*ca,centre[1]-k*(sa*128+ca*128))
    crop=im.transform((256,256),Image.AFFINE,A,Image.BILINEAR)
    it.set_tensor(inp['index'],np.asarray(crop,np.float32)[None]/255.0); it.invoke()
    p=it.get_tensor(outs[0]['index']).reshape(-1,3); u,v,z=p[:,0],p[:,1],p[:,2]
    pts=np.stack([A[0]*u+A[1]*v+A[2], A[3]*u+A[4]*v+A[5], z*k],1)
    return pts, float(it.get_tensor(outs[1]['index']).ravel()[0])
for n in sys.argv[3:]:
    im=Image.open(f'{D}/{n}.jpg').convert('RGB'); res=[]
    for f in json.load(open(f'{S}/{n}.pose.json')):
        L,R=np.array(f['left']),np.array(f['right']); roll=math.atan2(R[1]-L[1],R[0]-L[0])
        bx,by,bw,bh=f['box']
        # Apple's eye line can be far off on profiles and tilted heads: try it and rotations around it, keep the best.
        tries=[run(im,np.array([bx+bw/2,by+bh/2]),max(bw,bh)*1.6,roll+math.radians(d)) for d in (0,-45,-30,-15,15,30,45)]
        pts,score=max(tries,key=lambda t:t[1])
        for _ in range(2):
            v=pts[152,:2]-pts[10,:2]; roll2=math.atan2(-v[0],v[1])   # forehead->chin pointing straight down
            lo,hi=pts[:468,:2].min(0),pts[:468,:2].max(0)
            pts2,score2=run(im,(lo+hi)/2,max(hi-lo)*1.5,roll2)
            if score2<score-1: break   # keep the better crop
            pts,score=pts2,score2
        res.append({'pts':pts.round(2).tolist(),'box':f['box'],'scores':[score]})
    json.dump(res,open(f'{S}/{n}.lm.json','w')); print(n,[round(r['scores'][0],1) for r in res])
