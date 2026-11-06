#!/bin/bash
# Стан прогону run-v3.sh одним екраном: результати етапів, поточна модель і етап, час проти бюджету,
# запити через проксі (скільки, середній час, 5xx, стиснення контексту), останні дії моделі, відеокарта.
#   status.sh        — один раз
#   status.sh -f [N] — оновлювати кожні N с (типово 30), вихід — Ctrl+C
V=/home/alex/v4_stand; L=$V/logs
if [ "${1:-}" = -f ]; then
  while true; do clear; "$0"; sleep "${2:-30}"; done
fi

echo "=== $(date '+%F %T')"
if flock -n "$V/.lock" true 2>/dev/null; then echo "прогін: НЕ ЙДЕ"; else echo "прогін: іде"; fi
[ -f "$L/run.out" ] || { echo "немає logs/run.out"; exit 0; }

echo; echo "--- етапи (run.out)"
grep -E '^== .*(start|етап|end|бюджет|зупинено|ЗАПОБІЖНИК|failed|all done)' "$L/run.out" | sed 's/^== 2026-//' | tail -14 | cut -c1-110

start=$(grep -E '^== .* start ' "$L/run.out" | tail -1)
[ -n "$start" ] || exit 0
task=$(awk '{print $5}' <<< "$start"); model=$(awk '{print $6}' <<< "$start")
t0=$(date -d "$(awk '{print $2, $3}' <<< "$start")" +%s)
case "$task" in pre) budget=3000 ;; gra) budget=9000 ;; shop) budget=9000 ;; esac
el=$(( $(date +%s) - t0 ))
echo; echo "--- зараз: $task $model, минуло $((el / 60)) хв з $((budget / 60))"

python3 - "$L/proxy.tsv" "$model" "$(date -d @$t0 '+%F %T')" <<'EOF'
import json, sys
path, model, since = sys.argv[1:]
n = tsum = e5 = comp = 0
last = None
try:
    for line in open(path):
        c = line.rstrip("\n").split("\t")
        if len(c) < 7 or c[1] != model or c[0] < since:
            continue
        n += 1; tsum += float(c[4] or 0); e5 += c[3].startswith("5")
        # без інструментів: назва сесії (запит 25–90 КБ) або стиснення (0,4–2,7 МБ); за часом не розрізнити —
        # qwen3.6 стискає за 17–28 с, а gpt-oss з довгим контекстом пише назву ~36 с
        comp += '"tools": 0' in c[6] and int(c[5] or 0) > 300_000
        last = c[0]
except OSError:
    pass
if n:
    print(f"запитів {n}, сер. {tsum / n:.0f} с на крок, 5xx {e5}, стиснень контексту {comp}, останній {last[11:]}")
EOF

jl=$(ls -t "$L"/"$task"-*-s*.jsonl 2>/dev/null | head -1)
[ -n "$jl" ] && { echo; echo "--- останні дії ($(basename "$jl"))"; python3 - "$jl" <<'EOF'
import json, sys
rows = []
for line in open(sys.argv[1], errors="ignore"):
    try:
        p = json.loads(line).get("part", {})
    except ValueError:
        continue
    if p.get("type") == "tool":
        inp = p.get("state", {}).get("input", {})
        arg = inp.get("command") or inp.get("filePath") or inp.get("pattern") or json.dumps(inp, ensure_ascii=False)
        rows.append(f"{p['tool']:9} {str(arg)[:95]}")
    elif p.get("type") == "text" and p.get("text", "").strip():
        t = p["text"].strip().replace("\n", " ")
        rows.append(("[стиснення] " if t.startswith("## Objective") else "» ") + t[:100])
print("\n".join(rows[-10:]))
EOF
}

echo; echo "--- відеокарта"
nvidia-smi --query-gpu=memory.used,memory.total,utilization.gpu,temperature.gpu --format=csv,noheader
x=$(journalctl -k --since "$(date -d @$t0 '+%F %T')" 2>/dev/null | grep -ci xid); echo "Xid з початку моделі: $x"
