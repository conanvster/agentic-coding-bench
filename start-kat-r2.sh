#!/bin/bash
# Гра v4.2 (06.11): kat-coder-v2.5 ще раз з етапу 4 (слово користувача) на копії її гри після етапу 3 (коміт 26bd2ab).
# Стенд v4.2: llama-server напряму, проксі ловить переповнення від LM Studio, перевірка ✗ на втрачених батьків вузлів,
# засвічений і закритий кадр; у звіті godot_run — FRAME COVERAGE / BLOCKED VIEW / LOST PARENTS.
# Старі результати kat (0–8c.1, v4.1) лишаються в stash/gra/kat-coder-v2.5 і archive/kat-day*. Запуск з `su - alex`.
V=/home/alex/v4_stand
SRC=$V/stash/gra/kat-coder-v2.5
WD=/home/alex/v4_test/game/kat-coder-v2.5-r2
[ -s "$V/logs/run.out" ] && { echo "== СТОП: logs/ не порожній — спершу заархівуй попередній прогін"; exit 1; }
[ -e "$WD" ] && { echo "== СТОП: $WD уже існує"; exit 1; }
[ -e "$V/stash/gra/kat-coder-v2.5-r2" ] && { echo "== СТОП: stash/gra/kat-coder-v2.5-r2 уже існує"; exit 1; }
[ -d "$SRC/.git" ] || { echo "== СТОП: немає $SRC"; exit 1; }
mkdir -p "$V/logs" /home/alex/v4_test/game
git clone -q "$SRC" "$WD" && git -C "$WD" checkout -q -B master 26bd2ab || { echo "== СТОП: не вдалося взяти коміт 26bd2ab"; exit 1; }
git -C "$WD" remote remove origin
echo "== каталог $WD на $(git -C "$WD" log --oneline -1)"
export START_STAGE=4 GRA_BUDGET=172800 STAGE_CAP=5400 TASKS=gra RUNS_FILE=$V/runs-v4-kat-r2.txt
export EXTRA_NOTE="Етапи 0–3 зроблено раніше й зараховано за старими правилами стенду. Перевірка тепер суворіша: вузли сцени, що втратили батька, засвічений кадр і кадр, закритий предметом перед камерою, — це ✗. Якщо stand_stage_check покаже такі вади зі сцени етапу 3, виправ їх у межах цього етапу."
# FOREGROUND=1 — чекати кінця прогону (для ланцюжка start-kat-r2-qwen36.sh)
if [ "${FOREGROUND:-0}" = 1 ]; then "$V/run-v4.sh" > "$V/logs/run.out" 2>&1; exit $?; fi
nohup "$V/run-v4.sh" > "$V/logs/run.out" 2>&1 &
echo "запущено, PID $!"
