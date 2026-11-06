#!/bin/bash
# Продовження прогону iq4_xs (день 2, частина 2): з етапу 8, ctx 69632. Попереднє — archive/iq4-day1-2026-11-01, archive/iq4-day2-2026-11-02
V=/home/alex/v4_stand
[ -s "$V/logs/run.out" ] && { echo "== СТОП: logs/ не порожній — спершу заархівуй попередній прогін"; exit 1; }
mkdir -p "$V/logs"
START_STAGE=8 GRA_BUDGET=172800 STAGE_CAP=10800 TASKS=gra RUNS_FILE=$V/runs-v4-iq4.txt \
EXTRA_NOTE="Етап 8 починається заново (попередню спробу перервав стенд: контекст переповнювався, поки ти читав цілі файли; тепер вікно більше). Читай файли частинами — stand_read_lines з start/count або grep, а не цілком: scenes/main.tscn має ~1000 рядків. Користуйся інструментами stand_* (read_lines/edit_lines/write_file/godot_run)." \
nohup "$V/run-v4.sh" > "$V/logs/run.out" 2>&1 &
echo "запущено, PID $!"
