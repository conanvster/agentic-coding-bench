#!/bin/bash
# Димовий тест (05.11): чи доходить скриншот із stand_godot_run до gemma через OpenCode. ~5 хв GPU, запуск з `su - alex`.
# Передтест 05.11 показав: результат інструмента з помилкою (isError) OpenCode перетворює на текст і картинку викидає
# (там помилка була лише «X11 Display is not available» — у передтесті не було дисплея). Тут дисплей як у run-v4.sh.
# Результат: archive/smoke-image-gemma26-<час>/summary.txt — скільки запитів до моделі містили картинку.
set -u
V=/home/alex/v4_stand
MODEL="lmstudio-community/gemma-4-26b-a4b-it-qat"
CTX="${CTX:-79872}"
OUT="$V/archive/smoke-image-gemma26-$(date +%F-%H%M)"
LMS="$HOME/.lmstudio/bin/lms"; lmsc() { "$LMS" "$@" 8>&-; }
for p in /proc/[0-9]*; do
  a=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
  case "$a" in *"run-""v4.sh"*) echo "== СТОП: іде прогін стенду (PID ${p#/proc/})"; exit 1;; esac
done
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
[ -z "${WAYLAND_DISPLAY:-}" ] && [ -S "$XDG_RUNTIME_DIR/wayland-0" ] && export WAYLAND_DISPLAY=wayland-0
[ -z "${DISPLAY:-}" ] && [ -S /tmp/.X11-unix/X0 ] && export DISPLAY=:0
[ -z "${XAUTHORITY:-}" ] && XAUTHORITY=$(ls -t "$XDG_RUNTIME_DIR"/.mutter-Xwaylandauth.* 2>/dev/null | head -1) && export XAUTHORITY
mkdir -p "$OUT"; S="$OUT/summary.txt"
say() { echo "$*" | tee -a "$S"; }
say "== $(date '+%F %T') дисплей: DISPLAY=${DISPLAY:-—} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-—}"
. "$V/lib-graphs.sh"; . "$V/lib-direct.sh"
lmsc unload --all >/dev/null 2>&1; sleep 3
direct_start "$MODEL" "$CTX" off "$OUT/llama.log" || { say "== сервер не піднявся"; exit 1; }
P="$OUT/smoke-project"; mkdir -p "$P"
rsync -a --exclude build --exclude .git --exclude .userdata --exclude .stand "$V/stash/gra/qwen3.8-27b-iq4-xs/" "$P/"
python3 "$V/proxy.py" "$OUT/proxy.tsv" & proxy_pid=$!; sleep 2
( cd "$P" && V4_WORKDIR="$P" V4_VISION=1 OPENCODE_CONFIG="$V/opencode.json" OPENCODE_DISABLE_CLAUDE_CODE=1 PATH="$V/bin:$PATH" \
  timeout 900 opencode run --auto --format json -m "lmv4/$MODEL" \
  "Call the tool stand_godot_run with mode=play exactly once. Then, without calling any other tool, describe in 3 sentences what you SEE on the screenshot image you received: colours, ground, horizon, objects. If you did not receive an image, say NO IMAGE." \
  < /dev/null > "$OUT/smoke.jsonl" 2> "$OUT/smoke.stderr" )
kill $proxy_pid 2>/dev/null
direct_stop
python3 - "$OUT" <<'PY' | tee -a "$S"
import glob, json, sys
out = sys.argv[1]
st, att, txt = "?", 0, []
for l in open(f"{out}/smoke.jsonl"):
    try:
        e = json.loads(l)
    except ValueError:
        continue
    p = e.get("part") or {}
    if p.get("tool") == "stand_godot_run":
        s = p.get("state") or {}
        st, att = s.get("status"), len(s.get("attachments") or [])
    if p.get("type") == "text" and p.get("text"):
        txt.append(p["text"])
with_img = [f for f in glob.glob(f"{out}/req/*/*.request.json") if "data:image" in open(f, errors="ignore").read()]
print(f"stand_godot_run: статус {st}, вкладень у OpenCode {att}")
print(f"запитів до моделі з картинкою: {len(with_img)}")
print("відповідь моделі: " + " ".join(txt)[-600:].replace("\n", " "))
PY
set_graphs "$(python3 "$V/model_rules.py" "qwen3.8-27b@iq2_xxs" graphs)" >/dev/null 2>&1
lmsc load "qwen3.8-27b@iq2_xxs" -c 30720 --gpu max --identifier "qwen3.8-27b@iq2_xxs" -y < /dev/null > /dev/null 2>&1
say "== $(date '+%F %T') готово; бойову модель повернено"
