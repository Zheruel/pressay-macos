"""Run Claude cleanup over ASR outputs.
usage: gen.py ENGINE MODELKEY PROMPT [ids_file]
writes out/ENGINE/MODELKEY-PROMPT.json  {id: {text, latency, in, out, stop}}
"""
import asyncio, json, os, sys, time
import anthropic

S = os.path.dirname(os.path.abspath(__file__))
engine, mkey, pname = sys.argv[1:4]

MODELS = {
    "haiku55-low": dict(model="claude-haiku-5-5", thinking={"type": "disabled"}, output_config={"effort": "low"}),
    "haiku55-med": dict(model="claude-haiku-5-5", thinking={"type": "adaptive"}, output_config={"effort": "medium"}),
    "haiku55-high": dict(model="claude-haiku-5-5", thinking={"type": "adaptive"}, output_config={"effort": "high"}),
    "haiku55-xhigh": dict(model="claude-haiku-5-5", thinking={"type": "adaptive"}, output_config={"effort": "xhigh"}),
    "sonnet55-low": dict(model="claude-sonnet-5-5", thinking={"type": "between_tools"}, output_config={"effort": "low"}),
    "sonnet55-med": dict(model="claude-sonnet-5-5", thinking={"type": "adaptive"}, output_config={"effort": "medium"}),
}

def vocab_block():
    lines = []
    for l in open(f"{S}/vocab.txt"):
        l = l.strip()
        if not l or l.startswith("#"):
            continue
        if "<=" in l:
            pref, heard = [x.strip() for x in l.split("<=", 1)]
            lines.append(f"{pref} (often misheard as: {heard})")
        else:
            lines.append(l)
    return "\n".join(lines)

system = open(f"{S}/prompts/{pname}.txt").read().replace("{vocab}", vocab_block())
inputs = json.load(open(f"{S}/inputs/{engine}.json"))  # {id: {raw, app}}
if len(sys.argv) > 4:
    keep = set(json.load(open(sys.argv[4])))
    inputs = {k: v for k, v in inputs.items() if k in keep}

outp = f"{S}/out/{engine}/{mkey}-{pname}.json"
os.makedirs(os.path.dirname(outp), exist_ok=True)
done = json.load(open(outp)) if os.path.exists(outp) else {}

client = anthropic.AsyncAnthropic(max_retries=6)
sem = asyncio.Semaphore(int(os.environ.get("CONC", "6")))

async def one(cid, item):
    raw = item["raw"].strip()
    if not raw:
        done[cid] = dict(text="", latency=0, inp=0, out=0, stop="empty")
        return
    user = f"App: {item.get('app') or 'unknown'}\n\n<transcript>\n{raw}\n</transcript>"
    async with sem:
        t = time.time()
        r = await client.messages.create(
            max_tokens=4000, system=system,
            messages=[{"role": "user", "content": user}], **MODELS[mkey])
        lat = time.time() - t
    text = "".join(b.text for b in r.content if b.type == "text").strip()
    done[cid] = dict(text=text, latency=lat, inp=r.usage.input_tokens, out=r.usage.output_tokens, stop=r.stop_reason)

async def main():
    todo = [(k, v) for k, v in inputs.items() if k not in done]
    res = await asyncio.gather(*(one(k, v) for k, v in todo), return_exceptions=True)
    errs = [(k, e) for (k, _), e in zip(todo, res) if isinstance(e, Exception)]
    json.dump(done, open(outp, "w"), indent=1)
    lats = sorted(v["latency"] for v in done.values() if v["latency"])
    print(f"{engine} {mkey}-{pname}: n={len(done)} errs={len(errs)} median={lats[len(lats)//2]:.2f}s p90={lats[int(len(lats)*.9)]:.2f}s",
          *(f"\n  ERR {k}: {e}" for k, e in errs[:3]))

asyncio.run(main())
