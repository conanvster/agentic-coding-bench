#!/bin/bash
# 08.11 (слово користувача): сайт flint — нечесний замір: з ~30-ї хв нестача оперативки (Chrome, Godot, своп 8/8 ГБ)
# витісняла експертів flint (-ncmoe 32, ~10 ГБ в оперативці) — читання з диска 0,9 ГБ/с, генерація 48 → 15–20 ток/с,
# підказка 172 → ~40 ток/с. Компенсація: продовжити її сайт з першого непройденого етапу ще EXTRA_H год (типово 3,5)
# на чистій машині. Розрахунок: ~5,5 год на ~0,4 швидкості ≈ 2,2 год норми + 0,5 год чистих → бракує ~3,3 год.
# Можна запускати одразу: чекає кінця поточного прогону (gpt-oss, ~05:05), архівує його логи, повертає каталог flint
# зі stash (копія стану на 6 год → архів), перевіряє оперативку і запускає. Сповіщення — через хаб.
V=/home/alex/v4_stand
EXTRA_H="${EXTRA_H:-3.5}"; NEED_GB="${NEED_GB:-20}"
say() { echo "== $(date '+%F %T') $*"; }
ENVF="$HOME/.config/hub/env"; HUB_URL=$(grep '^HUB_URL=' "$ENVF" | cut -d= -f2-); HUB_KEY=$(grep '^HUB_KEY=' "$ENVF" | cut -d= -f2-)
notify() { curl -s -m 20 -H "Authorization: Bearer $HUB_KEY" -H 'Content-Type: application/json' \
  -d "$(python3 -c 'import json,sys; print(json.dumps({"title": sys.argv[1], "text": sys.argv[2]}))' "$1" "$2")" \
  "${HUB_URL%/}/api/notify" >/dev/null; }
run_active() { for p in /proc/[0-9]*; do case "$(tr '\0' ' ' < $p/cmdline 2>/dev/null)" in *"run-""v4.sh"*) return 0;; esac; done 2>/dev/null; return 1; }

if run_active; then say "іде прогін — чекаю його кінця"; while run_active; do sleep 60; done; say "прогін завершився"; fi
grep -q "all done" "$V/logs/run.out" || { say "СТОП: у logs/run.out немає «all done» — прогін не завершився сам"; notify "❌ flint +${EXTRA_H} год: не запущено" "прогін сайту не дійшов до all done"; exit 1; }

# 1) логи 5 моделей → архів; стан flint на 6 год → архів (копія)
A="$V/archive/shop-v44-$(date +%F-%H%M)"
mkdir -p "$A" && mv "$V/logs" "$A/logs" && mkdir -p "$V/logs" && say "логи сайту v4.4 → $A"
cp -a "$V/stash/shop/flint-q4kxl" "$A/flint-q4kxl-at-6h" && say "стан flint на 6 год → $A/flint-q4kxl-at-6h"

# 2) перший непройдений етап flint (за журналом прогону)
LAST=$(grep -oE "shop flint-q4kxl етап [0-9]+[a-z]? спроба [0-9]+: oc=[0-9]+ перевірка=0" "$A/logs/run.out" | awk '{print $4}' | sed 's/[^0-9].*//' | sort -n | tail -1)
START=$(( ${LAST:-0} + 1 ))
say "flint пройшла до етапу ${LAST:-—}; продовжую з етапу $START"

# 3) оперативка: експертам flint потрібно ~17 ГБ разом із кешем
avail=$(awk '/MemAvailable/{print int($2/1048576)}' /proc/meminfo)
if [ "$avail" -lt "$NEED_GB" ]; then
  say "СТОП: доступно $avail ГБ оперативки, потрібно ≥ $NEED_GB — закрий Chrome/Godot/«Ресурси» і запусти знову"
  notify "❌ flint +${EXTRA_H} год: мало оперативки" "доступно $avail ГБ, потрібно ≥ $NEED_GB; логи вже в архіві — запусти скрипт знову після звільнення"
  exit 1
fi
f=$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null | grep -v -e llama -e lmstudio)
[ -n "$f" ] && { say "СТОП: на відеокарті чужий процес: $(echo $f)"; notify "❌ flint +${EXTRA_H} год: чужий процес на GPU" "$f"; exit 1; }

# 4) каталог flint назад на робоче місце і продовження
mv "$V/stash/shop/flint-q4kxl" /home/alex/v4_test/shop/flint-q4kxl || exit 1
budget=$(python3 -c "print(int(float('$EXTRA_H') * 3600))")
notify "▶ flint +${EXTRA_H} год стартував" "з етапу $START; доступно $avail ГБ оперативки"
say "старт: flint, етап $START+, бюджет $budget с"
TASKS=shop SHOP_BUDGET="$budget" STAGE_CAP=5400 START_STAGE="$START" MODELS_ONLY="flint-q4kxl" \
  RUNS_FILE="$V/runs-v4-shop.txt" "$V/run-v4.sh" > "$V/logs/run.out" 2>&1
say "готово; логи — $V/logs (архівувати разом з $A)"
