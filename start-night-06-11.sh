#!/bin/bash
# Ніч 06→07.11: тіло — chain-night-06-11.sh (див. опис там). Запуск з `su - alex`; можна поки ще йде qwen3.6 Q2.
V=/home/alex/v4_stand
for d in /home/alex/v4_test/shop/gpt-oss-20b-smoke $V/stash/shop/gpt-oss-20b-smoke /home/alex/v4_test/game/qwen3.6-35b-a3b-q4kxl /home/alex/v4_test/game/flint-q4kxl $V/stash/gra/qwen3.6-35b-a3b-q4kxl $V/stash/gra/flint-q4kxl $V/stash/gra/qwen3.6-35b-a3b; do
  [ -e "$d" ] && { echo "== СТОП: $d уже існує"; exit 1; }
done
[ -f /home/alex/v4_test/inputs/shop/TZ.md ] || { echo "== СТОП: немає inputs/shop/TZ.md"; exit 1; }
L="$V/archive/chain-night-06-11-$(date +%F-%H%M).out"
nohup "$V/chain-night-06-11.sh" > "$L" 2>&1 &
echo "запущено, PID $!; журнал $L"
