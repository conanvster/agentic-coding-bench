#!/bin/bash
# 10.11 (слово користувача): нові можливості рушія 2.66.0 — швидше, не вилазячи за пам'ять; контекст не зменшувати,
# краще збільшити без втрати швидкості. Відмінність від bench-tune: не окремі запити, а СЕРІЯ з 30 послідовних
# справжніх кроків агента (logs/req прогону етапу 3, вікно з найдовшою історією) — саме на серії вилізло падіння
# qwen3.8 на 2.66.0 (CUDA out of memory після 25 хв). Для кожного варіанта: падіння, пікова відеопам'ять,
# генерація ток/с, читання підказки ток/с, частка вгаданих чернеток, загальний час серії.
# Кандидати: чернетки з повторів тексту (--spec-type ngram-mod, 0 МіБ), кеш експертів у відеопам'яті
# (--moe-cache-mib), MTP qwen3.8 з меншими буферами (-ub 256, --spec-draft-n-ubatch), більший контекст Q2/Q4.
# Кеш K/V у 4 бітах — не тестуємо (слово користувача 08.11). Зір (mmproj) — на CPU. Лише при вільній GPU.
#   ./bench-tune2/run.sh            — усе (~3 год)
#   ONLY="Q4" ./bench-tune2/run.sh  — лише варіанти, чия назва починається з Q4
set -u
D=$(cd "$(dirname "$0")" && pwd)
for p in /proc/[0-9]*; do case "$(tr '\0' ' ' < $p/cmdline 2>/dev/null)" in *"run-""v4.sh"*) echo "== СТОП: іде прогін стенду"; exit 1;; esac; done 2>/dev/null
f=$(nvidia-smi --query-compute-apps=pid,process_name --format=csv,noheader | grep -v -e lmstudio)
[ -n "$f" ] && { echo "== СТОП: на відеокарті процес: $f"; exit 1; }
"$HOME/.lmstudio/bin/lms" unload --all >/dev/null 2>&1 8>&-; sleep 3
M="$HOME/.lmstudio/models/unsloth"; BK="$HOME/.lmstudio/extensions/backends"; VEND="$BK/vendor/linux-llama-cuda12-vendor-v1"
OUT="$D/results-$(date +%F-%H%M).txt"; PORT=1297
say() { echo "$*" | tee -a "$OUT"; }
Q2="$M/Qwen3.6-35B-A3B-GGUF/Qwen3.6-35B-A3B-UD-Q2_K_XL.gguf"; Q4="$M/Qwen3.6-35B-A3B-GGUF/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf"
Q36MM="$M/Qwen3.6-35B-A3B-GGUF/mmproj-F16.gguf"; FL="$M/flint-GGUF/flint-UD-Q4_K_XL.gguf"
Q38="$M/Qwen3.8-27B-GGUF/Qwen3.8-27B-UD-IQ4_XS.gguf"; Q38MM="$M/Qwen3.8-27B-GGUF/mmproj-F16.gguf"
NG="--spec-type ngram-mod"                                                   # типово чернетка 48–64 токени
NG16="--spec-type ngram-mod --spec-ngram-mod-n-min 8 --spec-ngram-mod-n-max 16"  # коротша — дешевша помилка для MoE
Q4T="-ncmoe 26 -ub 2048 -b 2048"; FLT="-ncmoe 34 -ub 2048 -b 2048"; KV8="-ctk q8_0 -ctv q8_0"

