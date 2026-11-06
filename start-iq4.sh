#!/bin/bash
# Гра v4: iq4_xs з етапу 4, без ліміту часу. Запуск з `su - alex`.
V=/home/alex/v4_stand
[ -s "$V/logs/run.out" ] && { echo "== СТОП: $V/logs/run.out не порожній — заархівуй попередній прогін"; exit 1; }
START_STAGE=4 GRA_BUDGET=172800 STAGE_CAP=10800 TASKS=gra RUNS_FILE=$V/runs-v4-iq4.txt \
EXTRA_NOTE="Проєкт перенесено з /home/alex/Задачі/гра/qwen3.8-27b-iq4-xs у цей каталог разом з git; старі шляхи в docs/ застарілі. Етапи 0–3 уже зроблено. Стенд оновлено: користуйся інструментами stand_* (особливо godot_run — він показує, що бачить камера)." \
nohup "$V/run-v4.sh" > "$V/logs/run.out" 2>&1 &
echo "== запущено (pid $!); стан: $V/status.sh -f"
