#!/bin/bash
# Передтести gemma-4-26b Q4_0 перед прогоном гри на v4.1 (підготовлено 04.11, запуск — користувач, з `su - alex`).
# Займає GPU ~1–1,5 год: бойову модель (qwen3.8-27b@iq2_xxs) вивантажено на час тестів і повернено в кінці.
#  1) стеля контексту з mmproj на CPU: 83968 → якщо запасу відеопам'яті < 400 МіБ, лишається 79872
#     (сервер піднято, промпт на весь контекст, потім запит із картинкою; міряється вільна відеопам'ять)
#  2) повтор 13 запитів, на яких gemma 03.11 зациклилась у роздумах: base проти DRY 0.8 (по 2 рази)
#  3) димовий OpenCode: чи доходить до моделі картинка з stand_godot_run (MCP image) — запит у дампі проксі
# Результати: archive/pretest-gemma26-<дата>/ (summary.txt — підсумок). Нічого в стенді не змінює.
set -u
V=/home/alex/v4_stand
MODEL="lmstudio-community/gemma-4-26b-a4b-it-qat"
OUT="$V/archive/pretest-gemma26-$(date +%F)"
DUMPS="$V/archive/gemma26-2026-11-03/req/lmstudio-community_gemma-4-26b-a4b-it-qat"
LMS="$HOME/.lmstudio/bin/lms"; lmsc() { "$LMS" "$@" 8>&-; }
for p in /proc/[0-9]*; do
  a=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
  case "$a" in *"run-""v4.sh"*) echo "== СТОП: іде прогін стенду (PID ${p#/proc/})"; exit 1;; esac
done
[ -e "$OUT" ] && { echo "== СТОП: $OUT уже існує"; exit 1; }
mkdir -p "$OUT"; S="$OUT/summary.txt"
say() { echo "$*" | tee -a "$S"; }
. "$V/lib-graphs.sh"; . "$V/lib-direct.sh"
free_mib() { nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | head -1; }
SHOT=$(ls "$V/stash/gra/qwen3.8-27b-iq4-xs/docs/screenshots/"start.png 2>/dev/null | head -1)

say "== $(date '+%F %T') передтести $MODEL"
lmsc unload --all >/dev/null 2>&1; sleep 3
say "відеопам'ять вільна без моделей: $(free_mib) МіБ"

# --- 1. стеля контексту -------------------------------------------------------------------------------
CTX=""
for ctx in 83968 79872; do
  if ! direct_start "$MODEL" "$ctx" off "$OUT/llama-$ctx.log"; then say "ctx $ctx: сервер не піднявся"; continue; fi
  f0=$(free_mib)
  python3 - "$DIRECT_PORT" "$ctx" "$SHOT" > "$OUT/ctx-$ctx.txt" 2>&1 <<'PY'
