#!/bin/bash
# 17.11 (слово користувача, п. 3 аналізу): сліпа рецензія коду двох сайтів свіжим рецензентом (Claude Code, `claude -p`).
#   qa/blind-review.sh <сайт 1> <сайт 2> <вихідний каталог>
# 1) qa/blind-prep.sh → /home/alex/blind-review-<час>/{A,B} (випадковий порядок), відповідність — <вихідний>/mapping.txt.
# 2) Рецензент запускається з робочим каталогом рецензії: пам'ять Claude прив'язана до каталогу (тут її немає),
#    читати можна лише ./** (dontAsk + дозволи за шляхом), стенд, архів, сайти, ~/.claude — заборонені явно;
#    Bash, запис, мережа — заборонені. Перевірено 17.11: читання /home/alex/v4_stand/README.md відхилено.
# 3) Звіт → <вихідний>/report.md; лише після цього до нього дописується відповідність A/B → моделі.
# Потрібен дійсний вхід `claude` (OAuth). Для довгих нічних ланцюжків — `claude setup-token`.
set -u
V=/home/alex/v4_stand
S1=$(readlink -f "${1:?сайт 1}"); S2=$(readlink -f "${2:?сайт 2}"); OUT=$(readlink -m "${3:?вихідний каталог}")
MODEL="${REVIEW_MODEL:-opus}"
mkdir -p "$OUT"; R="/home/alex/blind-review-$(date +%Y%m%d-%H%M%S)"
"$V/qa/blind-prep.sh" "$S1" "$S2" "$R" "$OUT/mapping.txt" || exit 1
PROMPT='Ти — незалежний досвідчений рецензент коду (TypeScript, React, Fastify, Prisma, тестування). Виконай сліпу порівняльну рецензію двох рішень однієї задачі.
У поточному каталозі: RUBRIC.md — шкала, критерії й обов'"'"'язковий формат відповіді (прочитай першою і дотримуйся точно); TZ.md, landing-structure.txt, mockups-description.md — технічне завдання; A/ і B/ — два рішення.
Правила: читай лише файли в поточному каталозі; не намагайся з'"'"'ясувати, хто автор. Прочитай код по-справжньому: доменну логіку API (ціни, промокоди, кешбек, фільтри й фасети, замовлення, ідемпотентність, сесія), ключові компоненти фронтенду, тести (unit, integration, e2e), Dockerfile/compose/Makefile. Кожну оцінку й ваду підтверджуй посиланням шлях:рядок (відносно поточного каталогу, напр. A/apps/api/src/x.ts:42) і перевір, що рядок справді містить те, на що посилаєшся. Будь однаково прискіпливим до обох; якщо щось не знайшов — так і пиши.
Поверни повний звіт у форматі з RUBRIC.md (Markdown, українською). Звіт — це вся твоя фінальна відповідь.'
echo "== $(date '+%F %T') рецензент ($MODEL) у $R"
( cd "$R" && timeout 5400 claude -p --model "$MODEL" --no-session-persistence --permission-mode dontAsk \
    --allowedTools "Read(./**)" "Grep(./**)" "Glob(./**)" \
    --disallowedTools "Read(/home/alex/v4_stand/**)" "Read(/home/alex/v4_test/**)" "Read(/home/alex/.claude/**)" \
      "Grep(/home/alex/v4_stand/**)" "Grep(/home/alex/v4_test/**)" "Glob(/home/alex/v4_stand/**)" "Glob(/home/alex/v4_test/**)" \
      Bash Write Edit NotebookEdit WebFetch WebSearch Agent \
    -- "$PROMPT" ) > "$OUT/report.md" 2> "$OUT/review.err"
rc=$?
grep -q '^# ' "$OUT/report.md" || { echo "== ПОМИЛКА: рецензент не повернув звіт (код $rc), див. $OUT/review.err"; exit 1; }
{ echo; echo "---"; echo "**Відповідність (відкрито після рецензії):** $(cat "$OUT/mapping.txt")"; } >> "$OUT/report.md"
# підсумкові бали з таблиці критеріїв → summary.json
python3 - "$OUT/report.md" "$OUT/mapping.txt" > "$OUT/summary.json" <<'EOF'
import re, sys, json
t = open(sys.argv[1]).read(); m = open(sys.argv[2]).read()
rows = re.findall(r'^\|\s*(\d+)\.\s*([^|]+?)\s*\|\s*(\d)\s*\|\s*(\d)\s*\|', t, re.M)
mp = dict(re.findall(r'([AB])=(\S+)', m))
a = sum(int(r[2]) for r in rows); b = sum(int(r[3]) for r in rows)
print(json.dumps({"A": mp.get("A"), "B": mp.get("B"), "criteria": [{"n": int(r[0]), "name": r[1], "A": int(r[2]), "B": int(r[3])} for r in rows],
                  "sum_A": a, "sum_B": b}, ensure_ascii=False, indent=1))
EOF
rm -rf "$R"
echo "== $(date '+%F %T') звіт: $OUT/report.md; бали: $(python3 -c "import json;d=json.load(open('$OUT/summary.json'));print(d['A'].split('/')[-1],d['sum_A'],':',d['sum_B'],d['B'].split('/')[-1])")"
