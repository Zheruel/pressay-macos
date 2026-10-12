"""usage: gen_notes.py ENGINE PROVIDER:MODELKEY PROMPT   (claude:haiku55-med | oai:gpt-6-luna@none)
Only clips with >= 60 words. writes out/notes/ENGINE/<model>-<prompt>.json"""
import asyncio, json, os, sys, time
S = os.path.dirname(os.path.abspath(__file__))
engine, spec, pname = sys.argv[1:4]
prov, mkey = spec.split(":")
def vocab_block():
    out = []
    for l in open(f"{S}/vocab.txt"):
        l = l.strip()
        if not l or l.startswith("#"): continue
        if "<=" in l:
            p, h = [x.strip() for x in l.split("<=", 1)]; out.append(f"{p} (often misheard as: {h})")
        else: out.append(l)
    return "\n".join(out)
system = open(f"{S}/notes/{pname}.txt").read().replace("{vocab}", vocab_block())
inputs = {k: v for k, v in json.load(open(f"{S}/inputs/{engine}.json")).items() if len(v["raw"].split()) >= 60}
outp = f"{S}/out/notes/{engine}/{mkey.replace('@','-')}-{pname}.json"
os.makedirs(os.path.dirname(outp), exist_ok=True)
done = json.load(open(outp)) if os.path.exists(outp) else {}
sem = asyncio.Semaphore(4)
if prov == "claude":
    import anthropic
    client = anthropic.AsyncAnthropic(max_retries=6)
    M = {"haiku55-low": dict(model="claude-haiku-5-5", thinking={"type": "disabled"}, output_config={"effort": "low"}),
         "haiku55-med": dict(model="claude-haiku-5-5", thinking={"type": "adaptive"}, output_config={"effort": "medium"})}
else:
    sys.path.insert(0, S)
    from openai import AsyncOpenAI
    import importlib.util
    spec_ = importlib.util.spec_from_file_location("g", f"{S}/gen_oai_token.py"); g = importlib.util.module_from_spec(spec_); spec_.loader.exec_module(g)
    client = AsyncOpenAI(api_key=g.token(), max_retries=4)
async def one(cid, item):
    user = f"<transcript>\n{item['raw'].strip()}\n</transcript>"
    async with sem:
        t = time.time()
        if prov == "claude":
            r = await client.messages.create(max_tokens=6000, system=system, messages=[{"role": "user", "content": user}], **M[mkey])
            text = "".join(b.text for b in r.content if b.type == "text")
        else:
            slug, eff = mkey.split("@")
            kw = dict(model=slug, instructions=system, input=[{"role": "user", "content": user}], store=False, stream=True)
            if eff != "default": kw["reasoning"] = {"effort": eff}
            text = ""
            async for ev in await client.responses.create(**kw):
                if ev.type == "response.output_text.delta": text += ev.delta
                elif ev.type in ("response.failed", "response.incomplete", "error"): raise RuntimeError(str(ev)[:300])
        done[cid] = dict(text=text.strip(), latency=time.time() - t)
async def main():
    todo = [(k, v) for k, v in inputs.items() if k not in done]
    res = await asyncio.gather(*(one(k, v) for k, v in todo), return_exceptions=True)
    errs = [(k, e) for (k, _), e in zip(todo, res) if isinstance(e, Exception)]
    json.dump(done, open(outp, "w"), indent=1)
    lat = sorted(v["latency"] for v in done.values())
    print(f"{engine} {spec} {pname}: n={len(done)} errs={len(errs)} med={lat[len(lat)//2]:.1f}s", *[f"\n ERR {k} {e}" for k, e in errs[:2]])
asyncio.run(main())
