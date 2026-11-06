#!/bin/bash
# Гра v4.1 (04.11): gpt-oss-20b, повтор з етапу 3 на копії її ж каталогу після прогону 04.11 (етапи 0–2 ✓, етап 3 ✗).
# Нове у v4.1: модель сама ділить етап після 3 невдач (3 → 3.1, 3.2 …), обов'язковий перегляд гри, зрозумілі помилки
# інструментів, відповідь до 32k (поріг стискання 122 880). Запуск з `su - alex`.
V=/home/alex/v4_stand
SRC=$V/stash/gra/gpt-oss-20b
WD=/home/alex/v4_test/game/gpt-oss-20b-r2
[ -s "$V/logs/run.out" ] && { echo "== СТОП: logs/ не порожній — спершу заархівуй попередній прогін"; exit 1; }
[ -e "$WD" ] && { echo "== СТОП: $WD уже існує"; exit 1; }
[ -e "$V/stash/gra/gpt-oss-20b-r2" ] && { echo "== СТОП: stash/gra/gpt-oss-20b-r2 уже існує"; exit 1; }
[ -d "$SRC/.git" ] || { echo "== СТОП: немає $SRC"; exit 1; }
mkdir -p "$V/logs" /home/alex/v4_test/game
cp -a "$SRC" "$WD"
START_STAGE=3 GRA_BUDGET=172800 STAGE_CAP=5400 TASKS=gra RUNS_FILE=$V/runs-v4-gptoss-r2.txt \
nohup "$V/run-v4.sh" > "$V/logs/run.out" 2>&1 &
echo "запущено, PID $!"
