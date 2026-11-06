#!/bin/bash
# Для кожної моделі: копія результату → власні тести моделі → docker build/run → accept.py → прибирання.
Q=${Q:-$HOME/стенд-кодингу/opencode-v3/qa/out}; mkdir -p "$Q"
SRC=${SRC:?каталог з результатами моделей}
port=18101
for slug in ${SLUGS:-gpt-oss-20b qwen3.6-35b-a3b kat-coder-v2.5 gemma-4-26b-q4kxl gemma-4-12b-qat gemma-4-e4b}; do
  w=$Q/w/$slug; rm -rf "$w"; mkdir -p "$Q/w"; cp -a "$SRC/$slug" "$w"
  echo "=== $slug"
  (cd "$w" && timeout 120 bash run_tests.sh > "$Q/$slug.tests.txt" 2>&1; echo "власні тести: код $?, $(grep -Eo '[0-9]+ passed|Ran [0-9]+ tests|[0-9]+ failed' "$Q/$slug.tests.txt" | tr '\n' ' ')")
  img="pretest-qa-$slug"
  if ! docker build -q -t "$img" "$w" > "$Q/$slug.build.txt" 2>&1; then echo "збірка: ПОМИЛКА"; tail -3 "$Q/$slug.build.txt"; port=$((port+1)); continue; fi
  cid=$(docker run -d -p 127.0.0.1:$port:8099 "$img")
  for i in $(seq 20); do curl -s -m 1 "127.0.0.1:$port/sum?num1=1&num2=1" >/dev/null && break; sleep 0.5; done
  echo "uid у контейнері: $(docker exec "$cid" id -u 2>&1)"
  python3 "$(dirname "$0")/accept-pre.py" $port > "$Q/$slug.accept.json"
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print('приймання:', sum(v[0] for v in d.values()), '/', len(d)); [print('  ✗', k, v[1]) for k,v in d.items() if not v[0]]" "$Q/$slug.accept.json"
  docker rm -f "$cid" >/dev/null; docker rmi "$img" >/dev/null
  port=$((port+1))
done
