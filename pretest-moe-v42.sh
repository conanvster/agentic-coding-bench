#!/bin/bash
# 06.11: претест нових MoE-моделей, що не влазять у 16 ГБ цілком (qwen3.6 UD-Q4_K_XL, flint UD-Q4_K_XL).
# Шукає найменше N для -ncmoe (експерти перших N шарів — в оперативці), за якого при ctx 131072 сервер живий
# після підказки ~100 тис. токенів і лишається ≥ 500 МіБ відеопам'яті. Менше N — швидше.
# Обране N (+1 шар запасу) записує в model-rules (замість "AUTO"). Модель, що не вмістилась, лишається з AUTO —
# ланцюжок її пропускає. Результат: archive/pretest-moe-v42-<час>/summary.txt. Бойову модель НЕ повертає (далі ланцюжок).
set -u
V=/home/alex/v4_stand
OUT="$V/archive/pretest-moe-v42-$(date +%F-%H%M)"
LMS="$HOME/.lmstudio/bin/lms"; lmsc() { "$LMS" "$@" 8>&-; }
for p in /proc/[0-9]*; do
  a=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
  case "$a" in *"run-""v4.sh"*) echo "== СТОП: іде прогін стенду (PID ${p#/proc/})"; exit 1;; esac
done
mkdir -p "$OUT"; S="$OUT/summary.txt"; say() { echo "$*" | tee -a "$S"; }
. "$V/lib-direct.sh"
free_mib() { nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | head -1; }
rules_file() { grep -l "\"model\": \"$1\"" "$V"/model-rules/*.json | head -1; }
set_n() {  # файл N — замінити значення після -ncmoe
  python3 - "$1" "$2" <<'PY'
import json, sys
p, n = sys.argv[1], sys.argv[2]
d = json.load(open(p, encoding="utf-8")); a = d["server"]["args"]; a[a.index("-ncmoe") + 1] = n
json.dump(d, open(p, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY
}
try_n() {  # модель N → 0 якщо вміщається; друкує рядок результату
  local model="$1" n="$2" f="$(rules_file "$1")" f0 f1 alive
  set_n "$f" "$n"
  if ! direct_start "$model" 131072 on "$OUT/llama-$model-n$n.log" >/dev/null; then echo "N=$n: не піднявся"; return 1; fi
  f0=$(free_mib)
  python3 - "$DIRECT_PORT" > "$OUT/speed-$model-n$n.txt" 2>&1 <<'PY'
import json, sys, time, urllib.request
port = int(sys.argv[1])
def post(path, obj):
    r = urllib.request.Request(f"http://127.0.0.1:{port}{path}", json.dumps(obj).encode(), {"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(r, timeout=3600))
n = len(post("/tokenize", {"content": "apple " * 1000})["tokens"])
t = time.time()
r = post("/completion", {"prompt": "apple " * int(100000 * 1000 / n) + "\nWrite a short poem about the sea.", "n_predict": 200, "cache_prompt": False})
tm = r.get("timings", {})
print(f"підказка {r.get('tokens_evaluated')} ток., {tm.get('prompt_per_second', 0):.0f} ток/с; відповідь {tm.get('predicted_per_second', 0):.1f} ток/с; усього {time.time() - t:.0f} с")
PY
  f1=$(free_mib); alive=0; direct_ok && alive=1
  echo "N=$n: вільно після старту $f0 МіБ, після 100k $f1 МіБ, живий=$alive; $(tail -1 "$OUT/speed-$model-n$n.txt")"
  direct_stop; sleep 3
  [ "$alive" = 1 ] && [ "${f1:-0}" -ge 500 ] && grep -q "ток/с; усього" "$OUT/speed-$model-n$n.txt"
}
lmsc unload --all >/dev/null 2>&1; sleep 3
say "== $(date '+%F %T') вільно без моделей: $(free_mib) МіБ; оперативки доступно $(free -m | awk '/^Mem/{print $7}') МіБ"
for model in ${MODELS:-qwen3.6-35b-a3b@ud-q4_k_xl flint@ud-q4_k_xl}; do
  f="$(rules_file "$model")"; [ -n "$f" ] || { say "$model: немає файлу правил"; continue; }
  gguf="$HOME/.lmstudio/models/$(python3 "$V/model_rules.py" "$model" server | python3 -c 'import json,sys; print(json.load(sys.stdin)["gguf"])')"
  [ -f "$gguf" ] || { say "$model: файл моделі ще не завантажено ($gguf)"; continue; }
  # верхня межа: усі шари в оперативці; заразом із журналу — кількість шарів
  r=$(try_n "$model" 999); rc=$?; say "$model $r"
  if [ "$rc" -ne 0 ]; then set_n "$f" AUTO; say "$model: НЕ ВМІЩАЄТЬСЯ навіть з усіма експертами в оперативці — пропуск"; continue; fi
  L=$(grep -oE "n_layer += [0-9]+" "$OUT/llama-$model-n999.log" | head -1 | grep -oE "[0-9]+$"); L=${L:-48}
  lo=0; hi=$L   # hi — вміщається (≈ 999), lo — ще не перевірено
  while [ $((hi - lo)) -gt 2 ]; do
    mid=$(( (lo + hi) / 2 ))
    r=$(try_n "$model" "$mid"); rc=$?; say "$model $r"
    if [ "$rc" -eq 0 ]; then hi=$mid; else lo=$mid; fi
  done
  n=$(( hi + 1 > L ? L : hi + 1 ))
  set_n "$f" "$n"
  say "$model: ОБРАНО -ncmoe $n із $L шарів (найменше, що вмістилось, + 1 запасу) → $(basename "$f")"
done
say "== $(date '+%F %T') готово"
