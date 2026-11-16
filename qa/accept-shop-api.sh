#!/bin/bash
# 16.11: серверні вимоги ТЗ магазину через HTTP — доповнення до accept-shop.mjs (браузер).
#   qa/accept-shop-api.sh <варіант API: a|b> [BASE]     a — /api/cart/items {gameSlug}, payMethod; b — /api/cart {slug}, paymentMethod
# Перевіряє: ціни з клієнта ігноруються, ідемпотентність POST /api/orders, порожній кошик → відмова,
# rate-limit промокодів і підписки, маскування ключів/email у логах api, Postgres не опублікований назовні.
V="${1:?a|b}"; B="${2:-http://localhost:8088}"; J=$(mktemp -d); ok=0; all=0
r() { all=$((all+1)); if [ "$2" = 1 ]; then ok=$((ok+1)); echo "✓ $1${3:+ — $3}"; else echo "✗ $1${3:+ — $3}"; fi; }
c() { curl -s -b "$J/ck" -c "$J/ck" "$@"; }
if [ "$V" = a ]; then add='{"gameSlug":"neon-horizon-2088","platform":"Steam","priceCents":1,"discountPct":99}'; addp=/api/cart/items; pm='"payMethod":"card"'
else add='{"slug":"neon-horizon-2088","platform":"Steam","priceCents":1,"discountPct":99}'; addp=/api/cart; pm="\"paymentMethod\":\"${PM:-CARD_DEMO}\""; fi
c "$B/api/cart" >/dev/null
code=$(c -o "$J/add" -w '%{http_code}' -H 'content-type: application/json' -d "$add" "$B$addp")
cart=$(c "$B/api/cart"); tot=$(echo "$cart" | grep -oE '"(totalCents|payableCents|grandTotalCents|toPayCents)":[0-9]+' | head -1 | grep -oE '[0-9]+$')
want=$(curl -s "$B/api/games/neon-horizon-2088" | grep -oE '"(priceCents|currentPriceCents)":[0-9]+' | head -1 | grep -oE '[0-9]+$')
r "ціни з клієнта ігноруються (priceCents:1 у запиті)" $([ "${code:0:1}" = 2 ] && [ -n "$want" ] && [ "$tot" = "$want" ] && echo 1) "додавання $code; у кошику $tot, ціна гри в API $want"
key="acc-$(date +%s%N)"; body="{\"email\":\"buyer@example.com\",$pm}"
o1=$(c -H 'content-type: application/json' -H "Idempotency-Key: $key" -d "$body" "$B/api/orders"); o2=$(c -H 'content-type: application/json' -H "Idempotency-Key: $key" -d "$body" "$B/api/orders")
n1=$(echo "$o1" | grep -oE 'CS-2026-[0-9]{6}' | head -1); n2=$(echo "$o2" | grep -oE 'CS-2026-[0-9]{6}' | head -1)
r "Idempotency-Key: повтор дає те саме замовлення" $([ -n "$n1" ] && [ "$n1" = "$n2" ] && echo 1) "$n1 / $n2"
key2="acc2-$(date +%s%N)"; e=$(c -o /dev/null -w '%{http_code}' -H 'content-type: application/json' -H "Idempotency-Key: $key2" -d "$body" "$B/api/orders")
r "порожній кошик → відмова (4xx)" $([ "${e:0:1}" = 4 ] && echo 1) "$e"
k=$(echo "$o1" | grep -oE 'DEMO-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}' | head -1)
logs=$(docker compose logs api 2>/dev/null)
leak=0; [ -n "$k" ] && echo "$logs" | grep -qF "$k" && leak=1; echo "$logs" | grep -qF 'buyer@example.com' && leak=$((leak+2))
r "у логах api немає повного ключа й email" $([ -n "$k" ] && [ $leak = 0 ] && echo 1) "ключ ${k:-не отримано}; витік=$leak (1 ключ, 2 email)"
v=$(c -o /dev/null -w '%{http_code}' -H 'content-type: application/json' -d '{"email":"x"}' "$B/api/subscriptions")
r "сервер валідує email підписки (400/422 на «x», до перевірки rate-limit)" $(echo "$v" | grep -qE "^(400|422)$" && echo 1) "$v"
codes=""; for i in $(seq 40); do codes="$codes $(c -o /dev/null -w '%{http_code}' -H 'content-type: application/json' -d '{"code":"NOPE'$i'"}' "$B/api/cart/promo")"; done
r "rate-limit на промокоди (429 серед 40 запитів)" $(echo "$codes" | grep -q 429 && echo 1) "$(echo $codes | tr ' ' '\n' | sort | uniq -c | tr '\n' ' ')"
codes=""; for i in $(seq 40); do codes="$codes $(c -o /dev/null -w '%{http_code}' -H 'content-type: application/json' -d "{\"email\":\"rl$i-$RANDOM@example.com\"}" "$B/api/subscriptions")"; done
r "rate-limit на підписку (429 серед 40 запитів)" $(echo "$codes" | grep -q 429 && echo 1) "$(echo $codes | tr ' ' '\n' | sort | uniq -c | tr '\n' ' ')"
r "Postgres не опублікований на хост" $(docker compose ps --format '{{.Service}} {{.Ports}}' | awk '$1=="db"' | grep -q -- '->' || echo 1) "$(docker compose ps --format '{{.Service}}: {{.Ports}}' | tr '\n' ' ')"
echo "Підсумок API: $ok з $all"; rm -rf "$J"
