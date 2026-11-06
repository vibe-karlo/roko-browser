# frames.py <file.frames> <out.png> t1 t2 ...: the grey frames nearest those seconds, side by side, doubled.
import sys, struct, numpy as np
from PIL import Image
f,out=sys.argv[1:3]; ts=[float(x) for x in sys.argv[3:]]
d=open(f,'rb').read(); n=40+100*218; c=len(d)//n
fr=[(struct.unpack('5d',d[i*n:i*n+40])[0],np.frombuffer(d[i*n+40:(i+1)*n],dtype=np.uint8).reshape(218,100)) for i in range(c)]
pick=[min(fr,key=lambda x:abs(x[0]-t))[1] for t in ts]
gap=np.full((218,6),128,dtype=np.uint8)
row=[]
for p in pick: row+= [p,gap]
Image.fromarray(np.hstack(row)).resize(((106*len(ts))*2,436)).save(out)
