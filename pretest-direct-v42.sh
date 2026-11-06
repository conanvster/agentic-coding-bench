#!/bin/bash
# v4.2 (06.11): чи піднімаються kat і qwen3.6 на llama-server напряму з ctx 131072 (раніше — LM Studio). ~5 хв GPU.
# MODELS="kat-coder-v2.5-dev-apex" — перевірити лише вказані моделі.
# Для кожної: старт, вільна відеопам'ять, підказка ~100 тис. токенів + 200 токенів відповіді (швидкість), зупинка.
# Бойову модель вивантажено на час тесту й повернено. Результат: archive/pretest-direct-v42-<час>/summary.txt
set -u
V=/home/alex/v4_stand
OUT="$V/archive/pretest-direct-v42-$(date +%F-%H%M)"
LMS="$HOME/.lmstudio/bin/lms"; lmsc() { "$LMS" "$@" 8>&-; }
for p in /proc/[0-9]*; do
  a=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
  case "$a" in *"run-""v4.sh"*) echo "== СТОП: іде прогін стенду (PID ${p#/proc/})"; exit 1;; esac
done
mkdir -p "$OUT"; S="$OUT/summary.txt"; say() { echo "$*" | tee -a "$S"; }
. "$V/lib-graphs.sh"; . "$V/lib-direct.sh"
free_mib() { nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | head -1; }
lmsc unload --all >/dev/null 2>&1; sleep 3
say "== $(date '+%F %T') вільно без моделей: $(free_mib) МіБ"
for model in ${MODELS:-kat-coder-v2.5-dev-apex qwen3.6-35b-a3b}; do
  if ! direct_start "$model" 131072 on "$OUT/llama-$model.log"; then say "$model: сервер НЕ піднявся (див. llama-$model.log)"; continue; fi
  f0=$(free_mib)
  python3 - "$DIRECT_PORT" > "$OUT/speed-$model.txt" 2>&1 <<'PY'
import json, sys, time, urllib.request
port = int(sys.argv[1])
def post(path, obj):
    r = urllib.request.Request(f"http://127.0.0.1:{port}{path}", json.dumps(obj).encode(), {"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(r, timeout=1800))
n = len(post("/tokenize", {"content": "apple " * 1000})["tokens"])
t = time.time()
r = post("/completion", {"prompt": "apple " * int(100000 * 1000 / n) + "\nWrite a short poem about the sea.", "n_predict": 200, "cache_prompt": False})
tm = r.get("timings", {})
print(f"підказка {r.get('tokens_evaluated')} ток., {tm.get('prompt_per_second', 0):.0f} ток/с; відповідь {tm.get('predicted_per_second', 0):.1f} ток/с; усього {time.time() - t:.0f} с")
PY
  f1=$(free_mib); ok_srv=0; direct_ok && ok_srv=1
  say "$model: вільно після старту $f0 МіБ, після 100k-підказки $f1 МіБ, сервер живий=$ok_srv; $(cat "$OUT/speed-$model.txt" | tail -1)"
  direct_stop; sleep 3
done
set_graphs "$(python3 "$V/model_rules.py" "qwen3.8-27b@iq2_xxs" graphs)" >/dev/null 2>&1
lmsc load "qwen3.8-27b@iq2_xxs" -c 30720 --gpu max --identifier "qwen3.8-27b@iq2_xxs" -y < /dev/null > /dev/null 2>&1
say "== $(date '+%F %T') готово; бойову модель повернено"
