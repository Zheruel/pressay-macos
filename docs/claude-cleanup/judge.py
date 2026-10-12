"""Blind judge. usage: judge.py ENGINE PASS SPEC
SPEC: comma list of candidate names; each is a file stem in out/ENGINE (e.g. haiku55-low-light),
      or 'rules' / 'apple' (from out/ENGINE/local.json) or 'wispr' (wispr_formatted, w_ clips only).
writes judged/ENGINE-PASS.json {clip: {key: {label: name}, scores: {name: {...}}}}
"""
import asyncio, json, os, random, sys
import anthropic

S = os.path.dirname(os.path.abspath(__file__))
engine, pas, spec = sys.argv[1], sys.argv[2], sys.argv[3].split(",")
JUDGE = os.environ.get("JUDGE", "claude-opus-5-5")
meta = json.load(open(f"{S}/meta.json"))
refs = {e: json.load(open(f"{S}/inputs/{e}.json")) for e in
        ["qwen3ASR17", "qwen3ASR06", "funASRMLTNano", "whisperTurboGGML"] if os.path.exists(f"{S}/inputs/{e}.json")}
if engine not in refs:
    refs[engine] = json.load(open(f"{S}/inputs/{engine}.json"))
local = json.load(open(f"{S}/out/{engine}/local.json")) if os.path.exists(f"{S}/out/{engine}/local.json") else {}

def cand_text(name, cid):
    if ":" in name:
        e, n = name.split(":", 1)
        if n == "rules": return json.load(open(f"{S}/out/{e}/local.json"))["rules+structure"].get(cid)
        d = json.load(open(f"{S}/out/{e}/{n}.json")); return d[cid]["text"] if cid in d else None
    if name == "rules": return local["rules+structure"].get(cid)
    if name == "apple": return local["apple-light"].get(cid, local["rules"].get(cid))
    if name == "wispr": return meta.get(cid, {}).get("wispr_formatted") if cid.startswith("w_") else None
    d = json.load(open(f"{S}/out/{engine}/{name}.json"))
    return d[cid]["text"] if cid in d else None

CANDS = {n: {} for n in spec}
for n in spec:
    for cid in refs[engine]:
        t = cand_text(n, cid)
        if t is not None: CANDS[n][cid] = t

SYSTEM = """You are grading cleanup of dictated text. A software developer holds a key, speaks, and the app inserts text into the focused app (often a prompt for an AI coding agent, sometimes a message to a teammate). Raw speech recognition is followed by a cleanup step. You compare several cleanup outputs for the same dictation.

What the developer wants from cleanup: text that says exactly what they meant, with misheard words and technical terms fixed, fillers and false starts removed, correct punctuation, and easy to read - concise and well structured where that helps - ready to send without editing.

You cannot hear the audio. Several independent speech-recognition transcripts of the same audio are given as references; infer what was actually said from where they agree, from context, and from the speaker's vocabulary. A cleanup that fixes a misheard term to what was plausibly said is good; one that "fixes" a word into a different term the speaker did not say is bad.

Score every candidate on three 0-10 scales:
- fidelity: says what the speaker meant. Every instruction, constraint, question, number, name, negation and hedge is kept; nothing invented; misheard words corrected rather than kept or replaced by wrong guesses. Dropping or changing any instruction or meaning is a serious error (fidelity 5 or lower). Rewording that keeps meaning is not a fidelity error.
- readability: how clean, clear and easy to act on the text is. Fillers, rambling, repetition and broken sentences cost points; good punctuation, tight wording and sensible structure earn them.
- overall: how happy the developer would be to have this inserted as-is. Fidelity problems dominate; among faithful candidates, the more readable one wins.
Also set meaning_changed (true if any instruction or meaning was lost, altered or invented) and give a short note naming concrete errors. Be consistent across candidates: identical texts get identical scores."""

def schema(labels):
    item = {"type": "object", "properties": {
        "fidelity": {"type": "number"}, "readability": {"type": "number"}, "overall": {"type": "number"},
        "meaning_changed": {"type": "boolean"}, "note": {"type": "string"}},
        "required": ["fidelity", "readability", "overall", "meaning_changed", "note"], "additionalProperties": False}
    return {"type": "object", "properties": {l: item for l in labels}, "required": labels, "additionalProperties": False}

client = anthropic.AsyncAnthropic(max_retries=6)
sem = asyncio.Semaphore(int(os.environ.get("CONC", "6")))
outp = f"{S}/judged/{engine}-{pas}.json"
os.makedirs(f"{S}/judged", exist_ok=True)
done = json.load(open(outp)) if os.path.exists(outp) else {}
vocab = ", ".join(l.split("<=")[0].strip() for l in open(f"{S}/vocab.txt") if l.strip() and not l.startswith("#"))

async def one(cid):
    names = [n for n in spec if cid in CANDS[n]]
    rng = random.Random(f"{cid}-{pas}")
    rng.shuffle(names)
    labels = [chr(65 + i) for i in range(len(names))]
    key = dict(zip(labels, names))
    parts = [f"Dictated into: {meta.get(cid, {}).get('app') or 'unknown'}", f"Speaker vocabulary: {vocab}", "", "Reference speech-recognition transcripts (not candidates):"]
    rr = [refs[e][cid]["raw"] for e in refs if cid in refs[e]]
    if meta.get(cid, {}).get("wispr_asr"): rr.append(meta[cid]["wispr_asr"])
    rng.shuffle(rr)
    parts += [f"[ref {i+1}] {t}" for i, t in enumerate(rr)]
    parts += ["", "Candidates:"] + [f"<candidate {l}>\n{CANDS[key[l]][cid]}\n</candidate {l}>" for l in labels]
    async with sem:
        async with client.messages.stream(
            model=JUDGE, max_tokens=32000, system=SYSTEM,
            messages=[{"role": "user", "content": "\n".join(parts)}],
            output_config={"effort": "high", "format": {"type": "json_schema", "schema": schema(labels)}},
        ) as st:
            r = await st.get_final_message()
    text = next(b.text for b in r.content if b.type == "text")
    sc = json.loads(text)
    done[cid] = {"key": key, "scores": {key[l]: sc[l] for l in labels},
                 "usage": [r.usage.input_tokens, r.usage.output_tokens]}

async def main():
    ids = [c for c in refs[engine] if refs[engine][c]["raw"].strip() and c not in done]
    if os.environ.get("IDS"): ids = [c for c in ids if c in set(json.load(open(os.environ["IDS"])))]
    res = await asyncio.gather(*(one(c) for c in ids), return_exceptions=True)
    errs = [(c, e) for c, e in zip(ids, res) if isinstance(e, Exception)]
    json.dump(done, open(outp, "w"), indent=1)
    u = [v["usage"] for v in done.values()]
    print(f"judged {engine}-{pas}: n={len(done)} errs={len(errs)} in={sum(a for a,_ in u)} out={sum(b for _,b in u)}", *(f"\n ERR {c}: {e}" for c, e in errs[:3]))

asyncio.run(main())
