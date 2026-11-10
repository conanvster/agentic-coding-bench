#!/bin/bash
# 10.11 (слово користувача): повний тест сайту CyberSphere (етапи 0–9, stages-shop.txt) для 3 претендентів
# (runs-full-shop.txt): qwen3.6 35B-A3B UD-Q4_K_XL, qwen3.8 27B UD-Q3_K_XL (98 304), qwen3.8 27B UD-IQ4_XS (69 632).
# Без ліміту часу (слово користувача): бюджет 7 діб і етап 24 год — лише запобіжник від вічного циклу.
# Правила — model-rules-full/ (= model-rules-tuned + чернетки ngram-mod 16 для Q4 + новий qwen3.8-27b-q3kxl.json).
# Перевірка етапів — звичайна (gate.py v4.5), без змін; сайти перевіряє власник вручну → archive/full-shop-<час>/sites/.
# Сторож читання стенду (tools/read-guard.py) — помічає спроби моделі читати стенд/архів/чужі сайти, сповіщає на телефон.
# Запуск з `su - alex`: ./start-full-shop.sh
V=/home/alex/v4_stand
[ -s "$V/logs/run.out" ] && { echo "== СТОП: logs/ не порожній — спершу заархівуй попередній прогін"; exit 1; }
for p in /proc/[0-9]*; do case "$(tr '\0' ' ' < $p/cmdline 2>/dev/null)" in *"run-""v4.sh"*|*"bench-tune2/"*) echo "== СТОП: іде прогін/замір (PID ${p#/proc/})"; exit 1;; esac; done
while IFS='|' read -r model slug ctx; do
  [ -e "/home/alex/v4_test/shop/$slug" ] || [ -e "$V/stash/shop/$slug" ] && { echo "== СТОП: каталог сайту $slug уже існує"; exit 1; }
  MODEL_RULES="$V/model-rules-full" python3 "$V/model_rules.py" "$model" server >/dev/null 2>&1 || { echo "== СТОП: немає правил для $model"; exit 1; }
done < <(grep -v '^#' "$V/runs-full-shop.txt" | grep .)
f=$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null | grep -v -e llama -e lmstudio)
[ -n "$f" ] && { echo "== СТОП: на відеокарті чужий процес: $(echo $f)"; exit 1; }
avail=$(awk '/MemAvailable/{print int($2/1048576)}' /proc/meminfo); [ "$avail" -lt 18 ] && echo "== УВАГА: оперативки доступно $avail ГБ — закрий браузер (qwen3.6 Q4 потребує ≥ 15 ГБ)"
setsid nohup "$V/tools/read-guard.py" > "$V/archive/read-guard.out" 2>&1 &
guard=$!
nohup bash -c '
V=/home/alex/v4_stand
MODEL_RULES="$V/model-rules-full" TASKS=shop SHOP_BUDGET=604800 STAGE_CAP=86400 RUNS_FILE="$V/runs-full-shop.txt" \
  "$V/run-v4.sh" > "$V/logs/run.out" 2>&1
kill '"$guard"' 2>/dev/null
a="$V/archive/full-shop-$(date +%F-%H%M)"; mkdir -p "$a/sites" && mv "$V/logs" "$a/logs" && mkdir -p "$V/logs"
mv "$V/stash/shop/"full-* "$a/sites/" 2>/dev/null
echo "== $(date "+%F %T") архів: $a"
' > "$V/archive/full-shop-launch.out" 2>&1 &
echo "запущено (PID $!): $(grep -v '^#' "$V/runs-full-shop.txt" | grep . | cut -d'|' -f2 | tr '\n' ' '); журнал — logs/run.out, сповіщення — на телефон; сторож читання — PID $guard"
