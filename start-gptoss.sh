#!/bin/bash
# Гра v4: gpt-oss-20b з етапу 0, ті самі рішення, що в iq4_xs (README «Рішення за прогоном iq4_xs»). Запуск з `su - alex`.
V=/home/alex/v4_stand
[ -s "$V/logs/run.out" ] && { echo "== СТОП: logs/ не порожній — спершу заархівуй попередній прогін"; exit 1; }
[ -e /home/alex/v4_test/game/gpt-oss-20b ] && { echo "== СТОП: /home/alex/v4_test/game/gpt-oss-20b уже існує"; exit 1; }
mkdir -p "$V/logs"
START_STAGE=0 GRA_BUDGET=172800 STAGE_CAP=5400 TASKS=gra RUNS_FILE=$V/runs-v4-gptoss.txt \
nohup "$V/run-v4.sh" > "$V/logs/run.out" 2>&1 &
echo "запущено, PID $!"