import base64, json, sys, time, urllib.request
port, ctx, shot = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
def post(path, obj, t=1800):
    r = urllib.request.Request(f"http://127.0.0.1:{port}{path}", json.dumps(obj).encode(), {"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(r, timeout=t))
n = len(post("/tokenize", {"content": "apple " * 1000})["tokens"])
words = int((ctx - 3000) * 1000 / n)
t = time.time()
r = post("/completion", {"prompt": "apple " * words, "n_predict": 8, "cache_prompt": False})
print(f"повний контекст: {r.get('tokens_evaluated')} токенів за {time.time() - t:.0f} с")
if shot:
    t = time.time()
    img = base64.b64encode(open(shot, "rb").read()).decode()
    r = post("/v1/chat/completions", {"max_tokens": 300, "messages": [{"role": "user", "content": [
        {"type": "text", "text": "Describe this game screenshot in 2 sentences: colours, ground, objects."},
        {"type": "image_url", "image_url": {"url": "data:image/png;base64," + img}}]}]})
    print(f"картинка за {time.time() - t:.0f} с: {r['choices'][0]['message'].get('content', '')[:300]}")
PY
  rc=$?; f1=$(free_mib); ok_srv=0; direct_ok && ok_srv=1
  say "ctx $ctx: вільно після старту $f0 МіБ, після повного контексту й картинки $f1 МіБ, сервер живий=$ok_srv, rc=$rc"
  sed 's/^/    /' "$OUT/ctx-$ctx.txt" | tee -a "$S"
  if [ "$rc" = 0 ] && [ "$ok_srv" = 1 ] && [ "$f1" -ge 400 ]; then CTX=$ctx; break; fi
  direct_stop; sleep 3
done
[ -z "$CTX" ] && { say "== СТОП: жоден контекст не пройшов"; lmsc load "qwen3.8-27b@iq2_xxs" -c 30720 --gpu max --identifier "qwen3.8-27b@iq2_xxs" -y </dev/null >/dev/null 2>&1; exit 1; }
say "== обрано ctx $CTX"

# --- 2. зациклення: base проти DRY ----------------------------------------------------------------------
SAMP=$(python3 "$V/model_rules.py" "$MODEL" sampling 2>/dev/null || echo '{}')
[ -z "$SAMP" ] && SAMP='{}'
DRY=$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); d.update(dry_multiplier=0.8, dry_base=1.75, dry_allowed_length=4); print(json.dumps(d))' "$SAMP")
for v in "base|$SAMP" "dry08|$DRY"; do
  name=${v%%|*}; extra=${v#*|}
  python3 "$V/qa/replay_loops.py" --port "$DIRECT_PORT" --dumps "$DUMPS" --runs 2 --name "$name" --extra "$extra" \
    --out "$OUT/replay.jsonl" > "$OUT/replay-$name.txt" 2>&1
  say "$(tail -1 "$OUT/replay-$name.txt")"
done

# --- 3. димовий OpenCode: картинка з інструмента доходить до моделі? -------------------------------------
P="$OUT/smoke-project"; mkdir -p "$P"
rsync -a --exclude build --exclude .git --exclude .userdata --exclude .stand "$V/stash/gra/qwen3.8-27b-iq4-xs/" "$P/"  # без збірок (гра — 2,2 ГБ)
python3 "$V/proxy.py" "$OUT/proxy.tsv" & proxy_pid=$!; sleep 2
( cd "$P" && V4_WORKDIR="$P" V4_VISION=1 OPENCODE_CONFIG="$V/opencode.json" PATH="$V/bin:$PATH" \
  timeout 900 opencode run --auto --format json -m "lmv4/$MODEL" \
  "Call the tool stand_godot_run with mode=play exactly once. Then, without calling any other tool, describe in 3 sentences what you SEE on the screenshot image you received: colours, ground, horizon, objects. If you did not receive an image, say NO IMAGE." \
  < /dev/null > "$OUT/smoke.jsonl" 2> "$OUT/smoke.stderr" )
kill $proxy_pid 2>/dev/null
img_in_req=$(grep -l 'image_url\|"type": *"image"\|data:image/png' "$OUT"/req/*/*.request.json 2>/dev/null | wc -l)
say "димовий OpenCode: запитів до моделі з картинкою — $img_in_req"
python3 - "$OUT/smoke.jsonl" <<'PY' | tee -a "$S"
import json, sys
txt = []
for l in open(sys.argv[1]):
    try:
        e = json.loads(l)
    except ValueError:
        continue
    p = e.get("part") or {}
    if p.get("type") == "text" and p.get("text"):
        txt.append(p["text"])
print("    відповідь моделі: " + " ".join(txt)[-600:].replace("\n", " "))
PY

direct_stop
set_graphs "$(python3 "$V/model_rules.py" "qwen3.8-27b@iq2_xxs" graphs)" >/dev/null 2>&1
lmsc load "qwen3.8-27b@iq2_xxs" -c 30720 --gpu max --identifier "qwen3.8-27b@iq2_xxs" -y < /dev/null > /dev/null 2>&1
say "== $(date '+%F %T') готово; бойову модель повернено. Підсумок: $S"