# назва | запити | gguf | mmproj | рушій | ctx | параметри
CONFIGS=(
  "Q2 tuned|q2|$Q2||2.66.0|131072|"
  "Q2 ngram-mod|q2|$Q2||2.66.0|131072|$NG"
  "Q2 ngram-mod 16|q2|$Q2||2.66.0|131072|$NG16"
  "Q2 ctx 196k|q2|$Q2||2.66.0|196608|"
  "Q2 ctx 262k kv8|q2|$Q2||2.66.0|262144|$KV8"
  "Q4 tuned|q4|$Q4|$Q36MM|2.66.0|131072|$Q4T"
  "Q4 ngram-mod 16|q4|$Q4|$Q36MM|2.66.0|131072|$Q4T $NG16"
  "Q4 moe-cache 2048|q4|$Q4|$Q36MM|2.66.0|131072|$Q4T --moe-cache-mib 2048"
  "Q4 ctx 262k ncmoe 30 moe-cache 1024|q4|$Q4|$Q36MM|2.66.0|262144|-ncmoe 30 -ub 2048 -b 2048 --moe-cache-mib 1024"
  "flint tuned|flint|$FL||2.66.0|131072|$FLT"
  "flint ngram-mod 16|flint|$FL||2.66.0|131072|$FLT $NG16"
  "flint ngram-mod|flint|$FL||2.66.0|131072|$FLT $NG"
  "flint moe-cache 2048|flint|$FL||2.66.0|131072|$FLT --moe-cache-mib 2048"
  "qwen3.8 база 2.28.2|q38|$Q38|$Q38MM|2.28.2|69632|$KV8"
  "qwen3.8 2.66 ub256|q38|$Q38|$Q38MM|2.66.0|69632|$KV8 -ub 256 -b 2048"
  "qwen3.8 2.66 ub256 ngram-mod 16|q38|$Q38|$Q38MM|2.66.0|69632|$KV8 -ub 256 -b 2048 $NG16"
  "qwen3.8 2.66 ub256 MTP2|q38|$Q38|$Q38MM|2.66.0|69632|$KV8 -ub 256 -b 2048 --spec-type draft-mtp --spec-draft-n-max 2 --spec-draft-n-ubatch 64"
  # власна збірка llama.cpp з AVX-512 і sm_120 (tools/build-llama-native.sh); пропускається, якщо її ще немає
  "Q2 native|q2|$Q2||native|131072|"
  "Q4 native|q4|$Q4|$Q36MM|native|131072|$Q4T"
  "flint native|flint|$FL||native|131072|$FLT"
  "qwen3.8 native|q38|$Q38|$Q38MM|native|69632|$KV8"
  "qwen3.8 2.66 ub256 MTP2 65536|q38|$Q38|$Q38MM|2.66.0|65536|$KV8 -ub 256 -b 2048 --spec-type draft-mtp --spec-draft-n-max 2 --spec-draft-n-ubatch 64"
)
say "== $(date '+%F %T') замір v2: серії з 30 справжніх кроків агента; $(nproc) потоків CPU, вільно оперативки $(awk '/MemAvailable/{print int($2/1048576)}' /proc/meminfo) ГБ"
for c in "${CONFIGS[@]}"; do
  IFS='|' read -r name rq gguf mm ver ctx extra <<< "$c"
  case "${ONLY:-}" in "") ;; *) [[ "$name" == ${ONLY}* ]] || continue;; esac
  bin="$BK/llama.cpp-linux-x86_64-nvidia-cuda12-avx2-$ver"
  if [ "$ver" = native ]; then bin="$HOME/llama.cpp-native/current"; [ -x "$bin/llama-server" ] || { say ""; say "## $name: пропущено — немає власної збірки"; continue; }; fi
  log="$D/llama-$(echo "$name" | tr ' ' '_').log"
  mmarg=(); [ -n "$mm" ] && mmarg=(--mmproj "$mm" --no-mmproj-offload)
  say ""; say "## $name: рушій $ver, ctx $ctx, ${mm:+зір на CPU, }$extra"
  # shellcheck disable=SC2086
  LD_LIBRARY_PATH="$bin:$VEND" "$bin/llama-server" -m "$gguf" "${mmarg[@]}" -c "$ctx" -ngl 999 -fa on -np 1 --jinja \
    --host 127.0.0.1 --port $PORT $extra > "$log" 2>&1 &
  pid=$!
  ok=0; for _ in $(seq 300); do curl -sf -m 3 localhost:$PORT/health >/dev/null && { ok=1; break; }; kill -0 $pid 2>/dev/null || break; sleep 1; done
  if [ $ok = 0 ]; then say "  не піднявся: $(grep -iE 'out of memory|failed to|error|unknown|invalid|not supported' "$log" | tail -2 | tr '\n' ' ' | cut -c1-300)"; kill $pid 2>/dev/null; wait $pid 2>/dev/null; continue; fi
  say "  вільно відеопам'яті після старту: $(nvidia-smi --query-gpu=memory.free --format=csv,noheader)"
  # пікова відеопам'ять під час серії
  ( while kill -0 $pid 2>/dev/null; do nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits; sleep 2; done ) > "$D/.vram" 2>/dev/null &
  mon=$!
  python3 - "$PORT" "$D/req/$rq" "$pid" "$( [ -n "$mm" ] && echo vision )" >> "$OUT" 2>&1 <<'PY'
