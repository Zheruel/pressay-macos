#!/usr/bin/env python3
import base64, json, os, struct, sys, time
model, model_path, runtime = sys.argv[1:]
log = os.path.join(runtime, 'events.jsonl')
def event(kind, **extra):
    with open(log, 'a') as f:
        f.write(json.dumps(dict(kind=kind, pid=os.getpid(), model=model, path=model_path, **extra))+'\n')
def reply(**fields):
    print(json.dumps(fields), flush=True)
event('start')
if model == 'hang-ready': time.sleep(60)
reply(ready=True)
for line in sys.stdin:
    data = base64.b64decode(json.loads(line)['pcm'])
    samples = struct.unpack('<%df' % (len(data)//4), data)
    event('request', count=len(samples), first=samples[0])
    if model == 'hang': time.sleep(60)
    elif model == 'oversized':
        sys.stdout.write('x' * (1048576 + 1)); sys.stdout.flush(); time.sleep(60)
    elif model == 'eof': sys.exit(0)
    elif model == 'incomplete': print('{"text":"incomplete","truncated":false}', end='', flush=True); sys.exit(0)
    elif model == 'bad-json': print('not json', flush=True)
    elif model == 'missing-field': reply(text='missing truncated')
    elif model in ('truncate', 'always-truncate'):
        truncated = model == 'always-truncate' or len(samples) > 16000
        reply(text='DISCARD THIS PARTIAL' if truncated else str(round(samples[0], 1)), truncated=truncated)
    else:
        reply(text=model + ':' + str(len(samples)), truncated=False)
        if model == 'exit': sys.exit(0)
