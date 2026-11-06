#!/bin/bash
# Ніч 06→07.11 (слово користувача: «3 дні», ліміт 6 год на модель і задачу, сайт без kat, qwen3.6 Q2 обрізати на 6 год).
# Запуск — start-night-06-11.sh (у фоні). Кроки:
#   0. qwen3.6 Q2 (гра, старт 15:54) — чекати до 21:54 або «all done»; потім зупинити, логи → archive/qwen36-q2-*
#   1. зір gemma-4-26b Q4_0 — блок G стенду помічника (~5–10 хв), результат docs/bench-lmstudio-community_gemma-…-vision.json
#   2. претест нових MoE (pretest-moe-v42.sh): -ncmoe для qwen3.6 UD-Q4_K_XL і flint
#   3. димовий сайту: gpt-oss, SHOP_BUDGET 2400 → archive/smoke-shop-v42-*  (перевіряю вранці я)
#   4. гра для нових моделей, GRA_BUDGET 21600 (6 год) → archive/new-gra-*
# Сайт для всіх моделей — окремою командою після перевірки димового (start-shop-v42.sh).
V=/home/alex/v4_stand
say() { echo "== $(date '+%F %T') $*"; }
archive_logs() {
  local a="$V/archive/$1-$(date +%F-%H%M)"
  mkdir -p "$a" && mv "$V/logs" "$a/logs" && mkdir -p "$V/logs" && say "логи → $a"
}
find_pids() {  # шаблон → PID-и (за рядком команди з /proc, не pgrep -f)
  local p c
  for p in /proc/[0-9]*; do c=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null); case "$c" in *"$1"*) echo "${p#/proc/}";; esac; done
}
run_active() { [ -n "$(find_pids "run-""v4.sh")" ]; }

# 0. qwen3.6 Q2
DEADLINE=$(date -d '2026-11-06 21:54' +%s)
say "крок 0: чекаю кінця qwen3.6 Q2 (не пізніше 21:54)"
while run_active && [ "$(date +%s)" -lt "$DEADLINE" ]; do sleep 30; done
if run_active; then
  say "ліміт 6 год — зупиняю qwen3.6 Q2"
  for p in $(find_pids "start-""qwen36.sh"); do kill "$p" 2>/dev/null; done
  for p in $(find_pids "run-""v4.sh"); do kill "$p" 2>/dev/null; done
  for p in $(find_pids "opencode run"); do kill "$p" 2>/dev/null; done
  for _ in $(seq 60); do run_active || break; sleep 2; done
  for p in $(find_pids "llama-""server"); do kill "$p" 2>/dev/null; done
  sleep 5
fi
W=/home/alex/v4_test/game/qwen3.6-35b-a3b
if [ -d "$W" ]; then
  (cd "$W" && git log --oneline; echo; git status -s) > "$V/logs/git-status-at-stop.txt" 2>&1
  mv "$W" "$V/stash/gra/" && say "гра qwen3.6 Q2 → stash/gra/qwen3.6-35b-a3b"
fi
archive_logs qwen36-q2

# 1. зір gemma Q4_0
say "крок 1: зір gemma-4-26b Q4_0"
"$HOME/.lmstudio/bin/lms" unload --all >/dev/null 2>&1 8>&-
(cd /home/alex/voice-assistant-panel && timeout 3600 tools/run-all.sh vision "lmstudio-community/gemma-4-26b-a4b-it-qat") > "$V/archive/vision-gemma26-q4_0-$(date +%F-%H%M).out" 2>&1
say "зір: код $?"
"$HOME/.lmstudio/bin/lms" unload --all >/dev/null 2>&1 8>&-

# 2. претест нових
say "крок 2: претест нових MoE"
timeout 7200 "$V/pretest-moe-v42.sh"
NEW=""
for m in "qwen3.6-35b-a3b@ud-q4_k_xl|qwen3.6-35b-a3b-q4kxl" "flint@ud-q4_k_xl|flint-q4kxl"; do
  if python3 "$V/model_rules.py" "${m%%|*}" server | grep -q '"AUTO"'; then say "${m%%|*}: не вмістилась/не завантажена — без неї"; else NEW="$NEW ${m#*|}"; fi
done

# 3. димовий сайту
say "крок 3: димовий сайту (gpt-oss, 40 хв)"
TASKS=shop SHOP_BUDGET=2400 STAGE_CAP=1800 RUNS_FILE="$V/runs-v4-smoke-shop.txt" "$V/run-v4.sh" > "$V/logs/run.out" 2>&1
archive_logs smoke-shop-v42

# 4. гра для нових
if [ -n "$NEW" ]; then
  say "крок 4: гра для:$NEW (6 год на модель)"
  TASKS=gra GRA_BUDGET=21600 STAGE_CAP=5400 MODELS_ONLY="$NEW" RUNS_FILE="$V/runs-v4-new-gra.txt" "$V/run-v4.sh" > "$V/logs/run.out" 2>&1
  archive_logs new-gra
else
  say "крок 4 пропущено: жодна нова модель не готова"
  "$HOME/.lmstudio/bin/lms" load "qwen3.8-27b@iq2_xxs" -c 30720 --gpu max --identifier "qwen3.8-27b@iq2_xxs" -y < /dev/null >/dev/null 2>&1 8>&-
fi
say "ланцюжок завершено"
