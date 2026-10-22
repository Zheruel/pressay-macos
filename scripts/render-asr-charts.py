#!/usr/bin/env python3
"""Rebuild public ASR figures from sanitized aggregate data, never private audio."""
import html,json,pathlib
ROOT=pathlib.Path(__file__).resolve().parents[1]
DATA=json.loads((ROOT/'docs/benchmarks/local-asr-2026-10-22.json').read_text())
M={r['model']:r for r in DATA['models']}
ORDER=['moss','orukeet','parakeet-ultra','qwen3-1.7b','mega']
NAMES={'moss':'MOSS','orukeet':'Orukeet','parakeet-ultra':'Parakeet Ultra','qwen3-1.7b':'Qwen3-ASR 1.7B','mega':'Mega-ASR'}
COLORS={'moss':'#32917d','orukeet':'#8060c4','parakeet-ultra':'#5c8096','qwen3-1.7b':'#898a98','mega':'#a198ae'}
def text(x,y,s,size=18,fill='#26242b',weight=400,anchor='start'):
 return f'<text x="{x}" y="{y}" font-size="{size}" fill="{fill}" font-weight="{weight}" text-anchor="{anchor}">{html.escape(str(s))}</text>'
def figure(name,title,subtitle,body,height=600):
 svg=f'''<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="{height}" viewBox="0 0 1200 {height}" role="img" aria-labelledby="title desc"><title id="title">{html.escape(title)}</title><desc id="desc">{html.escape(subtitle)}</desc><style>text{{font-family:system-ui,-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif;font-variant-numeric:tabular-nums}}</style><rect width="1200" height="{height}" rx="24" fill="#f9f7f3"/>{text(40,56,title,30,weight=650)}{text(40,90,subtitle,16,'#6d6875')}{body}</svg>'''
 (ROOT/'docs/assets'/name).write_text(svg)
body=''
for panel,(key,label) in enumerate([('ami-extra','Meeting cohort A · 80 segments'),('ami-old','Meeting cohort B · 336 segments')]):
 x=40+panel*585;body+=text(x,145,label,20,weight=600)
 for i,name in enumerate(ORDER):
  y=190+i*62;v=M[name]['groups'][key]['wer'];body+=text(x,y,NAMES[name],17)
  body+=f'<rect x="{x+172}" y="{y-17}" width="{v/40*300:.2f}" height="22" rx="6" fill="{COLORS[name]}"/>'
  body+=text(x+495,y,f'{v:.2f}%',17,weight=600,anchor='end')
body+=text(40,540,'Lower word error rate is better. Two meetings per cohort; close gaps remain uncertain.',15,'#6d6875')
body+=text(40,568,'Apple M5 Pro · tested quantizations/runtimes · no cleanup · scores do not measure speaker attribution.',14,'#6d6875')
figure('speech-models.svg','Meeting accuracy: MOSS leads both cohorts','Human-reference word error rate · fixed model configurations · October 22, 2026',body)
figure('asr-model-comparison.svg','Compare local transcription models','Human-reference meeting scores · lower is better',body)
body=''
for i,name in enumerate(['orukeet','parakeet-ultra','qwen3-1.7b','moss','mega']):
 y=160+i*64;v=M[name]['personal_median'];body+=text(40,y,NAMES[name],18)
 body+=f'<rect x="240" y="{y-19}" width="{v/0.9*750:.2f}" height="26" rx="7" fill="{COLORS[name]}"/>'
 body+=text(1100,y,f'{v:.2f} s',18,weight=600,anchor='end')
body+=text(40,520,'Approximate resident-model ASR cost across 60 recordings; excludes cleanup and model loading.',16,'#6d6875')
body+=text(40,550,'Timing methods differ across runtimes. These are not predicted key-release-to-insert delays.',15,'#6d6875')
figure('asr-latency.svg','Orukeet leaves more time for cleanup','Median ASR processing cost on Apple M5 Pro · lower is faster',body)
body=text(40,150,'EVERYDAY DICTATION',14,'#6d6875',650)+text(630,150,'MEETING ACCURACY',14,'#6d6875',650)
for column,order in enumerate([['orukeet','moss','parakeet-ultra','qwen3-1.7b','mega'],ORDER]):
 x=40+590*column
 for i,name in enumerate(order):
  y=200+i*57;body+=text(x,y,f'{i+1}.',19,'#6d6875')+text(x+40,y,NAMES[name],23,weight=650 if i==0 else 400)
  if i==0:body+=text(x+300,y,'Recommended',15,COLORS[name],600)
body+=text(40,535,'Task-specific recommendation order—not a universal accuracy ranking.',16,'#6d6875')
body+=text(40,565,'Private transcript reviews found no verified dictation winner. Meeting recommendations use human references.',14,'#6d6875')
figure('asr-selection.svg','One recommended model for each job','Five local choices · only the active model stays resident',body)
print('Rebuilt 4 ASR figures from sanitized aggregates.')
