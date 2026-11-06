#!/bin/bash
# Гра v4.2 з нуля: qwen3.6-35b-a3b (підготовлено 05.11, 06.11 — стенд v4.2, llama-server напряму). ctx 131072, без зору.
# Запуск з `su - alex`, коли kat завершить (logs/ має бути заархівовано).
V=/home/alex/v4_stand
[ -e "$V/HOLD-qwen36" ] && { echo "== СТОП: є $V/HOLD-qwen36 — qwen3.6 притримано до оновлення перевірки (06.11); видали файл і запусти вручну"; exit 1; }
[ -s "$V/logs/run.out" ] && { echo "== СТОП: logs/ не порожній — спершу заархівуй попередній прогін"; exit 1; }
[ -e /home/alex/v4_test/game/qwen3.6-35b-a3b ] && { echo "== СТОП: каталог qwen3.6 уже існує"; exit 1; }
[ -e "$V/stash/gra/qwen3.6-35b-a3b" ] && { echo "== СТОП: stash/gra/qwen3.6-35b-a3b уже існує"; exit 1; }
mkdir -p "$V/logs"
export START_STAGE=0 GRA_BUDGET=172800 STAGE_CAP=5400 TASKS=gra RUNS_FILE=$V/runs-v4-qwen36.txt
# FOREGROUND=1 — чекати кінця прогону (для ланцюжка start-kat-r2-qwen36.sh)
if [ "${FOREGROUND:-0}" = 1 ]; then "$V/run-v4.sh" > "$V/logs/run.out" 2>&1; exit $?; fi
nohup "$V/run-v4.sh" > "$V/logs/run.out" 2>&1 &
echo "запущено, PID $!"
