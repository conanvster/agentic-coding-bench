#!/bin/bash
# 11.11 (слово користувача): продовжити повний сайт з місця зупинки (runs-full-shop-resume.txt, поле start=N).
# Перша частина (до 05:11 11.11) → archive/full-shop-2026-11-11-0511-chastyna1/{logs,sites} (копія сайтів на момент зупинки).
# Сайти з stash/shop/ повертаються в v4_test/shop/ і модель продовжує в тому самому каталозі.
# Нове в run-v4.sh: перед кожною спробою < 20 ГБ вільно → docker builder prune -af; < 10 ГБ і після чистки → пауза.
# Запуск: ./start-full-shop-resume.sh
V=/home/alex/v4_stand; T=/home/alex/v4_test/shop; P1="$V/archive/full-shop-2026-11-11-0511-chastyna1"
# 11.11 18:41: RUNS — інший файл черги (runs-full-shop-resume3.txt), PART — мітка архіву цієї частини
RUNS="${RUNS:-$V/runs-full-shop-resume.txt}"; PART="${PART:-chastyna2}"
for p in /proc/[0-9]*; do case "$(tr '\0' ' ' < $p/cmdline 2>/dev/null)" in *"run-""v4.sh"*|*"bench-tune2/"*) echo "== СТОП: іде прогін/замір (PID ${p#/proc/})"; exit 1;; esac; done
f=$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null | grep -v -e llama -e lmstudio)
[ -n "$f" ] && { echo "== СТОП: на відеокарті чужий процес: $(echo $f)"; exit 1; }
free=$(df -BG --output=avail / | tail -1 | tr -dc 0-9); [ "$free" -lt 30 ] && { echo "== СТОП: на диску $free ГБ — потрібно ≥ 30"; exit 1; }
if [ ! -d "$P1" ]; then
  [ -s "$V/logs/run.out" ] || { echo "== СТОП: logs/ порожній, а першої частини в архіві нема — щось не так"; exit 1; }
  mkdir -p "$P1/sites" && mv "$V/logs" "$P1/logs" && mkdir -p "$V/logs" || exit 1
  cp -a "$V/archive/full-shop-launch.out" "$V/archive/read-guard.out" "$V/archive/stand-watch.out" "$P1/" 2>/dev/null
fi
[ -s "$V/logs/run.out" ] && { echo "== СТОП: logs/ не порожній"; exit 1; }
while IFS='|' read -r model slug ctx opts; do
  if [ -d "$V/stash/shop/$slug" ]; then
    [ -e "$P1/sites/$slug" ] || cp -a "$V/stash/shop/$slug" "$P1/sites/" || exit 1
    [ -e "$T/$slug" ] && { echo "== СТОП: $T/$slug уже існує"; exit 1; }
    mv "$V/stash/shop/$slug" "$T/" || exit 1
  fi
  case "$opts" in
    *start=*) [ -d "$T/$slug" ] || { echo "== СТОП: нема каталогу сайту $slug для продовження"; exit 1; } ;;
    *) [ -e "$T/$slug" ] && { echo "== СТОП: $slug стартує з нуля, а $T/$slug уже існує"; exit 1; } ;;
  esac
done < <(grep -v '^#' "$RUNS" | grep .)
avail=$(awk '/MemAvailable/{print int($2/1048576)}' /proc/meminfo); [ "$avail" -lt 18 ] && echo "== УВАГА: оперативки доступно $avail ГБ — закрий браузер (qwen3.6 Q4 потребує ≥ 15 ГБ)"
setsid nohup "$V/tools/read-guard.py" > "$V/archive/read-guard.out" 2>&1 &
guard=$!
nohup bash -c '
V=/home/alex/v4_stand
MODEL_RULES="$V/model-rules-full" TASKS=shop SHOP_BUDGET=604800 STAGE_CAP=86400 RUNS_FILE="'"$RUNS"'" \
  "$V/run-v4.sh" > "$V/logs/run.out" 2>&1
kill '"$guard"' 2>/dev/null
a="$V/archive/full-shop-$(date +%F-%H%M)-'"$PART"'"; mkdir -p "$a/sites" && mv "$V/logs" "$a/logs" && mkdir -p "$V/logs"
mv "$V/stash/shop/"full-* "$a/sites/" 2>/dev/null
echo "== $(date "+%F %T") архів: $a"
' > "$V/archive/full-shop-launch.out" 2>&1 &
echo "запущено (PID $!): $(grep -v '^#' "$RUNS" | grep . | cut -d'|' -f2,4 | tr '\n' ' '); журнал — logs/run.out; сторож — PID $guard"
