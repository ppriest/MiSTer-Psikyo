import zlib,struct,sys
from collections import Counter
def load(fn):
    d=open(fn,'rb').read(); pos=8; idat=b''
    while pos<len(d):
        ln=struct.unpack('>I',d[pos:pos+4])[0]; typ=d[pos+4:pos+8]
        if typ==b'IHDR': W,H,bd,ct=struct.unpack('>IIBB',d[pos+8:pos+18])
        elif typ==b'IDAT': idat+=d[pos+8:pos+8+ln]
        pos+=12+ln
    raw=zlib.decompress(idat); bpp=3; stride=W*bpp
    out=bytearray(); prev=bytearray(stride)
    o=0
    for y in range(H):
        f=raw[o]; o+=1; line=bytearray(raw[o:o+stride]); o+=stride
        for i in range(stride):
            a=line[i-bpp] if i>=bpp else 0; b=prev[i]; c=prev[i-bpp] if i>=bpp else 0
            if f==1: line[i]=(line[i]+a)&255
            elif f==2: line[i]=(line[i]+b)&255
            elif f==3: line[i]=(line[i]+((a+b)>>1))&255
            elif f==4:
                p=a+b-c; pa=abs(p-a); pb=abs(p-b); pc=abs(p-c)
                pr=a if (pa<=pb and pa<=pc) else (b if pb<=pc else c)
                line[i]=(line[i]+pr)&255
        out+=line; prev=line
    return W,H,bytes(out)
W,H,px=load(sys.argv[1])
c=Counter((px[i],px[i+1],px[i+2]) for i in range(0,len(px),3))
print("%s : %dx%d, distinct colours=%d"%(sys.argv[1],W,H,len(c)))
tot=W*H
for col,n in c.most_common(10):
    print("   #%02X%02X%02X  %6d px (%5.2f%%)"%(col[0],col[1],col[2],n,100.0*n/tot))
bg=c.most_common(1)[0]
print("non-background: %d px (%.2f%%)"%(tot-bg[1],100.0*(tot-bg[1])/tot))
# rough row profile of non-bg
rows=[]
for y in range(H):
    n=sum(1 for x in range(W) if (px[(y*W+x)*3],px[(y*W+x)*3+1],px[(y*W+x)*3+2])!=bg[0])
    if n: rows.append((y,n))
print("rows with non-bg content: %d"%len(rows))
for y,n in rows[:24]: print("     row %3d : %4d px"%(y,n))
