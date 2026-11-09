#!/bin/bash
# 09.11 (слово користувача): етапний тест — лише етап 3 сайту (схема БД, міграції, детермінований сід ≥ 40 ігор,
# генератор зображень) зі спільної бази етапів 0–2 (bases/shop-0-2, зроблена Claude, перевірки 0–2 зелені).
# 4 моделі × 2 варіанти налаштувань (base — model-rules/, tuned — model-rules-tuned/) × 2 повтори = 16 прогонів.
# Час не обмежено (слово користувача): бюджет і ліміт етапу — 24 год як запобіжник; модель працює, доки сама не закінчить.
# Перевірку етапу 3 не посилено (слово користувача) — якість схеми, сіду й генератора аналізує Claude після прогону.
# Запуск з `su - alex`: ./start-stage3.sh   (VARIANTS="base" — лише один варіант)
V=/home/alex/v4_stand
[ -s "$V/logs/run.out" ] && { echo "== СТОП: logs/ не порожній"; exit 1; }
for p in /proc/[0-9]*; do case "$(tr '\0' ' ' < $p/cmdline 2>/dev/null)" in *"run-""v4.sh"*) echo "== СТОП: іде прогін"; exit 1;; esac; done
f=$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null | grep -v -e llama -e lmstudio)
[ -n "$f" ] && { echo "== СТОП: на відеокарті чужий процес: $(echo $f)"; exit 1; }
[ -f "$V/model-rules-tuned/ГОТОВО" ] || { echo "== СТОП: model-rules-tuned/ ще не налаштовано за заміром bench-tune (немає файлу ГОТОВО)"; exit 1; }
nohup bash -c '
V=/home/alex/v4_stand
for variant in ${VARIANTS:-base tuned}; do
  rules="$V/model-rules"; [ "$variant" = tuned ] && rules="$V/model-rules-tuned"
  runs="$V/runs-stage3-$variant.txt"
  : > "$runs"
  for r in 1 2; do
    echo "qwen3.6-35b-a3b|s3-q2-$variant-r$r|131072" >> "$runs"
    echo "qwen3.6-35b-a3b@ud-q4_k_xl|s3-q4-$variant-r$r|131072" >> "$runs"
    echo "flint@ud-q4_k_xl|s3-flint-$variant-r$r|131072" >> "$runs"
    echo "qwen3.8-27b@iq4_xs|s3-q38-$variant-r$r|69632" >> "$runs"
  done
  MODEL_RULES="$rules" BASE_DIR="$V/bases/shop-0-2" START_STAGE=3 STAGES_FILE="$V/stages-shop-only3.txt" \
  TASKS=shop SHOP_BUDGET=86400 STAGE_CAP=86400 RUNS_FILE="$runs" \
  EXTRA_NOTE="Етапи 0–2 уже виконано (план, перелік функцій, рішення, каркас монорепо, Docker, make test) — продовжуй з етапу 3; прочитай docs/PLAN.md, docs/DECISIONS.md і код каркаса." \
    "$V/run-v4.sh" > "$V/logs/run.out" 2>&1
  a="$V/archive/stage3-$variant-$(date +%F-%H%M)"; mkdir -p "$a" && mv "$V/logs" "$a/logs" && mkdir -p "$V/logs"
  mkdir -p "$a/sites" && mv "$V/stash/shop/"s3-*-"$variant"-r* "$a/sites/" 2>/dev/null
done
' > "$V/archive/stage3-launch.out" 2>&1 &
echo "запущено (PID $!): варіанти ${VARIANTS:-base tuned}; журнал — logs/run.out, сповіщення — на телефон"
