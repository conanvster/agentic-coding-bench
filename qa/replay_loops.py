#!/usr/bin/env python3
"""v4.1 (04.11): повтор запитів, на яких модель зациклилась у роздумах (finish=length з повтором рядків),
з різними налаштуваннями семплера. Порівнює частку циклів. Запускати лише при вільному GPU, сервер моделі — окремо.
  replay_loops.py --port 1251 --dumps <тека req> --runs 2 --name base --extra '{}'
  replay_loops.py ... --name dry --extra '{"dry_multiplier":0.8,"dry_base":1.75,"dry_allowed_length":4}'
"""
import argparse, collections, glob, json, os, random, time, urllib.request

ap = argparse.ArgumentParser()
ap.add_argument("--port", type=int, required=True)
ap.add_argument("--dumps", required=True)
ap.add_argument("--runs", type=int, default=2)
ap.add_argument("--name", default="base")
ap.add_argument("--extra", default="{}")
ap.add_argument("--max-tokens", type=int, default=8192)
ap.add_argument("--out", default="")
a = ap.parse_args()
extra = json.loads(a.extra)

cases = []
for resp in sorted(glob.glob(os.path.join(a.dumps, "*.response.txt"))):
    if '"finish_reason":"length"' in open(resp, errors="ignore").read().replace(" ", ""):
        req = resp.replace(".response.txt", ".request.json")
        if os.path.exists(req):
            cases.append(req)


def looped(text):
    lines = [l.strip() for l in text.splitlines() if len(l.strip()) > 8]
    if not lines:
        return False, ""
    top, n = collections.Counter(lines).most_common(1)[0]
    return n >= 15, f"{n}× «{top[:50]}»"


rows = []
for req_path in cases:
    base = json.load(open(req_path))
    for r in range(a.runs):
        req = dict(base, stream=True, max_tokens=a.max_tokens, seed=random.randrange(1 << 30))
        req.update(extra)
        body = json.dumps(req).encode()
        t0 = time.time()
        rc, ct, tc, fin = [], [], 0, None
        try:
            hr = urllib.request.Request(f"http://127.0.0.1:{a.port}/v1/chat/completions", body,
                                        {"Content-Type": "application/json"})
            with urllib.request.urlopen(hr, timeout=1800) as f:
                for line in f:
                    line = line.decode(errors="ignore").strip()
                    if not line.startswith("data:") or line == "data: [DONE]":
                        continue
                    try:
                        d = json.loads(line[5:])
                    except ValueError:
                        continue
                    for ch in d.get("choices", []):
                        dl = ch.get("delta", {})
                        rc.append(dl.get("reasoning_content") or "")
                        ct.append(dl.get("content") or "")
                        tc += len(dl.get("tool_calls") or [])
                        fin = ch.get("finish_reason") or fin
        except Exception as e:
            fin = f"error {e}"
        reason = "".join(rc)
        lp, what = looped(reason + "".join(ct))
        row = dict(case=os.path.basename(req_path)[:40], run=r + 1, finish=fin, loop=lp, what=what,
                   reasoning=len(reason), tool_calls=tc, sec=round(time.time() - t0))
        rows.append(row)
        print(json.dumps(row, ensure_ascii=False), flush=True)

n = len(rows)
loops = sum(r["loop"] for r in rows)
length = sum(r["finish"] == "length" for r in rows)
tools = sum(r["tool_calls"] > 0 for r in rows)
summary = f"{a.name}: випадків {len(cases)}×{a.runs}={n}; цикл {loops}, обрив length {length}, дійшло до виклику інструмента {tools}"
print(summary)
if a.out:
    with open(a.out, "a") as f:
        f.write(json.dumps({"name": a.name, "extra": extra, "rows": rows, "summary": summary}, ensure_ascii=False) + "\n")
