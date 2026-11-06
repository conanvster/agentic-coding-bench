#!/bin/bash
# Гра v4.1 (підготовлено 05.11): kat-coder-v2.5, потім qwen3.6-35b-a3b — обидві з етапу 0, без зору, стенд як для gemma r2
# 05.11: НЕ ЗАПУСКАТИ повторно — kat уже йде (продовження start-kat-day2.sh), qwen3.6 — start-qwen36.sh.
# (самоподіл етапів, обов'язковий перегляд гри текстовим звітом сцени, зрозумілі помилки інструментів, відповідь до 32k).
# Бюджет 48 год на модель, 90 хв на спробу. Запуск з `su - alex`.
V=/home/alex/v4_stand
[ -s "$V/logs/run.out" ] && { echo "== СТОП: logs/ не порожній — спершу заархівуй попередній прогін"; exit 1; }
for s in kat-coder-v2.5 qwen3.6-35b-a3b; do
  [ -e "/home/alex/v4_test/game/$s" ] && { echo "== СТОП: /home/alex/v4_test/game/$s уже існує"; exit 1; }
  [ -e "$V/stash/gra/$s" ] && { echo "== СТОП: stash/gra/$s уже існує"; exit 1; }
done
mkdir -p "$V/logs"
START_STAGE=0 GRA_BUDGET=172800 STAGE_CAP=5400 TASKS=gra RUNS_FILE=$V/runs-v4-kat-qwen36.txt \
nohup "$V/run-v4.sh" > "$V/logs/run.out" 2>&1 &
echo "запущено, PID $!"
