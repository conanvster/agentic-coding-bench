#!/bin/bash
# Сайт CyberSphere v4.4 для 5 моделей (runs-v4-shop.txt: qwen3.6 Q2, qwen3.6 Q4, qwen3.8, flint, gpt-oss), 6 год на модель,
# етап ≤ 1,5 год (слово користувача 07.11, після претестів 15 і 30 хв). Запуск з `su - alex`. ~30 год.
V=/home/alex/v4_stand
[ -s "$V/logs/run.out" ] && { echo "== СТОП: logs/ не порожній — спершу заархівуй попередній прогін"; exit 1; }
for p in /proc/[0-9]*; do case "$(tr '\0' ' ' < $p/cmdline 2>/dev/null)" in *"run-""v4.sh"*|*"chain-""night"*) echo "== СТОП: ще йде прогін/ланцюжок (PID ${p#/proc/})"; exit 1;; esac; done
ONLY=""
while IFS='|' read -r model slug ctx; do
  [ -e "/home/alex/v4_test/shop/$slug" ] || [ -e "$V/stash/shop/$slug" ] && { echo "== СТОП: каталог сайту $slug уже існує"; exit 1; }
  if python3 "$V/model_rules.py" "$model" server 2>/dev/null | grep -q '"AUTO"'; then echo "== $model: претест не пройдено — без неї"; else ONLY="$ONLY $slug"; fi
done < <(grep -v '^#' "$V/runs-v4-shop.txt" | grep .)
f=$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null | grep -v -e llama -e lmstudio)
[ -n "$f" ] && { echo "== СТОП: на відеокарті чужий процес: $(echo $f)"; exit 1; }
echo "== моделі:$ONLY"
export TASKS=shop SHOP_BUDGET=21600 STAGE_CAP=5400 MODELS_ONLY="$ONLY" RUNS_FILE="$V/runs-v4-shop.txt"
nohup "$V/run-v4.sh" > "$V/logs/run.out" 2>&1 &
echo "запущено, PID $!"
