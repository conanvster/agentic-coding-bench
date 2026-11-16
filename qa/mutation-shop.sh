#!/bin/bash
# 17.11 (слово користувача, п. 2 аналізу): мутаційне тестування сайту «магазин» — чи ловлять тести моделі справжні помилки.
# Stryker вносить у код сотні дрібних помилок (>= → >, + → -, умова → true, рядок → "") і запускає тести моделі:
# мутант «убито», якщо хоч один тест упав. Mutation score = убиті / (убиті + вижилі + без покриття).
#
#   qa/mutation-shop.sh <каталог сайту> <вихідний каталог> [api|web|all]
#
# Що мутуємо (однаково для всіх моделей, незалежно від структури):
#   api — увесь apps/api/src, крім точок входу й підключення до БД (main/server/db); тести — усі тести API моделі
#         (unit + інтеграційні) на справжньому Postgres у тимчасовому контейнері; паралельність 1 (спільна БД).
#   web — apps/web/src/lib (стан каталогу, API-клієнт, форматування); тести — усі тести вебчастини (jsdom).
# Каталог сайту не змінюється: робота — у копії <вихідний>/work (видаляється в кінці, лишаються звіти).
# Вихід: <вихідний>/{api,web}/mutation.json (+ html), summary.json, stryker-*.log.
set -u
SITE=$(readlink -f "${1:?каталог сайту}"); OUT=$(readlink -m "${2:?вихідний каталог}"); WHAT="${3:-all}"
[ -f "$SITE/package.json" ] || { echo "== СТОП: $SITE — не сайт (нема package.json)"; exit 1; }
mkdir -p "$OUT"; W="$OUT/work"; rm -rf "$W"
PORT=$((55400 + RANDOM % 90)); PG="stryker-pg-$$"
cleanup() { docker rm -f "$PG" >/dev/null 2>&1; rm -rf "$W"; }
trap cleanup EXIT

echo "== $(date '+%F %T') копія сайту → $W"
rsync -a --exclude .git --exclude coverage --exclude 'test-results' --exclude 'playwright-report' "$SITE/" "$W/" || exit 1
cd "$W" || exit 1

# Розкладка: тести API як vitest-проєкт (корінь з include apps/api/test або apps/api/vitest.config.ts)
if [ -f apps/api/vitest.config.ts ]; then API_CFG=apps/api/vitest.config.ts; API_DIR=apps/api; else API_CFG=vitest.config.ts; API_DIR=.; fi
if [ -f apps/web/vitest.config.ts ]; then WEB_CFG=apps/web/vitest.config.ts; WEB_DIR=apps/web; else WEB_CFG=vitest.config.ts; WEB_DIR=.; fi

echo "== Stryker (тимчасово, без запису в package.json сайту)"
npm i --no-save --no-audit --no-fund --loglevel=error @stryker-mutator/core@9 @stryker-mutator/vitest-runner@9 >"$OUT/npm-stryker.log" 2>&1 \
  || { echo "== СТОП: не встановився Stryker (див. $OUT/npm-stryker.log)"; exit 1; }

summary() { python3 - "$1" "$2" <<'EOF'
import json, sys, collections
f, part = sys.argv[1], sys.argv[2]
try: d = json.load(open(f))
except Exception as e: print(json.dumps({"part": part, "error": str(e)})); sys.exit()
c = collections.Counter(); per = {}
for path, fi in d.get("files", {}).items():
    k = collections.Counter(m["status"] for m in fi["mutants"]); c.update(k)
    det = k["Killed"] + k["Timeout"]; valid = det + k["Survived"] + k["NoCoverage"]
    per[path] = {"mutants": valid, "score": round(100 * det / valid, 1) if valid else None, "survived": k["Survived"], "no_coverage": k["NoCoverage"]}
det = c["Killed"] + c["Timeout"]; valid = det + c["Survived"] + c["NoCoverage"]; cov = det + c["Survived"]
print(json.dumps({"part": part, "mutants": valid, "killed": c["Killed"], "timeout": c["Timeout"], "survived": c["Survived"],
                  "no_coverage": c["NoCoverage"], "errors": c["CompileError"] + c["RuntimeError"], "ignored": c["Ignored"],
                  "score": round(100 * det / valid, 1) if valid else None,
                  "score_covered": round(100 * det / cov, 1) if cov else None, "files": per}, ensure_ascii=False))
EOF
}

