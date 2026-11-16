#!/bin/bash
# 17.11 (слово користувача): повний аналіз пари сайтів «магазин» після прогону — три незалежні методи.
#   qa/analyze-shop.sh <вихідний каталог> <сайт 1> <сайт 2>
# Для кожного сайту по черзі (однакові імена образів у compose — тому по одному, з --build і down -v):
#   1) приймальна перевірка в браузері (qa/accept-shop.mjs) і через API (qa/accept-shop-api.sh);
#   2) мутаційне тестування (qa/mutation-shop.sh) — API на справжньому Postgres + web lib;
# потім для пари: 3) сліпа рецензія (qa/blind-review.sh, свіжий `claude -p`, лише знеособлені копії).
# Підсумок — <вихідний>/summary.json і короткий друк.
set -u
V=/home/alex/v4_stand; OUT=$(readlink -m "${1:?вихідний каталог}"); shift
[ $# -eq 2 ] || { echo "== потрібно два сайти"; exit 1; }
mkdir -p "$OUT"; PW=""
for s in "$@" "$V"/archive/*/sites/*; do [ -d "$s/node_modules/playwright" ] && { PW="$s/node_modules/playwright"; break; }; [ -d "$s/e2e/node_modules/playwright" ] && { PW="$s/e2e/node_modules/playwright"; break; }; done
[ -n "$PW" ] || { echo "== СТОП: не знайдено playwright"; exit 1; }

newest() {  # назва «найновішої гри» з DECISIONS/README сайту (ТЗ §1 вимагає її записати)
  grep -hiE 'найнов' "$1/docs/DECISIONS.md" "$1/README.md" 2>/dev/null | grep -oE '«[^»]{4,60}»' | tr -d '«»' \
    | grep -vE 'За датою|новіші|найнов|Придбати|Gaming|Featured' | head -1
}
api_variant() {  # a — /api/cart/items {gameSlug}; b — /api/cart {slug}
  grep -rqE "['\"]/api/cart/items['\"]" "$1/apps/api/src" && echo a || echo b
}
pay_method() {  # перше значення enum способу оплати з коду API (card / CARD_DEMO …)
  grep -rhoE "z\.enum\(\[\s*'[^']+'" "$1/apps/api/src" | grep -iE "card" | head -1 | grep -oE "'[^']+'" | tr -d "'"
}

for site in "$@"; do
  site=$(readlink -f "$site"); name=$(basename "$site"); o="$OUT/$name"; mkdir -p "$o/shots"
  echo "== $(date '+%F %T') $name: підйом з нуля"
  ( cd "$site" && docker compose down -v >/dev/null 2>&1; docker compose up --build -d ) > "$o/compose-up.log" 2>&1
  t0=$(date +%s); for _ in $(seq 120); do [ "$(curl -s -o /dev/null -w '%{http_code}' localhost:8088/api/health)" = 200 ] && break; sleep 2; done
  echo "   health за $(( $(date +%s) - t0 )) с; найновіша гра: «$(newest "$site")»; API-варіант $(api_variant "$site"), оплата $(pay_method "$site")"
  PW="$PW" NEWEST="$(newest "$site")" SHOTS="$o/shots" timeout 900 node "$V/qa/accept-shop.mjs" http://localhost:8088 "$o/accept.json" > "$o/accept.txt" 2>&1
  ( cd "$site" && PM="$(pay_method "$site")" timeout 600 "$V/qa/accept-shop-api.sh" "$(api_variant "$site")" ) > "$o/accept-api.txt" 2>&1
  echo "   $(tail -1 "$o/accept.txt"); $(tail -1 "$o/accept-api.txt")"
  ( cd "$site" && docker compose down -v ) >/dev/null 2>&1
  "$V/qa/mutation-shop.sh" "$site" "$o/mutation" all > "$o/mutation.txt" 2>&1
  grep '^== \(api\|web\): mutation' "$o/mutation.txt" | sed 's/^/   /'
done

"$V/qa/blind-review.sh" "$1" "$2" "$OUT/blind-review" > "$OUT/blind-review.txt" 2>&1
tail -1 "$OUT/blind-review.txt"

python3 - "$OUT" "$@" <<'EOF'
import json, os, sys
out, sites = sys.argv[1], sys.argv[2:]
res = {}
for s in sites:
    n = os.path.basename(os.path.realpath(s)); o = os.path.join(out, n); r = {}
    try: a = json.load(open(os.path.join(o, "accept.json"))); r["accept"] = {k: a[k] for k in ("ok", "minor", "fail", "total")}
    except Exception: pass
    try: r["accept_api"] = open(os.path.join(o, "accept-api.txt")).read().strip().splitlines()[-1]
    except Exception: pass
    try: m = json.load(open(os.path.join(o, "mutation", "summary.json"))); r["mutation"] = {p: {k: m[p].get(k) for k in ("score", "score_covered", "mutants", "survived", "no_coverage")} for p in m}
    except Exception: pass
    res[n] = r
try: res["blind_review"] = json.load(open(os.path.join(out, "blind-review", "summary.json")))
except Exception: pass
json.dump(res, open(os.path.join(out, "summary.json"), "w"), ensure_ascii=False, indent=1)
print(json.dumps(res, ensure_ascii=False, indent=1)[:3000])
EOF
