#!/bin/bash
# 15.11 (слово користувача: «зупиняй і розбивай етап 5»): етап 5 qwen3.8 Q3_K_XL застряг у циклі стискань контексту
# (з 11:00 до 14:30 жодної зміни у файлах, 16 стискань; сторінки написані, компонентних тестів — жодного).
# Частина 4 (етапу 5 спроба 1 перервана) → archive/full-shop-2026-11-15-1432-chastyna4 (журнали + знімок сайту).
#  1) сайт full-q38q3 → коміт етапу 4 (a9052c7), як у resume4 MODE=clean
#  2) етап 5 частинами 5a (основа + лендінг) / 5b (каталог + сторінка гри) / 5c (кошик, checkout, решта) —
#     stages-shop-split5.txt; LAST_SUB=c — повна перевірка етапу (чекліст PLAN.md) лише на 5c;
#     gate.py shop5_part: у кожної частини свої файли й компонентні тести *.test.tsx
#  3) STAGE_CAP=18000 (5 год на спробу; найдовший успішний етап досі — 3,1 год), щоб цикл не палив добу
#  4) черга runs-full-shop-resume5.txt → ./start-full-shop-resume.sh, PART=chastyna5
# Запуск:  ./start-resume5.sh   (--dry — лише показати)
set -u
V=/home/alex/v4_stand; SITE=/home/alex/v4_test/shop/full-q38q3
STAGE4=a9052c7
DRY=0; [ "${1:-}" = "--dry" ] && DRY=1

for p in /proc/[0-9]*; do case "$(tr '\0' ' ' < $p/cmdline 2>/dev/null)" in *"run-""v4.sh"*|*"bench-tune2/"*) echo "== СТОП: іде прогін/замір (PID ${p#/proc/})"; exit 1;; esac; done 2>/dev/null
[ -d "$SITE/.git" ] || { echo "== СТОП: нема $SITE"; exit 1; }
git -C "$SITE" log -1 --format=%s "$STAGE4" 2>/dev/null | grep -q '^Етап 4' || { echo "== СТОП: коміт $STAGE4 не «Етап 4»"; exit 1; }
[ "$(git -C "$SITE" rev-parse --short=7 HEAD)" = "$STAGE4" ] || { echo "== СТОП: HEAD сайту не $STAGE4 — перевір вручну"; exit 1; }
[ -d "$V/archive/full-shop-2026-11-15-1432-chastyna4/sites/full-q38q3" ] || { echo "== СТОП: нема знімка сайту частини 4 в архіві"; exit 1; }
[ -s "$V/logs/run.out" ] && { echo "== СТОП: logs/ не порожній — спершу ./stop-stand.sh"; exit 1; }

echo "== незакомічене в сайті (буде відкинуто, копія в архіві частини 4): $(git -C "$SITE" status --short | wc -l) шляхів"
echo "== етапи: $(cut -d'|' -f1 "$V/stages-shop-split5.txt" | tr '\n' ' ')"
echo "== черга: $(grep -v '^#' "$V/runs-full-shop-resume5.txt" | grep . | tr '\n' ' ')"
echo "== STAGE_CAP=18000 с на спробу, LAST_SUB=c"
[ $DRY = 1 ] && { echo "== --dry: нічого не змінено"; exit 0; }

git -C "$SITE" reset -q --hard "$STAGE4" && git -C "$SITE" clean -qfd || exit 1   # без -x: .env і node_modules лишаються
echo "== сайт повернуто на коміт етапу 4 ($STAGE4)"

cd "$V" && STAGES_FILE="$V/stages-shop-split5.txt" LAST_SUB=c STAGE_CAP=18000 \
  RUNS="$V/runs-full-shop-resume5.txt" PART=chastyna5 exec ./start-full-shop-resume.sh
