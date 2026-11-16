#!/bin/bash
# 17.11 (слово користувача, п. 3 аналізу): знеособлені копії двох сайтів для сліпої рецензії коду.
#   qa/blind-prep.sh <сайт 1> <сайт 2> <каталог рецензії> <файл відповідності>
# Робить <каталог>/{A,B} у випадковому порядку (відповідність — лише у <файл відповідності>, поза каталогом рецензії),
# кладе поруч ТЗ і RUBRIC.md (qa/blind-rubric.md). Прибирає все, що видає модель чи процес:
# git-історію, docs/PROGRESS.md і PLAN.md (журнал етапів), макети, згенеровані картинки, скриншоти, package-lock,
# бінарники (замінено описом); шляхи стенду в текстах → нейтральні. Наприкінці шукає залишки й зупиняється, якщо є.
set -u
S1=$(readlink -f "${1:?сайт 1}"); S2=$(readlink -f "${2:?сайт 2}"); R=$(readlink -m "${3:?каталог рецензії}"); MAP=$(readlink -m "${4:?файл відповідності}")
V=/home/alex/v4_stand; INPUTS=/home/alex/v4_test/inputs/shop
[ -e "$R" ] && { echo "== СТОП: $R уже існує"; exit 1; }
case "$MAP" in "$R"/*) echo "== СТОП: файл відповідності не може лежати в каталозі рецензії"; exit 1;; esac
mkdir -p "$R" "$(dirname "$MAP")"
order=$(python3 -c "import random,sys; l=sys.argv[1:]; random.SystemRandom().shuffle(l); print(' '.join(l))" "$S1" "$S2")
set -- $order
echo "A=$1 B=$2 ($(date '+%F %T'))" > "$MAP"
for pair in "A $1" "B $2"; do
  set -- $pair; L=$1; src=$2; dst="$R/$L"; mkdir -p "$dst"
  (cd "$src" && git ls-files 2>/dev/null || (cd "$src" && find . -type f -not -path './node_modules/*' -not -path './.git/*' | sed 's#^\./##')) \
    | grep -vE '^docs/(PROGRESS|PLAN)\.md$|^docs/design/|package-lock\.json$|^apps/web/public/images/|\.(png|jpe?g|svg|webp)$|^docs/screenshots/|^\.stand/' \
    | while IFS= read -r f; do
        mkdir -p "$dst/$(dirname "$f")"
        if file -b --mime-encoding "$src/$f" | grep -q binary; then echo "(бінарний файл $(basename "$f"), $(stat -c %s "$src/$f") байт)" > "$dst/$f.txt"
        else cp "$src/$f" "$dst/$f"; fi
      done
  # шляхи стенду й назви каталогів сайтів → нейтральні
  slug=$(basename "$src")
  grep -rlE "$slug|v4_test|v4_stand|/tmp/opencode" "$dst" 2>/dev/null | xargs -r sed -i -E \
    "s#/home/alex/v4_test/shop/[A-Za-z0-9_-]+#~/cybersphere#g; s#/home/alex/v4_test/inputs/shop#<вхідні матеріали>#g; s#\\b$slug\\b#cybersphere#g; s#/tmp/opencode#/tmp/agent#g"
done
cp "$INPUTS/TZ.md" "$INPUTS/landing-structure.txt" "$INPUTS/mockups-description.md" "$R/"
sed -i 's#/home/alex/v4_test/inputs/shop/#./ (поруч із цим файлом)#' "$R/TZ.md"
cp "$V/qa/blind-rubric.md" "$R/RUBRIC.md"
left=$(grep -rliE 'qwen|q3_k|iq4_|gemma|gpt-oss|opencode|v4_stand|v4_test|full-q|claude|anthropic|stand_[a-z]|stage-check' "$R" 2>/dev/null)
[ -n "$left" ] && { echo "== СТОП: лишились сліди моделі чи стенду:"; echo "$left"; exit 1; }
for L in A B; do echo "== $L: $(find "$R/$L" -type f | wc -l) файлів, $(du -sh "$R/$L" | cut -f1)"; done
echo "== відповідність: $MAP (рецензентові не показувати)"
