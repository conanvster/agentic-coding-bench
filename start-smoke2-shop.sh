#!/bin/bash
# 07.11 (слово користувача: додати 3 перевірки сайту й обов'язково димовий). Чекає кінця нічного ланцюжка (flint),
# ставить v4.3 (gate.py + stages-shop.txt з next/v4.3, старі → archive/stand-v4.2-gate-*), проганяє нову перевірку
# етапу 6 на старому димовому сайті (має впасти: e2e/скриншотів немає), потім димовий gpt-oss 40 хв → archive/smoke2-shop-v43-*
V=/home/alex/v4_stand
say() { echo "== $(date '+%F %T') $*"; }
find_pids() { local p c; for p in /proc/[0-9]*; do c=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null) || continue; case "$c" in *"$1"*) echo "${p#/proc/}";; esac; done 2>/dev/null; }
busy() { [ -n "$(find_pids "chain-night-""06-11.sh")$(find_pids "run-""v4.sh")" ]; }
[ -e /home/alex/v4_test/shop/gpt-oss-20b-smoke2 ] && { say "СТОП: shop/gpt-oss-20b-smoke2 уже існує"; exit 1; }
say "чекаю кінця нічного ланцюжка"
while busy; do sleep 30; done
say "ланцюжок завершено; ставлю v4.3"
B="$V/archive/stand-v4.2-gate-$(date +%F-%H%M)"; mkdir -p "$B"
cp "$V/gate.py" "$V/stages-shop.txt" "$B/" && cp "$V/next/v4.3/gate.py" "$V/gate.py" && cp "$V/next/v4.3/stages-shop.txt" "$V/stages-shop.txt" || { say "СТОП: не вдалось поставити v4.3"; exit 1; }
say "перевірка нового gate на старому димовому сайті (етап 6, очікую ✗ e2e і скриншоти)"
R="$V/archive/gate-v43-regress-$(date +%F-%H%M)"; mkdir -p "$R"
cp -a "$V/stash/shop/gpt-oss-20b-smoke" "$R/site"
(cd "$R/site" && timeout 1800 python3 "$V/gate.py" shop 6; echo "код $?"; docker compose down -v >/dev/null 2>&1) > "$R/gate-s6.txt" 2>&1
grep -E "^✗|Підсумок|^код" "$R/gate-s6.txt"
rm -rf "$R/site"
say "димовий сайту v4.3: gpt-oss, SHOP_BUDGET 2400, STAGE_CAP 1800"
mkdir -p "$V/logs"
TASKS=shop SHOP_BUDGET=2400 STAGE_CAP=1800 RUNS_FILE="$V/runs-v4-smoke2-shop.txt" "$V/run-v4.sh" > "$V/logs/run.out" 2>&1
A="$V/archive/smoke2-shop-v43-$(date +%F-%H%M)"; mkdir -p "$A" && mv "$V/logs" "$A/logs" && mkdir -p "$V/logs" && say "логи → $A"
say "готово"
