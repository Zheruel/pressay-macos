#!/usr/bin/env python3
import json, os, sys, time
from pathlib import Path
# Both the initial installation and the later nested installation share state.
root = str(next(p for p in Path(sys.argv[0]).absolute().parents if (p / 'config.json').is_file()))
args=sys.argv[1:]
with open(root+'/config.json') as f: config=json.load(f)
def event(kind, **values):
    with open(root+'/events.jsonl', 'a') as f:
        f.write(json.dumps(dict(kind=kind,pid=os.getpid(),args=args,cwd=os.getcwd(),**values))+'\n')
if args == ['--help']:
    print('--safe-mode --tools --disallowedTools --no-session-persistence --output-format --system-prompt --effort --model')
elif args == ['auth', 'status']:
    print(json.dumps(dict(loggedIn=True,authMethod=config.get('auth','claude.ai'),orgId=config.get('org','fixture-org'),email='test@example.invalid',subscriptionType='max')))
elif args == ['auth', 'login']:
    print('signed in')
else:
    event('waiting')
    if config.get('early_exit'): sys.exit(1)
    text=sys.stdin.read()
    event('submitted',text=text)
    time.sleep(config.get('delay',0))
    if config.get('oversized'):
        print('x'*1100000)
    elif config.get('malformed'):
        print('private provider error and fixture-token')
    else:
        print(json.dumps(dict(type='result',subtype='success',is_error=False,stop_reason='end_turn',result='Cleaned dictation.')))
