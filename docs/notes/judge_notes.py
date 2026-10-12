"""Blind notes judge (Haiku). usage: judge_notes.py ENGINE PASS cand1,cand2,...  (stems in out/notes/ENGINE)
prints mean scores; writes judged/notes-ENGINE-PASS.json"""
import asyncio, json, os, random, re, sys, statistics as st
import anthropic
S = os.path.dirname(os.path.abspath(__file__))
engine, pas, names = sys.argv[1], sys.argv[2], sys.argv[3].split(",")
JUDGE = "claude-haiku-5-5"
raw = json.load(open(f"{S}/inputs/{engine}.json"))
C = {n: json.load(open(f"{S}/out/notes/{engine}/{n}.json")) for n in names}
clips = [c for c in C[names[0]] if all(c in C[n] for n in names)]
SYSTEM = """You grade notes made from voice recordings. A person held a key, talked, and an app turned the raw speech-to-text into a note they will read later. You compare several notes made from the same recording.

A great note:
- Faithful: keeps every meaningful idea, decision, question, name, number and reason; adds nothing the speaker did not say; keeps their hedges and tone. Fixes obvious mis-transcriptions sensibly. Dropping or inventing content is the worst failure.
- Readable: clean complete sentences, no fillers or false starts, organized for skimming (paragraphs, lists where the speaker listed things, headings only when topics really differ), not padded or over-structured for short content.
- Well titled: a short title that names what the note is about.
- Actions: when the speaker states things to do, they are easy to find (a list or checklist where several are given), accurate and concise; none invented, none repeated.

Score each note 1-10 on faithful, readable, title, todos, and overall (overall is your holistic judgment of which note the speaker would rather keep; faithfulness weighs most). Use the full scale and distinguish the notes.
Reply with JSON only: {"A": {"faithful": n, "readable": n, "title": n, "todos": n, "overall": n, "issue": "the single biggest weakness, under 15 words"}, "B": {...}, ...}"""
client = anthropic.AsyncAnthropic(max_retries=6)
sem = asyncio.Semaphore(6)
outp = f"{S}/judged/notes-{engine}-{pas}.json"
done = json.load(open(outp)) if os.path.exists(outp) else {}
async def one(cid):
    order = names[:]; random.Random(f"{pas}{cid}").shuffle(order)
    labels = {chr(65 + i): n for i, n in enumerate(order)}
    body = f"<transcript>\n{raw[cid]['raw'].strip()}\n</transcript>\n\n" + "\n\n".join(f"<note id=\"{l}\">\n{C[n][cid]['text']}\n</note>" for l, n in labels.items())
    async with sem:
        r = await client.messages.create(model=JUDGE, max_tokens=3000, system=SYSTEM, thinking={"type": "adaptive"}, output_config={"effort": "medium"},
                                         messages=[{"role": "user", "content": body}])
    txt = "".join(b.text for b in r.content if b.type == "text")
    js = json.loads(re.search(r"\{.*\}", txt, re.S).group(0))
    done[cid] = {labels[l]: v for l, v in js.items() if l in labels}
async def main():
    todo = [c for c in clips if c not in done or set(done[c]) != set(names)]
    res = await asyncio.gather(*(one(c) for c in todo), return_exceptions=True)
    print("errs", sum(isinstance(r, Exception) for r in res))
    os.makedirs(f"{S}/judged", exist_ok=True); json.dump(done, open(outp, "w"), indent=1)
    for n in names:
        sc = [done[c][n] for c in clips if c in done and n in done[c]]
        print(f"{n:40s} n={len(sc)} " + " ".join(f"{k}={st.mean(s[k] for s in sc):.2f}" for k in ["overall", "faithful", "readable", "title", "todos"]))
asyncio.run(main())

import collections
if os.environ.get("ISSUES"):
    for n in names:
        print("##", n)
        for c in clips[:40]:
            if c in done and n in done[c]: print(" -", done[c][n].get("issue",""))
