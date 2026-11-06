#!/usr/bin/env python3
import base64,json,os,struct,sys
mode,path,runtime=sys.argv[1:]
print(json.dumps(dict(ready=True,frame_samples=512)),flush=True)
pending=[];frame=0
for line in sys.stdin:
 r=json.loads(line);raw=base64.b64decode(r['pcm']);samples=list(struct.unpack('<%df'%(len(raw)//4),raw))
 if mode=='vad':
  pending+=samples;probs=[];first=frame
  while len(pending)>=512:
   probs.append(1.0 if max(abs(x) for x in pending[:512])>.01 else 0.0);pending=pending[512:];frame+=1
  print(json.dumps(dict(result=dict(first_frame=first,frame_samples=512,probabilities=probs))),flush=True)
 else:
  with open(os.path.join(runtime,'calls'),'a') as f:f.write(str(os.getpid())+'\n')
  print(json.dumps(dict(text='speech'+str(round(samples[len(samples)//2],1)),truncated=False)),flush=True)
