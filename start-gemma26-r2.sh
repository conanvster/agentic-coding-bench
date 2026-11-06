#!/bin/bash
# Гра v4.1 (підготовлено 04.11 на 05.11): gemma-4-26b Q4_0 із зором (mmproj на CPU) з етапу 0 — повтор на стенді v4.1:
# обов'язковий перегляд гри, скриншот картинкою в результаті godot_run, зрозумілі помилки інструментів, відповідь до 32k,
# модель сама ділить етап після 3 невдач. Спершу — pretest-gemma26.sh (стеля ctx, DRY, картинка через OpenCode).
# Запуск з `su - alex`.
V=/home/alex/v4_stand
WD=/home/alex/v4_test/game/gemma-4-26b-q4-0-r2
[ -s "$V/logs/run.out" ] && { echo "== СТОП: logs/ не порожній — спершу заархівуй попередній прогін"; exit 1; }
[ -e "$WD" ] && { echo "== СТОП: $WD уже існує"; exit 1; }
[ -e "$V/stash/gra/gemma-4-26b-q4-0-r2" ] && { echo "== СТОП: stash/gra/gemma-4-26b-q4-0-r2 уже існує"; exit 1; }
mkdir -p "$V/logs"
START_STAGE=0 GRA_BUDGET=172800 STAGE_CAP=5400 TASKS=gra RUNS_FILE=$V/runs-v4-gemma26-r2.txt \
nohup "$V/run-v4.sh" > "$V/logs/run.out" 2>&1 &
echo "запущено, PID $!"
