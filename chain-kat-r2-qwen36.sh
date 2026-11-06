#!/bin/bash
# Тіло ланцюжка (запускає start-kat-r2-qwen36.sh у фоні): kat r2 → архів логів → qwen3.6 → архів логів.
V=/home/alex/v4_stand
archive_logs() {
  local a="$V/archive/$1-$(date +%F-%H%M)"
  mkdir -p "$a" && mv "$V/logs" "$a/logs" && mkdir -p "$V/logs" && echo "== $(date '+%F %T') логи → $a"
}
echo "== $(date '+%F %T') kat r2 старт"
FOREGROUND=1 "$V/start-kat-r2.sh"; echo "== $(date '+%F %T') kat r2 кінець, код $?"
[ -s "$V/logs/run.out" ] || { echo "== kat не стартував — ланцюжок зупинено"; exit 1; }
grep -q '^== all done' "$V/logs/run.out" || { echo "== прогін kat перервано (немає «all done») — qwen3.6 не запускаю, логи лишено в logs/"; exit 1; }
archive_logs kat-r2
echo "== $(date '+%F %T') qwen3.6 старт"
FOREGROUND=1 "$V/start-qwen36.sh"; echo "== $(date '+%F %T') qwen3.6 кінець, код $?"
grep -q '^== all done' "$V/logs/run.out" && archive_logs qwen36
