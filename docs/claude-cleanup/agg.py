import json,sys,statistics as st,glob
files=sys.argv[1:]; P=[json.load(open(f)) for f in files]
clips=set.intersection(*[set(p) for p in P])
names=sorted({n for p in P for c in p.values() for n in c['scores']})
rows=[]
for n in names:
    O=[];F=[];R=[];chg=0;cnt=0;wins=0;long=[]
    for c in clips:
        vals=[p[c]['scores'][n] for p in P if n in p[c]['scores']]
        if not vals: continue
        o=st.mean(v['overall'] for v in vals); O.append(o); F.append(st.mean(v['fidelity'] for v in vals)); R.append(st.mean(v['readability'] for v in vals))
        chg+=st.mean(v['meaning_changed'] for v in vals); cnt+=1
        best=max(st.mean(p[c]['scores'][m]['overall'] for p in P) for m in P[0][c]['scores'])
        wins+= o>=best-1e-9
    rows.append((st.mean(O),n,st.mean(F),st.mean(R),chg/cnt*100,wins,cnt))
print(f"{'candidate':24}{'overall':>8}{'fidel':>7}{'read':>7}{'chg%':>7}{'best':>6}{'n':>5}")
for o,n,f,r,c,w,k in sorted(rows,reverse=True): print(f"{n:24}{o:8.2f}{f:7.2f}{r:7.2f}{c:7.1f}{w:6}{k:5}")
# judge agreement
a=[];b=[]
for c in clips:
    for n in P[0][c]['scores']:
        if len(P)>1 and n in P[1][c]['scores']: a.append(P[0][c]['scores'][n]['overall']); b.append(P[1][c]['scores'][n]['overall'])
if a: print('pass agreement r=',round(st.correlation(a,b),3))
