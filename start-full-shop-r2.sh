#!/bin/bash
# 17.11 (слово користувача): повторний прогін повного сайту CyberSphere для qwen3.8 27B UD-Q3_K_XL і UD-IQ4_XS
# з останніми налаштуваннями й РІВНИМИ УМОВАМИ ЗАЛІЗА, і з повним аналізом після.
# Ланцюжок (усе у фоні під hubjob, сповіщення на телефон):
#   0) tools/fit-equal.sh — одна збірка llama-server для обох (2.66.0, якщо обидві вміщаються, інакше 2.28.2),
#      однакові -ctk/-ctv q8_0 -ub 256 -b 2048, CUDA-графи off обом, контекст — найбільший, що влазить для кожної
#      (зір на CPU в обох) → model-rules-r2/ і runs-full-shop-r2.txt;
#   1) run-v4.sh: обидві з нуля, етапи 0–9, етап 5 частинами 5a/5b/5c (stages-shop-split5.txt, LAST_SUB=c),
#      ліміт спроби 5 год, моделі не бачать ~/.claude/CLAUDE.md (OPENCODE_DISABLE_CLAUDE_CODE=1 у run-v4.sh);
#   2) архів → archive/full-shop-r2-<час>/{logs,sites};
#   3) qa/analyze-shop.sh для пари нових сайтів: приймальна перевірка (браузер + API), Stryker, сліпа рецензія.
# Запуск: ./start-full-shop-r2.sh        (--dry — лише перевірки й параметри, нічого не вантажить)
V=/home/alex/v4_stand; RUNS="$V/runs-full-shop-r2.txt"; RULES="$V/model-rules-r2"
DRY=0; [ "${1:-}" = "--dry" ] && DRY=1
[ -s "$V/logs/run.out" ] && { echo "== СТОП: logs/ не порожній — спершу заархівуй попередній прогін"; exit 1; }
for p in /proc/[0-9]*; do case "$(tr '\0' ' ' < $p/cmdline 2>/dev/null)" in *"run-""v4.sh"*|*"bench-tune2/"*|*"fit-""equal.sh"*) echo "== СТОП: іде прогін/замір (PID ${p#/proc/})"; exit 1;; esac; done 2>/dev/null
for slug in full-r2-q38q3 full-r2-q38; do
  [ -e "/home/alex/v4_test/shop/$slug" ] || [ -e "$V/stash/shop/$slug" ] && { echo "== СТОП: каталог сайту $slug уже існує"; exit 1; }
done
f=$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null | grep -v -e llama -e lmstudio)
[ -n "$f" ] && { echo "== СТОП: на відеокарті чужий процес: $(echo $f)"; exit 1; }
free=$(df -BG --output=avail / | tail -1 | tr -dc 0-9); [ "$free" -lt 30 ] && { echo "== СТОП: на диску $free ГБ — потрібно ≥ 30 (docker builder prune -af)"; exit 1; }
grep -q 'OPENCODE_DISABLE_CLAUDE_CODE=1' "$V/run-v4.sh" || { echo "== СТОП: run-v4.sh без OPENCODE_DISABLE_CLAUDE_CODE"; exit 1; }
claude auth status >/dev/null 2>&1 || echo "== УВАГА: claude не залогінений — сліпа рецензія в кінці не відпрацює (claude auth login або claude setup-token)"
echo "== моделі: qwen3.8 27B UD-Q3_K_XL → UD-IQ4_XS, обидві з нуля (каталоги full-r2-*)"
echo "== рівні умови: tools/fit-equal.sh — $("$V/tools/fit-equal.sh" "$RULES" "$RUNS" --dry | sed -n 2p | sed 's/^== --dry: //')"
echo "== етапи: $(cut -d'|' -f1 "$V/stages-shop-split5.txt" | tr '\n' ' '); STAGE_CAP=18000, LAST_SUB=c, SHOP_BUDGET=604800"
echo "== після прогону: qa/analyze-shop.sh (приймальна перевірка, Stryker, сліпа рецензія) → archive/full-shop-r2-<час>/analysis/"
echo "== диск: $free ГБ; на відеокарті зараз: $(nvidia-smi --query-gpu=memory.used --format=csv,noheader) (LM Studio буде вивантажено)"
[ $DRY = 1 ] && { echo "== --dry: нічого не запущено"; exit 0; }
setsid nohup "$V/tools/read-guard.py" > "$V/archive/read-guard.out" 2>&1 &
guard=$!
nohup bash -c '
V=/home/alex/v4_stand; RUNS="'"$RUNS"'"; RULES="'"$RULES"'"
hj=(); command -v hubjob >/dev/null && hj=(hubjob --тиша 40 --назва)
echo "== $(date "+%F %T") 0) рівні умови"
"${hj[@]}" "r2: підбір рівних умов" -- "$V/tools/fit-equal.sh" "$RULES" "$RUNS" || { echo "== СТОП: рівні умови не підібрано"; exit 1; }
cat "$RUNS"
echo "== $(date "+%F %T") 1) прогін"
hj1=(); command -v hubjob >/dev/null && hj1=(hubjob --назва "стенд shop r2 (рівні умови)" --тиша 30 --журнал "$V/logs/proxy.tsv" --)
MODEL_RULES="$RULES" TASKS=shop SHOP_BUDGET=604800 STAGE_CAP=18000 LAST_SUB=c STAGES_FILE="$V/stages-shop-split5.txt" \
  RUNS_FILE="$RUNS" "${hj1[@]}" "$V/run-v4.sh" > "$V/logs/run.out" 2>&1
kill '"$guard"' 2>/dev/null
a="$V/archive/full-shop-r2-$(date +%F-%H%M)"; mkdir -p "$a/sites" && mv "$V/logs" "$a/logs" && mkdir -p "$V/logs"
mv "$V/stash/shop/"full-r2-* "$a/sites/" 2>/dev/null; cp -a "$V/archive/read-guard.out" "$RUNS" "$a/" 2>/dev/null; cp -a "$RULES" "$a/model-rules-r2" 2>/dev/null
echo "== $(date "+%F %T") 2) архів: $a"
echo "== $(date "+%F %T") 3) аналіз"
"${hj[@]}" "r2: аналіз сайтів (accept, Stryker, сліпа рецензія)" -- "$V/qa/analyze-shop.sh" "$a/analysis" "$a/sites/full-r2-q38q3" "$a/sites/full-r2-q38"
echo "== $(date "+%F %T") готово: $a/analysis/summary.json"
' > "$V/archive/full-shop-launch.out" 2>&1 &
echo "запущено (PID $!): журнал ланцюжка — archive/full-shop-launch.out, прогону — logs/run.out; сторож — PID $guard"
