#!/bin/bash
# 09.11 (слово користувача): як покращити швидкість (без втрати якості) 4 обраних моделей — замір налаштувань.
# Для кожного варіанта: чи вміщається (вільна відеопам'ять), генерація ток/с, читання підказки ток/с, і ціна
# «зсуву вікна міркувань» — повторний запит, де в одній із пізніх відповідей прибрано міркування (так proxy.py
# робить щокроку при passback keep 6): скільки підказки модель перечитує заново.
# Запити — 3 справжні з сайту (27/46/63 тис. токенів, OpenCode з інструментами). Зір (mmproj) — на CPU.
# Кеш K/V у 4 бітах не тестуємо (слово користувача 08.11). Результат: results-<час>.txt. Лише при вільній GPU.
set -u
D=$(cd "$(dirname "$0")" && pwd)
for p in /proc/[0-9]*; do case "$(tr '\0' ' ' < $p/cmdline 2>/dev/null)" in *"run-""v4.sh"*) echo "== СТОП: іде прогін стенду"; exit 1;; esac; done 2>/dev/null
f=$(nvidia-smi --query-compute-apps=pid,process_name --format=csv,noheader | grep -v -e lmstudio)
[ -n "$f" ] && { echo "== СТОП: на відеокарті процес: $f"; exit 1; }
"$HOME/.lmstudio/bin/lms" unload --all >/dev/null 2>&1 8>&-; sleep 3
M="$HOME/.lmstudio/models/unsloth"; BK="$HOME/.lmstudio/extensions/backends"; VEND="$BK/vendor/linux-llama-cuda12-vendor-v1"
OUT="$D/results-$(date +%F-%H%M).txt"; PORT=1298
say() { echo "$*" | tee -a "$OUT"; }
Q2="$M/Qwen3.6-35B-A3B-GGUF/Qwen3.6-35B-A3B-UD-Q2_K_XL.gguf"; Q4="$M/Qwen3.6-35B-A3B-GGUF/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf"
Q36MM="$M/Qwen3.6-35B-A3B-GGUF/mmproj-F16.gguf"; FL="$M/flint-GGUF/flint-UD-Q4_K_XL.gguf"
Q38="$M/Qwen3.8-27B-GGUF/Qwen3.8-27B-UD-IQ4_XS.gguf"; Q38MM="$M/Qwen3.8-27B-GGUF/mmproj-F16.gguf"
CP="--ctx-checkpoints 8 --checkpoint-min-step 2048 --cache-ram 8192"  # контрольні точки стану (гібридні моделі)

# назва | gguf | mmproj | рушій | ctx | параметри
CONFIGS=(
  "Q2 база|$Q2||2.28.2|131072|"
  "Q2 2.66|$Q2||2.66.0|131072|"
  "Q2 2.66 точки|$Q2||2.66.0|131072|$CP"
  "Q4 база|$Q4|$Q36MM|2.28.2|131072|-ncmoe 24"
  "Q4 2.66|$Q4|$Q36MM|2.66.0|131072|-ncmoe 24"
  "Q4 2.66 точки ub2048|$Q4|$Q36MM|2.66.0|131072|-ncmoe 26 -ub 2048 -b 2048 $CP"
  "Q4 2.66 точки ub2048 kv8|$Q4|$Q36MM|2.66.0|131072|-ncmoe 24 -ub 2048 -b 2048 -ctk q8_0 -ctv q8_0 $CP"
  "flint база|$FL||2.66.0|131072|-ncmoe 32"
  "flint точки ub2048|$FL||2.66.0|131072|-ncmoe 34 -ub 2048 -b 2048 $CP"
  "flint точки ub2048 kv8|$FL||2.66.0|131072|-ncmoe 32 -ub 2048 -b 2048 -ctk q8_0 -ctv q8_0 $CP"
  "qwen3.8 база|$Q38|$Q38MM|2.28.2|69632|-ctk q8_0 -ctv q8_0"
  "qwen3.8 2.66 точки|$Q38|$Q38MM|2.66.0|69632|-ctk q8_0 -ctv q8_0 $CP"
  "qwen3.8 2.66 точки MTP2|$Q38|$Q38MM|2.66.0|69632|-ctk q8_0 -ctv q8_0 $CP --spec-type draft-mtp --spec-draft-n-max 2"
  "qwen3.8 2.66 точки MTP3|$Q38|$Q38MM|2.66.0|69632|-ctk q8_0 -ctv q8_0 $CP --spec-type draft-mtp --spec-draft-n-max 3"
  "qwen3.8 2.66 MTP2 без зору|$Q38||2.66.0|69632|-ctk q8_0 -ctv q8_0 $CP --spec-type draft-mtp --spec-draft-n-max 2"
)
say "== $(date '+%F %T') замір налаштувань 4 моделей; запити: 27k, 46k, 63k і «зсув вікна» на 46k"
for c in "${CONFIGS[@]}"; do
  IFS='|' read -r name gguf mm ver ctx extra <<< "$c"
  case "${ONLY:-}" in "") ;; *) [[ "$name" == ${ONLY}* ]] || continue;; esac
  bin="$BK/llama.cpp-linux-x86_64-nvidia-cuda12-avx2-$ver"; log="$D/llama-$(echo "$name" | tr ' ' '_').log"
  mmarg=(); [ -n "$mm" ] && mmarg=(--mmproj "$mm" --no-mmproj-offload)
  say ""; say "## $name: рушій $ver, ctx $ctx, ${mm:+зір на CPU, }$extra"
  # shellcheck disable=SC2086
  LD_LIBRARY_PATH="$bin:$VEND" "$bin/llama-server" -m "$gguf" "${mmarg[@]}" -c "$ctx" -ngl 999 -fa on -np 1 --jinja \
    --host 127.0.0.1 --port $PORT $extra > "$log" 2>&1 &
  pid=$!
  ok=0; for _ in $(seq 300); do curl -sf -m 3 localhost:$PORT/health >/dev/null && { ok=1; break; }; kill -0 $pid 2>/dev/null || break; sleep 1; done
  if [ $ok = 0 ]; then say "  не піднявся: $(grep -iE 'out of memory|error|unknown|invalid|not supported' "$log" | tail -2)"; kill $pid 2>/dev/null; wait $pid 2>/dev/null; continue; fi
  say "  вільно відеопам'яті після старту: $(nvidia-smi --query-gpu=memory.free --format=csv,noheader)"
  python3 - "$PORT" "$D/req" "$( [ -n "$mm" ] && echo vision )" >> "$OUT" 2>&1 <<'PY'
