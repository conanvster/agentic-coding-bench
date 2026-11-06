#!/usr/bin/env bash
# Перевірка претесту ззовні: збирає образ агента, запускає на вільному порту, звіряє відповіді
# (числа, яких немає в ТЗ, щоб не пройшла відповідь «зашита» під 4+5), прибирає за собою.
set -u
tag="pretest-$(basename "$PWD" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9.-]/-/g')"
port=18099
fail=0
say() { echo "$1"; }
docker rm -f "$tag" >/dev/null 2>&1
docker build -q -t "$tag" . >/dev/null 2>build.err || { say "docker build не пройшов:"; tail -15 build.err; exit 1; }
rm -f build.err
docker run -d --rm --name "$tag" -p "$port:8099" "$tag" >/dev/null || { say "docker run не пройшов"; exit 1; }
for i in $(seq 1 30); do curl -s -o /dev/null "http://localhost:$port/sum?num1=1&num2=1" && break; sleep 1; done
check() {  # запит, очікуваний код, python-вираз над JSON d
  out=$(curl -s -w '\n%{http_code}' "http://localhost:$port$1"); code=${out##*$'\n'}; body=${out%$'\n'*}
  if [ "$code" != "$2" ] || ! python3 -c "import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if ($3) else 1)" "$body" 2>/dev/null; then
    say "НІ  $1 → код $code, тіло $body (очікувано код $2, умова: $3)"; fail=1
  else say "так $1 → $body"; fi
}
check "/sum?num1=4&num2=5" 200 'd.get("rez") == 9'
check "/sum?num1=17&num2=25" 200 'd.get("rez") == 42'
check "/sum?num1=-3&num2=1.5" 200 'abs(float(d.get("rez")) + 1.5) < 1e-9'
check "/sum?num1=abc&num2=5" 400 '"error" in d'
check "/sum?num1=4" 400 '"error" in d'
code=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$port/nope"); [ "$code" = 404 ] && say "так /nope → 404" || { say "НІ  /nope → $code (очікувано 404)"; fail=1; }
user=$(docker exec "$tag" id -u 2>/dev/null); [ -n "$user" ] && [ "$user" != 0 ] && say "так процес не від root (uid $user)" || { say "НІ  процес у контейнері від root"; fail=1; }
docker rm -f "$tag" >/dev/null 2>&1
tout=$(bash run_tests.sh 2>&1); trc=$?
n=$(grep -oE '(Ran|collected) [0-9]+|[0-9]+ passed' <<< "$tout" | grep -oE '[0-9]+' | sort -n | tail -1)
if [ "$trc" = 0 ] && [ "${n:-0}" -ge 5 ]; then say "так run_tests.sh: $n тестів"; else say "НІ  run_tests.sh: код $trc, тестів ${n:-0} (потрібно ≥ 5)"; tail -8 <<< "$tout"; fail=1; fi
exit $fail
