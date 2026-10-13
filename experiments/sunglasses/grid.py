# One sheet: rows = models (and colour variants), columns = the six test faces, each cell cropped to the face.
import sys, os, json, numpy as np
from PIL import Image, ImageDraw, ImageFont
S=sys.argv[1]; OUT=sys.argv[2]
T='/Users/sg/Documents/Dev/Projects/lightly/experiments/test-photos'; P='/Users/sg/Documents/Dev/Projects/lightly/experiments/lut3d/photos'
FACES=[(P,'portrait_deep_02'),(P,'portrait_medium_01'),(P,'portrait_medium_02'),(T,'glasses_side_angle_01'),(T,'profile_colour_woman_01'),(T,'profile_bw_woman_01')]
rows=[('Original',None)]
for i,n in enumerate(sorted(os.listdir(S+'/models')),1): rows.append((n,f'.m{i}'))
# LV pairs dropped by the owner (2026-10-13)
NAMES={'Ray-Ban Wayfarer Double Bridge RB4540':'Ray-Ban Wayfarer\nDouble Bridge RB4540','Ray-Ban Wayfarer Liteforce RB4195':'Ray-Ban Wayfarer\nLiteforce RB4195','Ray-Ban Outdoorsman RB3422Q':'Ray-Ban Outdoorsman\nRB3422Q','Z1576E 490559':'LV 490559 Black','Z1576E 490559 White':'LV 490559 White','Z1576E 490560':'LV Link Mask Black',
       'Z1576E 490560 White':'LV Link Mask White','Z1576E 490560 Red':'LV Link Mask Red'}
C=230; LABEL=210
sheet=Image.new('RGB',(LABEL+C*len(FACES),C*len(rows)),(30,30,30)); d=ImageDraw.Draw(sheet)
try: font=ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc',17)
except Exception: font=None
for j,(dr,n) in enumerate(FACES):
    f=max(json.load(open(f'{S}/{n}.lm.json')),key=lambda e:e['box'][2]); bx,by,bw,bh=f['box']
    cx,cy=bx+bw/2,by+bh*0.42; r=bw*0.62; box=(int(cx-r),int(cy-r),int(cx+r),int(cy+r))
    for i,(name,tag) in enumerate(rows):
        src=f'{dr}/{n}.jpg' if tag is None else f'{S}/{n}.worn{tag}.png'
        im=Image.open(src).convert('RGB').crop(box).resize((C-4,C-4),Image.LANCZOS); sheet.paste(im,(LABEL+j*C+2,i*C+2))
for i,(name,tag) in enumerate(rows):
    d.text((10,i*C+C//2-10),NAMES.get(name,name),fill=(235,235,235),font=font)
sheet.save(OUT,quality=88); print(sheet.size)
