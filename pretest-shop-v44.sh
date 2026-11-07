#!/bin/bash
# 07.11 (слово користувача): претест сайту для всіх претендентів перед повним прогоном.
#  1) зір: моделям із mmproj — макет design-landing.jpg напряму в llama-server, відповідь у vision-<модель>.txt
#  2) сайт, етапи 0–1, 15 хв на модель (runs-v4-pre-shop.txt, stages-shop-pre.txt) — чи зрозуміле ТЗ
# Результат: archive/pretest-shop-v44-<час>/. Запуск з `su - alex`, лише коли GPU вільна від прогонів.
V=/home/alex/v4_stand
say() { echo "== $(date '+%F %T') $*"; }
for p in /proc/[0-9]*; do case "$(tr '\0' ' ' < $p/cmdline 2>/dev/null)" in *"run-""v4.sh"*) say "СТОП: іде прогін (PID ${p#/proc/})"; exit 1;; esac; done 2>/dev/null
[ -s "$V/logs/run.out" ] && { say "СТОП: logs/ не порожній"; exit 1; }
# 07.11: перший запуск зірвав Godot-рендер MyWay на тій самій відеокарті — без вільної GPU не стартувати
f=$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null | grep -v -e llama -e lmstudio)
[ -n "$f" ] && { say "СТОП: на відеокарті чужий процес: $(echo $f) — закрий його й запусти знову"; exit 1; }
OUT="$V/archive/pretest-shop-v44-$(date +%F-%H%M)"; mkdir -p "$OUT"
"$HOME/.lmstudio/bin/lms" unload --all >/dev/null 2>&1 8>&-; sleep 3
. "$V/lib-direct.sh"
IMG=/home/alex/v4_test/inputs/shop/design-landing.jpg
while IFS='|' read -r model slug ctx; do
  mm=$(python3 "$V/model_rules.py" "$model" server | python3 -c 'import json,sys; print(json.load(sys.stdin).get("mmproj", ""))')
  [ -n "$mm" ] || { say "$model: без зору — пропуск проби"; continue; }
  say "зір: $model"
  if direct_start "$model" "$ctx" on "$OUT/llama-vision-$slug.log" >/dev/null; then
    python3 - "$DIRECT_PORT" "$IMG" > "$OUT/vision-$slug.txt" 2>&1 <<'PY'
import base64, json, sys, time, urllib.request
port, img = sys.argv[1], sys.argv[2]
b64 = base64.b64encode(open(img, "rb").read()).decode()
q = ("Це макет вебсторінки. Опиши: 1) блоки зверху вниз; 2) скільки великих карток у блоці з іграми і що на них написано; "
     "3) кольори кнопок і рамок карток; 4) що в шапці. Коротко, списком.")
body = {"messages": [{"role": "user", "content": [{"type": "text", "text": q},
        {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + b64}}]}], "max_tokens": 1500, "temperature": 0.2}
t = time.time()
r = json.load(urllib.request.urlopen(urllib.request.Request(f"http://127.0.0.1:{port}/v1/chat/completions",
        json.dumps(body).encode(), {"Content-Type": "application/json"}), timeout=900))
m = r["choices"][0]["message"]
print(f"[{time.time() - t:.0f} с, токенів підказки {r.get('usage', {}).get('prompt_tokens')}]")
print(m.get("content") or "(порожньо)")
PY
    say "  код $? → vision-$slug.txt"
  else
    say "  сервер не піднявся"
  fi
  direct_stop; sleep 3
done < <(grep -v '^#' "$V/runs-v4-pre-shop.txt" | grep .)
say "сайт, етапи 0–1, 15 хв на модель"
TASKS=shop SHOP_BUDGET=900 STAGE_CAP=900 STAGES_FILE="$V/stages-shop-pre.txt" RUNS_FILE="$V/runs-v4-pre-shop.txt" "$V/run-v4.sh" > "$V/logs/run.out" 2>&1
mv "$V/logs" "$OUT/logs" && mkdir -p "$V/logs"
say "готово → $OUT"
