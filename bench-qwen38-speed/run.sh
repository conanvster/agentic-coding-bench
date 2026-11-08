#!/bin/bash
# 08.11 (слово користувача): qwen3.8 27B IQ4_XS — контекст ≥ 70 тис., > 40 ток/с, зір на CPU.
# Стеля без хитрощів: ваги 14,25 ГБ / 448 ГБ/с пропускної здатності RTX 5060 Ti ≈ 31 ток/с максимум
# (на стенді 21 ток/с). > 40 можливо лише спекулятивним декодуванням: у GGUF є голова MTP
# (blk.64.nextn.*, рушій 2.28.2 її ігнорує), рушій LM Studio 2.66.0 має --spec-type draft-mtp і ngram-mod.
# Заміряє на 3 СПРАВЖНІХ запитах стенду (27/46/63 тис. токенів, з інструментами, сайт qwen3.8 08.11):
# швидкість відповіді, частку прийнятих чернеток, вільну відеопам'ять. mmproj завжди на CPU (--no-mmproj-offload).
# Лише коли GPU вільна: після прогону сайту. Результат: results-<час>.txt поруч.
set -u
D=$(cd "$(dirname "$0")" && pwd)
for p in /proc/[0-9]*; do case "$(tr '\0' ' ' < $p/cmdline 2>/dev/null)" in *"run-""v4.sh"*) echo "== СТОП: іде прогін стенду"; exit 1;; esac; done 2>/dev/null
f=$(nvidia-smi --query-compute-apps=pid,process_name --format=csv,noheader | grep -v -e lmstudio)
[ -n "$f" ] && { echo "== СТОП: на відеокарті процес: $f"; exit 1; }
"$HOME/.lmstudio/bin/lms" unload --all >/dev/null 2>&1 8>&-; sleep 3
M="$HOME/.lmstudio/models/unsloth/Qwen3.8-27B-GGUF"
GGUF="$M/Qwen3.8-27B-UD-IQ4_XS.gguf"; MMPROJ="$M/mmproj-F16.gguf"
BK="$HOME/.lmstudio/extensions/backends"; VEND="$BK/vendor/linux-llama-cuda12-vendor-v1"
OUT="$D/results-$(date +%F-%H%M).txt"; PORT=1299
say() { echo "$*" | tee -a "$OUT"; }

# назва | версія рушія | ctx | додаткові параметри
CONFIGS=(
  "A база стенду|2.28.2|69632|-ctk q8_0 -ctv q8_0"
  "B новий рушій|2.66.0|69632|-ctk q8_0 -ctv q8_0"
  "C MTP 3|2.66.0|69632|-ctk q8_0 -ctv q8_0 --spec-type draft-mtp --spec-draft-n-max 3"
  "D MTP 2|2.66.0|69632|-ctk q8_0 -ctv q8_0 --spec-type draft-mtp --spec-draft-n-max 2"
  "E MTP 3 + ngram|2.66.0|69632|-ctk q8_0 -ctv q8_0 --spec-type draft-mtp,ngram-mod --spec-draft-n-max 3"
  # 08.11 (слово користувача): кеш K/V у 4 бітах не тестуємо — втрачається якість; лише q8_0.
  # На 2.28.2 стеля q8_0 — 69632 (73728 — OOM); новий рушій може бути ощадніший — перевірити 73728 і 77824
  "F MTP 3, 73728|2.66.0|73728|-ctk q8_0 -ctv q8_0 --spec-type draft-mtp --spec-draft-n-max 3"
  "G MTP 3, 77824|2.66.0|77824|-ctk q8_0 -ctv q8_0 --spec-type draft-mtp --spec-draft-n-max 3"
)
say "== $(date '+%F %T') qwen3.8 27B IQ4_XS: швидкість і контекст; зір (mmproj) на CPU у всіх варіантах"
for c in "${CONFIGS[@]}"; do
  IFS='|' read -r name ver ctx extra <<< "$c"
  bin="$BK/llama.cpp-linux-x86_64-nvidia-cuda12-avx2-$ver"; log="$D/llama-${name%% *}.log"
  say ""; say "## $name: рушій $ver, ctx $ctx, $extra"
  # shellcheck disable=SC2086
  LD_LIBRARY_PATH="$bin:$VEND" "$bin/llama-server" -m "$GGUF" --mmproj "$MMPROJ" --no-mmproj-offload \
    -c "$ctx" -ngl 999 -fa on -np 1 --jinja --host 127.0.0.1 --port $PORT $extra > "$log" 2>&1 &
  pid=$!
  ok=0; for _ in $(seq 240); do curl -sf -m 3 localhost:$PORT/health >/dev/null && { ok=1; break; }; kill -0 $pid 2>/dev/null || break; sleep 1; done
  if [ $ok = 0 ]; then say "  не піднявся: $(grep -iE 'out of memory|error|unknown|invalid' "$log" | tail -2)"; kill $pid 2>/dev/null; wait $pid 2>/dev/null; continue; fi
  say "  вільно відеопам'яті після старту: $(nvidia-smi --query-gpu=memory.free --format=csv,noheader)"
  python3 - "$PORT" "$D/req" >> "$OUT" 2>&1 <<'PY'
