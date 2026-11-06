#!/bin/bash
# v4.2 (06.11): одна команда — kat з етапу 4 (start-kat-r2.sh), архів логів, потім qwen3.6 з нуля (start-qwen36.sh).
# Ланцюжок іде у фоні (chain-kat-r2-qwen36.sh); журнал — archive/chain-kat-r2-qwen36-<час>.out. Запуск з `su - alex`.
# Якщо kat перервати вручну (немає «all done»), qwen3.6 не стартує.
V=/home/alex/v4_stand
CH="$V/archive/chain-kat-r2-qwen36-$(date +%F-%H%M).out"
[ -s "$V/logs/run.out" ] && { echo "== СТОП: logs/ не порожній — спершу заархівуй попередній прогін"; exit 1; }
for d in /home/alex/v4_test/game/kat-coder-v2.5-r2 /home/alex/v4_test/game/qwen3.6-35b-a3b "$V/stash/gra/kat-coder-v2.5-r2" "$V/stash/gra/qwen3.6-35b-a3b"; do
  [ -e "$d" ] && { echo "== СТОП: $d уже існує"; exit 1; }
done
nohup "$V/chain-kat-r2-qwen36.sh" > "$CH" 2>&1 < /dev/null &
echo "ланцюжок запущено, PID $!; журнал $CH"
