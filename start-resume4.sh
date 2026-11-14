#!/bin/bash
# 14.11: продовження повного сайту після перезавантаження ПК о 10:30 (завис Wi-Fi, етап 5 спроба 2 перервана).
#  1) частина 3 (logs/ + знімок сайту без node_modules + diff незакоміченого) → archive/full-shop-2026-11-14-1030-chastyna3
#  2) каталог сайту full-q38q3:
#       MODE=clean (типово) — повернути на коміт етапу 4 (a9052c7): етап 5 з чистого стану, як в інших моделей
#       MODE=keep           — лишити напрацювання обох спроб етапу 5 як є
#  3) черга runs-full-shop-resume4.txt (Q3_K_XL з етапу 5, IQ4_XS з нуля) → ./start-full-shop-resume.sh, PART=chastyna4
# Запуск:  ./start-resume4.sh            (або MODE=keep ./start-resume4.sh)
#          ./start-resume4.sh --dry     — лише показати, що буде зроблено
set -u
V=/home/alex/v4_stand; SITE=/home/alex/v4_test/shop/full-q38q3
A="$V/archive/full-shop-2026-11-14-1030-chastyna3"
STAGE4=a9052c7
MODE="${MODE:-clean}"; DRY=0; [ "${1:-}" = "--dry" ] && DRY=1
case "$MODE" in clean|keep) ;; *) echo "== СТОП: MODE має бути clean або keep"; exit 1;; esac

for p in /proc/[0-9]*; do case "$(tr '\0' ' ' < $p/cmdline 2>/dev/null)" in *"run-""v4.sh"*|*"bench-tune2/"*) echo "== СТОП: іде прогін/замір (PID ${p#/proc/})"; exit 1;; esac; done 2>/dev/null
[ -d "$SITE/.git" ] || { echo "== СТОП: нема $SITE"; exit 1; }
git -C "$SITE" log -1 --format=%s "$STAGE4" 2>/dev/null | grep -q '^Етап 4' || { echo "== СТОП: коміт $STAGE4 не «Етап 4»"; exit 1; }
[ "$(git -C "$SITE" rev-parse --short=7 HEAD)" = "$STAGE4" ] || { echo "== СТОП: HEAD сайту не $STAGE4 — модель встигла закомітити щось нове, перевір вручну"; exit 1; }

# Wi-Fi: о 01:00 14.11 карта mt7921e зависла в енергозбереженні — лише попередження, прогону не заважає
ps_now=$(iw dev wlp6s0 get power_save 2>/dev/null | awk '{print $NF}')
aspm=$(cat /sys/module/mt7921e/parameters/disable_aspm 2>/dev/null)
[ "$ps_now" = "on" ] || [ "$aspm" = "N" ] && echo "== УВАГА: Wi-Fi power_save=$ps_now, disable_aspm=$aspm — карта може знову зависнути вночі (див. відповідь 14.11)"

echo "== режим: MODE=$MODE; архів частини 3: $A"
echo "== незакомічене в сайті (етап 5, обидві спроби): $(git -C "$SITE" status --short | wc -l) шляхів"
echo "== черга: $(grep -v '^#' "$V/runs-full-shop-resume4.txt" | grep . | tr '\n' ' ')"
[ $DRY = 1 ] && { echo "== --dry: нічого не змінено"; exit 0; }

# 1) архів частини 3
if [ -s "$V/logs/run.out" ]; then
  [ -e "$A" ] && { echo "== СТОП: $A уже існує, а logs/ не порожній"; exit 1; }
  mkdir -p "$A/sites" && mv "$V/logs" "$A/logs" && mkdir -p "$V/logs" || exit 1
  cp -a "$V/archive/full-shop-launch.out" "$V/archive/read-guard.out" "$V/archive/stand-watch.out" "$A/" 2>/dev/null
  rsync -a --exclude node_modules --exclude coverage "$SITE/" "$A/sites/full-q38q3/" || exit 1
  { git -C "$SITE" diff; git -C "$SITE" ls-files --others --exclude-standard; } > "$A/sites/full-q38q3-etap5-nezakomicheno.diff"
  echo "== частину 3 заархівовано"
fi

# 2) каталог сайту
if [ "$MODE" = clean ]; then
  git -C "$SITE" reset -q --hard "$STAGE4" && git -C "$SITE" clean -qfd || exit 1   # без -x: .env і node_modules лишаються
  echo "== сайт повернуто на коміт етапу 4 ($STAGE4)"
fi

# 3) запуск
cd "$V" && RUNS="$V/runs-full-shop-resume4.txt" PART=chastyna4 exec ./start-full-shop-resume.sh