import json, sys, time, urllib.request
port, rdir = sys.argv[1], sys.argv[2]
for name in ("r27k", "r46k", "r63k"):
    d = json.load(open(f"{rdir}/{name}.json"))
    d.update(stream=False, max_tokens=1500, seed=42)
    d.pop("stream_options", None)
    t = time.time()
    try:
        r = json.load(urllib.request.urlopen(urllib.request.Request(f"http://127.0.0.1:{port}/v1/chat/completions",
            json.dumps(d).encode(), {"Content-Type": "application/json"}), timeout=1800))
    except Exception as e:
        print(f"  {name}: ПОМИЛКА {e}"); continue
    tm, u = r.get("timings", {}), r.get("usage", {})
    acc = (f", чернетки {tm['draft_n_accepted']}/{tm['draft_n']} ({100 * tm['draft_n_accepted'] / tm['draft_n']:.0f} %)"
           if tm.get("draft_n") else "")
    print(f"  {name}: підказка {u.get('prompt_tokens')} ток. за {tm.get('prompt_ms', 0) / 1000:.0f} с "
          f"({tm.get('prompt_per_second', 0):.0f} ток/с); відповідь {u.get('completion_tokens')} ток., "
          f"{tm.get('predicted_per_second', 0):.1f} ток/с{acc}; усього {time.time() - t:.0f} с", flush=True)
import base64
b64 = base64.b64encode(open("/home/alex/v4_test/inputs/shop/design-landing.jpg", "rb").read()).decode()
body = {"messages": [{"role": "user", "content": [{"type": "text", "text": "Опиши блоки цього макета зверху вниз, коротко."},
        {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + b64}}]}],
        "max_tokens": 600, "chat_template_kwargs": {"reasoning_effort": "low"}}
t = time.time()
try:
    r = json.load(urllib.request.urlopen(urllib.request.Request(f"http://127.0.0.1:{port}/v1/chat/completions",
        json.dumps(body).encode(), {"Content-Type": "application/json"}), timeout=900))
    tm = r.get("timings", {})
    print(f"  зір (макет, CPU): підказка {r['usage']['prompt_tokens']} ток. за {tm.get('prompt_ms', 0) / 1000:.0f} с; "
          f"відповідь {tm.get('predicted_per_second', 0):.1f} ток/с; усього {time.time() - t:.0f} с; "
          f"«{(r['choices'][0]['message'].get('content') or '')[:120]}»", flush=True)
except Exception as e:
    print(f"  зір: ПОМИЛКА {e}")
PY
  say "  вільно відеопам'яті під навантаженням 63k: $(nvidia-smi --query-gpu=memory.free --format=csv,noheader)"
  kill $pid 2>/dev/null; wait $pid 2>/dev/null; sleep 3
done
say ""; say "== $(date '+%F %T') готово → $OUT"
