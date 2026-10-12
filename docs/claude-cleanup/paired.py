import json,sys,random,statistics as st
P=[json.load(open(f)) for f in sys.argv[3:]]; a,b=sys.argv[1],sys.argv[2]
cl=[c for c in P[0] if all(a in p[c]['scores'] and b in p[c]['scores'] for p in P)]
d=[st.mean(p[c]['scores'][a]['overall']-p[c]['scores'][b]['overall'] for p in P) for c in cl]
bs=sorted(st.mean(random.choices(d,k=len(d))) for _ in range(5000))
print(f"{a} - {b}: {st.mean(d):+.3f}  95%CI [{bs[125]:+.3f},{bs[4875]:+.3f}]  a>b {sum(x>0 for x in d)} a<b {sum(x<0 for x in d)} tie {sum(x==0 for x in d)}")