import base64, copy, json, sys, time, urllib.request
port, rdir, vision = sys.argv[1], sys.argv[2], sys.argv[3] == "vision"
def post(body, timeout=3600):
    return json.load(urllib.request.urlopen(urllib.request.Request(f"http://127.0.0.1:{port}/v1/chat/completions",
        json.dumps(body).encode(), {"Content-Type": "application/json"}), timeout=timeout))
def show(tag, r, t):
    tm, u = r.get("timings", {}), r.get("usage", {})
    acc = (f", вгадано {tm['draft_n_accepted']}/{tm['draft_n']} ({100 * tm['draft_n_accepted'] / max(1, tm['draft_n']):.0f} %)"
           if tm.get("draft_n") else "")
    print(f"  {tag}: підказка {u.get('prompt_tokens')} ток., перечитано {tm.get('prompt_n')} за {tm.get('prompt_ms', 0) / 1000:.0f} с "
          f"({tm.get('prompt_per_second', 0):.0f} ток/с); відповідь {u.get('completion_tokens')} ток. {tm.get('predicted_per_second', 0):.1f} ток/с{acc}; "
          f"усього {time.time() - t:.0f} с", flush=True)
def prep(d):
    d = copy.deepcopy(d); d.update(stream=False, max_tokens=1200, seed=42); d.pop("stream_options", None); d.pop("model", None); return d
for name in ("r27k", "r63k", "r46k"):
    d = prep(json.load(open(f"{rdir}/{name}.json")))
    t = time.time()
    try:
        show(name, post(d), t)
    except Exception as e:
        print(f"  {name}: ПОМИЛКА {e}", flush=True)
# зсув вікна міркувань: як proxy.py на наступному кроці — найстаріша відповідь з міркуваннями їх втрачає
d2 = prep(json.load(open(f"{rdir}/r46k.json")))
withr = [i for i, m in enumerate(d2["messages"]) if m.get("role") == "assistant" and m.get("reasoning_content")]
if withr:
    d2["messages"][withr[0]].pop("reasoning_content")
t = time.time()
try:
    show("r46k після зсуву вікна", post(d2), t)
except Exception as e:
    print(f"  зсув: ПОМИЛКА {e}", flush=True)
if vision:
    b64 = base64.b64encode(open("/home/alex/v4_test/inputs/shop/design-landing.jpg", "rb").read()).decode()
    body = {"messages": [{"role": "user", "content": [{"type": "text", "text": "Опиши блоки цього макета зверху вниз, коротко."},
            {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + b64}}]}], "max_tokens": 600,
            "chat_template_kwargs": {"reasoning_effort": "low"}}
    t = time.time()
    try:
        r = post(body, 900)
        print(f"  зір (макет на CPU): {time.time() - t:.0f} с; «{(r['choices'][0]['message'].get('content') or '')[:100]}»", flush=True)
    except Exception as e:
        print(f"  зір: ПОМИЛКА {e}", flush=True)
PY
  say "  вільно відеопам'яті під навантаженням: $(nvidia-smi --query-gpu=memory.free --format=csv,noheader); оперативки доступно $(awk '/MemAvailable/{print int($2/1048576)}' /proc/meminfo) ГБ"
  kill $pid 2>/dev/null; wait $pid 2>/dev/null; sleep 3
done
say ""; say "== $(date '+%F %T') готово → $OUT"