run_part() {  # $1 — api|web
  local part=$1 cfg dir mutate conc
  if [ "$part" = api ]; then cfg=$API_CFG; dir=$API_DIR; conc=1
    mutate='["apps/api/src/**/*.ts", "!apps/api/src/**/{main,server,db,index}.ts", "!apps/api/src/lib/db.ts", "!apps/api/src/**/*.d.ts"]'
  else cfg=$WEB_CFG; dir=$WEB_DIR; conc=4
    mutate='["apps/web/src/lib/**/*.{ts,tsx}", "!apps/web/src/lib/{setup,test-utils,setupTests}.{ts,tsx}", "!apps/web/src/**/*.test.{ts,tsx}", "!apps/web/src/**/*.d.ts"]'
  fi
  # спільний кореневий конфіг (тести api і web разом) → окремий конфіг лише з тестами цієї частини
  if [ "$dir" = . ]; then
    local inc; [ "$part" = api ] && inc="['apps/api/test/**/*.{spec,test}.ts', 'scripts/*.spec.ts']" || inc="['apps/web/src/**/*.test.{ts,tsx}', 'apps/web/test/**/*.test.{ts,tsx}']"
    cat > "vitest.stryker-$part.config.ts" <<EOV
import base from './$(basename "$cfg")';
const b: any = base;
export default { ...b, test: { ...b.test, include: $inc, coverage: { enabled: false } } };
EOV
    cfg="vitest.stryker-$part.config.ts"
  else
    # окремий конфіг застосунку (apps/<частина>/vitest.config.ts): Stryker однаково запускаємо з кореня репозиторію —
    # пісочниця має містити весь проєкт (тести можуть читати файли відносно кореня, як hero-perf.test.tsx 17.11);
    # обгортка ставить root на каталог застосунку (відносно cwd пісочниці), щоб include/setupFiles лишились чинні
    cat > "vitest.stryker-$part.config.ts" <<EOV
import base from './$cfg';
const b: any = base;
export default { ...b, root: '$dir', test: { ...b.test, coverage: { enabled: false } } };
EOV
    cfg="vitest.stryker-$part.config.ts"; dir=.
  fi
  # шляхи mutate — відносно кореня Stryker (каталог конфігу vitest)
  local rel=""; [ "$dir" != . ] && rel="$dir/"
  local m; m=$(python3 -c "import json,sys; r=sys.argv[2]; print(json.dumps([('!' if p.startswith('!') else '') + p.lstrip('!').replace(r,'',1) if r else p for p in json.loads(sys.argv[1])]))" "$mutate" "$rel")
  cat > "$dir/stryker.$part.json" <<EOF
{ "\$schema": "./node_modules/@stryker-mutator/core/schema/stryker-schema.json",
  "testRunner": "vitest", "vitest": { "configFile": "$(basename "$cfg")", "related": false },
  "plugins": ["$W/node_modules/@stryker-mutator/vitest-runner/dist/src/index.js"],
  "mutate": $m, "coverageAnalysis": "perTest", "concurrency": $conc,
  "timeoutMS": 30000, "timeoutFactor": 3, "ignoreStatic": true, "disableTypeChecks": true,
  "reporters": ["json", "html", "clear-text"],
  "jsonReporter": { "fileName": "$OUT/$part/mutation.json" }, "htmlReporter": { "fileName": "$OUT/$part/mutation.html" },
  "tempDirName": ".stryker-tmp-$part", "cleanTempDir": "always" }
EOF
  mkdir -p "$OUT/$part"
  echo "== $(date '+%F %T') Stryker $part (конфіг $dir/stryker.$part.json, vitest $cfg)"
  (cd "$dir" && "$W/node_modules/.bin/stryker" run "stryker.$part.json") > "$OUT/stryker-$part.log" 2>&1
  local rc=$?
  echo "== $(date '+%F %T') $part: код $rc; $(grep -E 'All files' "$OUT/stryker-$part.log" | tail -1)"
  summary "$OUT/$part/mutation.json" "$part" > "$OUT/$part/summary.json"
}

if [ "$WHAT" != web ]; then
  echo "== Postgres для інтеграційних тестів: контейнер $PG, порт $PORT"
  docker run -d --name "$PG" -e POSTGRES_USER=cybersphere -e POSTGRES_PASSWORD=pw -e POSTGRES_DB=cybersphere_test \
    -p 127.0.0.1:$PORT:5432 postgres:16-alpine >/dev/null || exit 1
  for _ in $(seq 60); do docker exec "$PG" pg_isready -U cybersphere -d cybersphere_test >/dev/null 2>&1 && break; sleep 1; done; sleep 2
  export DATABASE_URL="postgresql://cybersphere:pw@127.0.0.1:$PORT/cybersphere_test"
  export TEST_DATABASE_URL="$DATABASE_URL" NODE_ENV=test LOG_LEVEL=silent
  schema=$(ls apps/api/prisma/schema.prisma)
  npx prisma generate --schema "$schema" >"$OUT/db-prepare.log" 2>&1
  npx prisma migrate deploy --schema "$schema" >>"$OUT/db-prepare.log" 2>&1 || { echo "== СТОП: міграції не застосувались (див. $OUT/db-prepare.log)"; exit 1; }
  # сід, як у make test моделі (якщо тести на нього спираються)
  if [ -f apps/api/prisma/seed.ts ]; then (npx tsx apps/api/prisma/seed.ts || (cd apps/api && npx tsx prisma/seed.ts)) >>"$OUT/db-prepare.log" 2>&1; fi
  echo "== сухий прогін тестів API без мутацій"
  (cd "$API_DIR" && npx vitest run --config "$(basename "$API_CFG")" $( [ "$API_DIR" = . ] && echo apps/api/test )) >"$OUT/api-dryrun.log" 2>&1
  echo "   $(grep -E 'Tests +[0-9]' "$OUT/api-dryrun.log" | tail -1 | sed 's/\x1b\[[0-9;]*m//g')"
  run_part api
fi
[ "$WHAT" != api ] && run_part web
python3 - "$OUT" <<'EOF'
import json, sys, os
o = sys.argv[1]; r = {}
for p in ("api", "web"):
    f = os.path.join(o, p, "summary.json")
    if os.path.exists(f):
        try: r[p] = json.load(open(f))
        except Exception: pass
json.dump(r, open(os.path.join(o, "summary.json"), "w"), ensure_ascii=False, indent=1)
for p, s in r.items():
    print(f"== {p}: mutation score {s.get('score')} % (у покритому коді {s.get('score_covered')} %), мутантів {s.get('mutants')}, вижило {s.get('survived')}, без покриття {s.get('no_coverage')}")
EOF
