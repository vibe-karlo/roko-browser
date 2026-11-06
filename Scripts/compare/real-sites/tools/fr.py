import sys, struct, numpy as np
f=sys.argv[1]; step=float(sys.argv[2]) if len(sys.argv)>2 else 1
d=open(f,'rb').read(); n=40+100*218
c=len(d)//n; last=-99; base=None
for i in range(c):
    r=d[i*n:(i+1)*n]; t,wi,wo,ci,co=struct.unpack('5d',r[:40]); a=np.frombuffer(r[40:],dtype=np.uint8)
    if base is None: base=(wi,ci)
    if t-last>=step:
        last=t
        print(f"{t:7.2f}s mean={a.mean():6.1f} std={a.std():5.1f} in={(wi-base[0]+ci-base[1])/1e6:7.2f}MB")
print("frames",c)
