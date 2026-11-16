#!/bin/bash
# 17.11 (слово користувача): рівні умови заліза для повторного прогону — одна збірка llama-server, однакові -ub/-b,
# CUDA-графи вимкнено обом; контекст — найбільший, що влазить для кожної моделі (зір на CPU в обох).
#   tools/fit-equal.sh <вихідний каталог правил> <runs-файл, що буде записано> [--dry]
# Для кожної збірки (2.66.0, потім 2.28.2): кожну модель піднімаємо через lib-direct.sh з кандидатами контексту
# (від більшого) і підказкою на ~90 % контексту — так llama-server виділяє весь кеш K/V і буфери обчислень.
# Підходить, якщо відповідь 200 і сервер не впав (CUDA OOM). Беремо першу збірку, на якій влазять обидві.
# Пише <каталог правил> = копія model-rules-full з полями bin/args/graphs для обох моделей і runs-файл з контекстами.
# Потребує вільної відеокарти: вивантажує всі моделі LM Studio (бойову теж — голосовий помічник на цей час без моделі).
set -u
V=/home/alex/v4_stand; OUTR=$(readlink -m "${1:?каталог правил}"); RUNS=$(readlink -m "${2:?runs-файл}"); DRY=0; [ "${3:-}" = --dry ] && DRY=1
BINS=(2.66.0 2.28.2); ARGS='["-ctk", "q8_0", "-ctv", "q8_0", "-ub", "256", "-b", "2048"]'
declare -A CTX=( ["qwen3.8-27b@q3_k_xl"]="114688 106496 98304" ["qwen3.8-27b@iq4_xs"]="98304 90112 81920 73728 69632" )
declare -A SLUG=( ["qwen3.8-27b@q3_k_xl"]="full-r2-q38q3" ["qwen3.8-27b@iq4_xs"]="full-r2-q38" )
MODELS=("qwen3.8-27b@q3_k_xl" "qwen3.8-27b@iq4_xs")
LOG="$(dirname "$RUNS")/fit-equal-$(date +%Y%m%d-%H%M).log"
echo "== журнал: $LOG"
[ $DRY = 1 ] && { echo "== --dry: збірки ${BINS[*]}; параметри $ARGS, графи off; контексти:"; for m in "${MODELS[@]}"; do echo "   $m: ${CTX[$m]}"; done; exit 0; }

"$HOME/.lmstudio/bin/lms" unload --all >/dev/null 2>&1
f=$(nvidia-smi --query-compute-apps=pid,process_name --format=csv,noheader 2>/dev/null)
[ -n "$f" ] && { echo "== СТОП: відеокарта не вільна: $f"; exit 1; }

TMPR=$(mktemp -d); trap 'rm -rf "$TMPR"' EXIT
mk_rules() {  # $1 — збірка → $TMPR/rules (копія model-rules-full з рівними параметрами)
  rm -rf "$TMPR/rules"; cp -a "$V/model-rules-full" "$TMPR/rules"
  python3 - "$TMPR/rules" "$1" "$ARGS" <<'EOF'
import json, sys, glob
d, binv, args = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
for f in glob.glob(d + "/qwen3.8-27b-q3kxl.json") + glob.glob(d + "/qwen3.8-27b-iq4-xs.json"):
    r = json.load(open(f)); r["server"]["bin"] = binv; r["server"]["args"] = args; r["graphs"] = "off"
    r["опис"] = r.get("опис", "") + f" | r2 17.11: рівні умови — рушій {binv}, {' '.join(args)}, графи off (tools/fit-equal.sh)"
    json.dump(r, open(f, "w"), ensure_ascii=False, indent=2)
EOF
}
probe() {  # модель ctx → 0, якщо влазить
  local model=$1 ctx=$2 slog="$TMPR/srv.log"
  ( export MODEL_RULES="$TMPR/rules" V="$V"; . "$V/lib-direct.sh"
    direct_start "$model" "$ctx" off "$slog" >/dev/null 2>&1 || exit 1
    python3 - "$DIRECT_PORT" "$ctx" <<'EOF'
import json, sys, urllib.request
port, ctx = sys.argv[1], int(sys.argv[2])
def post(path, body, t=900):
    rq = urllib.request.Request(f"http://127.0.0.1:{port}{path}", json.dumps(body).encode(), {"content-type": "application/json"})
    return json.load(urllib.request.urlopen(rq, timeout=t))
unit = "The quick brown fox audits the shopping cart, recomputes the cashback and writes a careful unit test. "
n = len(post("/tokenize", {"content": unit})["tokens"])
text = unit * max(1, int(ctx * 0.9 / n))
r = post("/v1/chat/completions", {"messages": [{"role": "user", "content": text + "\nReply with one word: ok"}], "max_tokens": 16})
print(r["usage"]["prompt_tokens"])
EOF
    rc=$?; direct_stop; exit $rc ) >> "$LOG" 2>&1
  local rc=$?
  grep -qiE 'out of memory|cudaMalloc failed|failed to allocate' "$slog" 2>/dev/null && rc=1
  cat "$slog" >> "$LOG" 2>/dev/null
  return $rc
}

declare -A BEST
for b in "${BINS[@]}"; do
  [ -x "$HOME/.lmstudio/extensions/backends/llama.cpp-linux-x86_64-nvidia-cuda12-avx2-$b/llama-server" ] || { echo "== збірки $b немає"; continue; }
  mk_rules "$b"; ok_all=1
  for m in "${MODELS[@]}"; do
    BEST[$m]=""
    for c in ${CTX[$m]}; do
      echo "== $(date '+%T') $b $m ctx $c …" | tee -a "$LOG"
      if probe "$m" "$c"; then BEST[$m]=$c; echo "   влазить" | tee -a "$LOG"; break; else echo "   не влазить" | tee -a "$LOG"; fi
    done
    [ -z "${BEST[$m]}" ] && { ok_all=0; echo "== $b: $m не вміщається навіть з найменшим контекстом" | tee -a "$LOG"; break; }
  done
  if [ $ok_all = 1 ]; then
    rm -rf "$OUTR"; cp -a "$TMPR/rules" "$OUTR"
    { echo "# 17.11 повторний прогін r2, рівні умови (tools/fit-equal.sh $(date '+%F %T')): рушій $b, $ARGS, CUDA-графи off обом"
      for m in "${MODELS[@]}"; do echo "$m|${SLUG[$m]}|${BEST[$m]}"; done; } > "$RUNS"
    echo "== ВИБРАНО: рушій $b; $(for m in "${MODELS[@]}"; do printf '%s ctx %s; ' "$m" "${BEST[$m]}"; done)" | tee -a "$LOG"
    exit 0
  fi
done
echo "== СТОП: жодна збірка не вмістила обидві моделі з рівними параметрами — див. $LOG"; exit 1
