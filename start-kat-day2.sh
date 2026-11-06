#!/bin/bash
# Продовження kat-coder-v2.5 (день 2): з частини 8b (0–7 і 8a зараховано 05.11). День 1 — archive/kat-day1-2026-11-05.
# stages-gra-from8b.txt = stages-gra.txt без 8a (нумерація 1…9 та сама); START_STAGE=8 пропускає 0–7.
# Після kat — qwen3.6 окремим запуском (runs-v4-kat-qwen36.txt має лише її рядок або start-qwen36.sh). Запуск з `su - alex`.
V=/home/alex/v4_stand
WD=/home/alex/v4_test/game/kat-coder-v2.5
[ -s "$V/logs/run.out" ] && { echo "== СТОП: logs/ не порожній — спершу заархівуй попередній прогін"; exit 1; }
[ -d "$WD/.git" ] || { echo "== СТОП: немає $WD"; exit 1; }
[ -e "$V/stash/gra/kat-coder-v2.5" ] && { echo "== СТОП: stash/gra/kat-coder-v2.5 уже існує"; exit 1; }
mkdir -p "$V/logs"
START_STAGE=8 STAGES_FILE=$V/stages-gra-from8b.txt GRA_BUDGET=172800 STAGE_CAP=5400 TASKS=gra RUNS_FILE=$V/runs-v4-kat-day2.txt \
EXTRA_NOTE="Роботу над частиною 8b вчора перервано посередині (пауза стенду, не твоя помилка). Незакомічені зміни лежать у каталозі (scripts/shooter.gd, scenes/main.tscn, tests/scenario/five_hits.gd, docs/test-log.txt, docs/screenshots/, tools/five_hits_8a.gd) — перевір git status і продовжуй 8b. Користуйся інструментами stand_* (read_lines/edit_lines/write_file/godot_run)." \
nohup "$V/run-v4.sh" > "$V/logs/run.out" 2>&1 &
echo "запущено, PID $!"
