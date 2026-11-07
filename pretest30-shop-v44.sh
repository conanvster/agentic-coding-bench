#!/bin/bash
# 07.11 (слово користувача): flint і qwen3.8 — етапи 0–1 сайту, 30 хв на модель (у претесті на 15 хв не встигли етап 0).
# Зір уже перевірено (archive/pretest-shop-v44-2026-11-07-1347) — тут без проби. Результат: archive/pretest30-shop-v44-<час>/.
V=/home/alex/v4_stand
say() { echo "== $(date '+%F %T') $*"; }
for p in /proc/[0-9]*; do case "$(tr '\0' ' ' < $p/cmdline 2>/dev/null)" in *"run-""v4.sh"*) say "СТОП: іде прогін (PID ${p#/proc/})"; exit 1;; esac; done 2>/dev/null
[ -s "$V/logs/run.out" ] && { say "СТОП: logs/ не порожній"; exit 1; }
f=$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null | grep -v -e llama -e lmstudio)
[ -n "$f" ] && { say "СТОП: на відеокарті чужий процес: $(echo $f) — закрий його й запусти знову"; exit 1; }
OUT="$V/archive/pretest30-shop-v44-$(date +%F-%H%M)"; mkdir -p "$OUT"
"$HOME/.lmstudio/bin/lms" unload --all >/dev/null 2>&1 8>&-; sleep 3
say "сайт, етапи 0–1, 30 хв на модель: flint, qwen3.8"
TASKS=shop SHOP_BUDGET=1800 STAGE_CAP=1800 STAGES_FILE="$V/stages-shop-pre.txt" RUNS_FILE="$V/runs-v4-pre30-shop.txt" "$V/run-v4.sh" > "$V/logs/run.out" 2>&1
mv "$V/logs" "$OUT/logs" && mkdir -p "$V/logs"
say "готово → $OUT"