import base64, glob, json, os, sys, time, urllib.request
port, rdir, pid, vision = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4] == "vision"
def post(body, timeout=1800):
    return json.load(urllib.request.urlopen(urllib.request.Request(f"http://127.0.0.1:{port}/v1/chat/completions",
        json.dumps(body).encode(), {"Content-Type": "application/json"}), timeout=timeout))
def alive():
    try: os.kill(pid, 0); return True
    except OSError: return False
pn = pms = gn = gms = dn = da = 0; t0 = time.time(); done = 0; maxp = 0
for f in sorted(glob.glob(f"{rdir}/*.json")):
    d = json.load(open(f)); d.update(stream=False, max_tokens=600, seed=42)
    for k in ("stream_options", "model"): d.pop(k, None)
    try:
        r = post(d)
    except Exception as e:
        print(f"  ПАДІННЯ на кроці {done + 1}: {'сервер упав' if not alive() else e}", flush=True); break
    tm, u = r.get("timings", {}), r.get("usage", {})
    pn += tm.get("prompt_n", 0); pms += tm.get("prompt_ms", 0); gn += tm.get("predicted_n", 0); gms += tm.get("predicted_ms", 0)
    dn += tm.get("draft_n", 0) or 0; da += tm.get("draft_n_accepted", 0) or 0; maxp = max(maxp, u.get("prompt_tokens") or 0); done += 1
acc = f"; чернетки вгадано {da}/{dn} ({100 * da / max(1, dn):.0f} %)" if dn else ""
print(f"  кроків {done}/30 за {time.time() - t0:.0f} с; найдовша підказка {maxp} ток.; перечитано {pn} ток. "
      f"({pn / max(1e-9, pms / 1000):.0f} ток/с); згенеровано {gn} ток. ({gn / max(1e-9, gms / 1000):.1f} ток/с){acc}", flush=True)
if vision and alive():
    b64 = base64.b64encode(open("/home/alex/v4_test/inputs/shop/design-landing.jpg", "rb").read()).decode()
    body = {"messages": [{"role": "user", "content": [{"type": "text", "text": "Опиши блоки цього макета зверху вниз, коротко."},
            {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + b64}}]}], "max_tokens": 2500,
            "chat_template_kwargs": {"reasoning_effort": "low"}}
    t = time.time()
    try:
        m = post(body, 900)["choices"][0]["message"]
        print(f"  зір (CPU): {time.time() - t:.0f} с; «{(m.get('content') or '')[:80]}»", flush=True)
    except Exception as e:
        print(f"  зір: ПОМИЛКА {e}", flush=True)
PY
  grep -q "CUDA error" "$log" && say "  у журналі сервера: $(grep -m1 -A1 'CUDA error' "$log" | tr '\n' ' ' | cut -c1-200)"
  kill $mon 2>/dev/null
  say "  пік відеопам'яті: $(sort -n "$D/.vram" | tail -1) МіБ із $(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits); оперативки доступно $(awk '/MemAvailable/{print int($2/1048576)}' /proc/meminfo) ГБ"
  kill $pid 2>/dev/null; wait $pid 2>/dev/null; sleep 3
done
rm -f "$D/.vram"
say ""; say "== $(date '+%F %T') готово → $OUT"
