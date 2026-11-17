#!/bin/bash
# 17.11 (слово користувача: «так, готуй»): продовження qwen3.8 27B UD-Q3_K_XL у повторному прогоні r2 з етапу 6.
# Чому: у r2 етап 6 зупинено «ПОТРІБЕН ПОДІЛ», але 2 з 3 спроб обірвав збій відеокарти Xid 8 (13:59/14:10 і 17:34),
# а запас незарахованих перезапусків моделі (2 на модель) вичерпано ще на етапі 4 (Xid 05:20). Спроба 3 дійшла до 12/17.
# Продовження — той самий каталог сайту, ті самі рівні умови (model-rules-r2: рушій 2.66.0, -ub 256 -b 2048, графи off,
# контекст 98 304), етапи 6–9, свіжий запас перезапусків і спроб. У звіті — окремим рядком «продовження після Xid».
#   MODE=keep (типово) — стан сайту як у кінці спроби 3 (між спробами етапу стенд нічого не відкочує — так само тут);
#   MODE=clean — відкотити до коміту етапу 5c (8f8b0e1).
# Запуск — лише після завершення ланцюжка r2 (прогін IQ4_XS + архів + аналіз):  ./start-r2b-q3-resume.sh [--dry]
# Після прогону: архів archive/full-shop-r2b-<час>/ і аналіз пари (Q3_K_XL r2b + IQ4_XS r2) — qa/analyze-shop.sh.
V=/home/alex/v4_stand; SLUG=full-r2-q38q3; STAGE5C=8f8b0e1; RULES="$V/model-rules-r2"; RUNS="$V/runs-full-shop-r2b.txt"
MODE="${MODE:-keep}"; DRY=0; [ "${1:-}" = "--dry" ] && DRY=1
case "$MODE" in keep|clean) ;; *) echo "== СТОП: MODE має бути keep або clean"; exit 1;; esac
for p in /proc/[0-9]*; do case "$(tr '\0' ' ' < $p/cmdline 2>/dev/null)" in *"run-""v4.sh"*|*"analyze-""shop.sh"*|*"fit-""equal.sh"*) echo "== СТОП: іде прогін/аналіз (PID ${p#/proc/})"; exit 1;; esac; done 2>/dev/null
[ -s "$V/logs/run.out" ] && { echo "== СТОП: logs/ не порожній — ланцюжок r2 ще не заархівував прогін"; exit 1; }
R2=$(ls -d "$V"/archive/full-shop-r2-2* 2>/dev/null | sort | tail -1)
[ -n "$R2" ] && [ -d "$R2/sites/$SLUG/.git" ] && [ -d "$R2/sites/full-r2-q38/.git" ] || { echo "== СТОП: нема архіву r2 з обома сайтами (archive/full-shop-r2-*)"; exit 1; }
[ -f "$R2/analysis/summary.json" ] || echo "== УВАГА: аналіз r2 ще не завершено ($R2/analysis) — краще дочекатись"
[ -d "$RULES" ] || { echo "== СТОП: нема $RULES (рівні умови r2)"; exit 1; }
grep -q '"graphs": "off"' "$RULES/qwen3.8-27b-q3kxl.json" || { echo "== СТОП: у $RULES графи не off"; exit 1; }
[ -e "/home/alex/v4_test/shop/$SLUG" ] || [ -e "$V/stash/shop/$SLUG" ] && { echo "== СТОП: $SLUG уже існує поза архівом"; exit 1; }
git -C "$R2/sites/$SLUG" log -1 --format=%s "$STAGE5C" 2>/dev/null | grep -q '^Етап 5c' || { echo "== СТОП: коміт $STAGE5C не «Етап 5c»"; exit 1; }
free=$(df -BG --output=avail / | tail -1 | tr -dc 0-9); [ "$free" -lt 30 ] && { echo "== СТОП: на диску $free ГБ — потрібно ≥ 30"; exit 1; }
f=$(nvidia-smi --query-compute-apps=pid,process_name --format=csv,noheader 2>/dev/null | grep -v -e llama -e lmstudio)
[ -n "$f" ] && { echo "== СТОП: на відеокарті чужий процес: $f"; exit 1; }
echo "== архів r2: $R2"
echo "== сайт: $SLUG, HEAD $(git -C "$R2/sites/$SLUG" log -1 --format='%h %s' | cut -c1-70); незакомічено $(git -C "$R2/sites/$SLUG" status --short | wc -l); режим MODE=$MODE"
echo "== рівні умови: $(head -1 "$R2/runs-full-shop-r2.txt" 2>/dev/null | cut -c3-200)"
echo "== етапи 6–9 (stages-shop-split5.txt), STAGE_CAP=18000, LAST_SUB=c, свіжий запас перезапусків і 3 спроби на етап"
[ $DRY = 1 ] && { echo "== --dry: нічого не змінено"; exit 0; }

rsync -a "$R2/sites/$SLUG/" "/home/alex/v4_test/shop/$SLUG/" || exit 1   # архів r2 лишається незмінним
if [ "$MODE" = clean ]; then git -C "/home/alex/v4_test/shop/$SLUG" reset -q --hard "$STAGE5C" && git -C "/home/alex/v4_test/shop/$SLUG" clean -qfd || exit 1; fi
{ echo "# 17.11 r2b: продовження qwen3.8 UD-Q3_K_XL з етапу 6 після збоїв Xid 8 у r2 (MODE=$MODE); рівні умови — $RULES"
  echo "qwen3.8-27b@q3_k_xl|$SLUG|98304|start=6"; } > "$RUNS"
setsid nohup "$V/tools/read-guard.py" > "$V/archive/read-guard.out" 2>&1 &
guard=$!
nohup bash -c '
V=/home/alex/v4_stand; RUNS="'"$RUNS"'"; RULES="'"$RULES"'"; R2="'"$R2"'"
hj=(); command -v hubjob >/dev/null && hj=(hubjob --назва "стенд shop r2b (Q3_K_XL з етапу 6)" --тиша 30 --журнал "$V/logs/proxy.tsv" --)
MODEL_RULES="$RULES" TASKS=shop SHOP_BUDGET=604800 STAGE_CAP=18000 LAST_SUB=c STAGES_FILE="$V/stages-shop-split5.txt" \
  RUNS_FILE="$RUNS" "${hj[@]}" "$V/run-v4.sh" > "$V/logs/run.out" 2>&1
kill '"$guard"' 2>/dev/null
a="$V/archive/full-shop-r2b-$(date +%F-%H%M)"; mkdir -p "$a/sites" && mv "$V/logs" "$a/logs" && mkdir -p "$V/logs"
mv "$V/stash/shop/'"$SLUG"'" "$a/sites/" 2>/dev/null; cp -a "$RUNS" "$V/archive/read-guard.out" "$a/" 2>/dev/null
echo "== $(date "+%F %T") архів: $a"
command -v hubjob >/dev/null && hj2=(hubjob --тиша 40 --назва "r2b: аналіз пари (Q3_K_XL r2b + IQ4_XS r2)" --) || hj2=()
"${hj2[@]}" "$V/qa/analyze-shop.sh" "$a/analysis" "$a/sites/'"$SLUG"'" "$R2/sites/full-r2-q38"
echo "== $(date "+%F %T") готово: $a/analysis/summary.json"
' > "$V/archive/full-shop-r2b-launch.out" 2>&1 &
echo "запущено (PID $!): журнал ланцюжка — archive/full-shop-r2b-launch.out, прогону — logs/run.out; сторож — PID $guard"
