#!/usr/bin/env python3
# sheet.py <dir> <out> <cellw> ids... : one row per id, top plus scrolls
import sys, glob, os
from PIL import Image, ImageDraw
d, out, w = sys.argv[1], sys.argv[2], int(sys.argv[3])
ids = sys.argv[4:]
rows=[]
for i in ids:
    fs=[f"{d}/{i}.jpg"]+[f"{d}/{i}.s{n}.jpg" for n in range(1,6)]
    rows.append((i,[f for f in fs]))
h=int(w*2.17)
sheet=Image.new("RGB",(6*(w+4),len(rows)*(h+18)),"#222")
dr=ImageDraw.Draw(sheet)
for y,(i,fs) in enumerate(rows):
    Y=y*(h+18)
    dr.text((4,Y+2),i,fill="#fff")
    for x,f in enumerate(fs):
        if os.path.exists(f):
            im=Image.open(f).convert("RGB"); im=im.resize((w,int(im.height*w/im.width)))
            sheet.paste(im,(x*(w+4),Y+16))
sheet.save(out,quality=78)
