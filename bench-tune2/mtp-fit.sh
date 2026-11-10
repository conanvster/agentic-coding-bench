#!/bin/bash
# 10.11 (слово користувача, варіант «а»): замір bench-tune2 показав, що MTP для qwen3.8 27B не піднімається на
# жодному з контекстів 65 536–114 688 (кеш допоміжного шару MTP теж займає відеопам'ять, напр. 320 МіБ на 81 920),
# а UD-IQ3_S не піднімається навіть без MTP на 131 072.
# Крок 1 (~10–15 хв): лише запуск сервера, контекст згори вниз — шукаємо найбільший, що піднімається:
#   UD-Q3_K_XL + MTP, UD-IQ3_S + MTP, UD-IQ3_S без MTP.
# Крок 2 (~10 хв на варіант): для кожного знайденого — та сама серія з 30 справжніх кроків (bench-tune2/run.sh),
# бо «піднявся» ще не означає «не впаде під навантаженням» (qwen3.8 на 2.66 падала через 25 хв).
# Найдовша підказка в серії qwen3.8 — 61 312 ток.: контекст менший за 62 тис. серію не пройде — такі лише відзначаємо.
# Кеш K/V у 4 бітах — не тестуємо (слово користувача 08.11). Зір (mmproj) — на CPU. Лише при вільній GPU.
#   ./bench-tune2/mtp-fit.sh
set -u
D=$(cd "$(dirname "$0")" && pwd)
for p in /proc/[0-9]*; do case "$(tr '\0' ' ' < $p/cmdline 2>/dev/null)" in *"run-""v4.sh"*|*"bench-tune2/run.sh"*) echo "== СТОП: іде прогін або замір"; exit 1;; esac; done 2>/dev/null
f=$(nvidia-smi --query-compute-apps=pid,process_name --format=csv,noheader | grep -v -e lmstudio)
[ -n "$f" ] && { echo "== СТОП: на відеокарті процес: $f"; exit 1; }
"$HOME/.lmstudio/bin/lms" unload --all >/dev/null 2>&1 8>&-; sleep 3
M="$HOME/.lmstudio/models/unsloth/Qwen3.8-27B-GGUF"; BK="$HOME/.lmstudio/extensions/backends"; VEND="$BK/vendor/linux-llama-cuda12-vendor-v1"
BIN="$BK/llama.cpp-linux-x86_64-nvidia-cuda12-avx2-2.66.0"; MM="$M/mmproj-F16.gguf"; PORT=1297
Q3="$M/Qwen3.8-27B-UD-Q3_K_XL.gguf"; I3="$M/Qwen3.8-27B-UD-IQ3_S.gguf"
BASE="-ctk q8_0 -ctv q8_0 -ub 256 -b 2048"; MTP="--spec-type draft-mtp --spec-draft-n-max 2 --spec-draft-n-ubatch 64"
OUT="$D/results-$(date +%F-%H%M)-mtp-fit.txt"; CF="$D/.mtp-fit-configs"; : > "$CF"
say() { echo "$*" | tee -a "$OUT"; }

# назва | gguf | параметри | контексти згори вниз
LADDERS=(
  "qwen3.8 Q3_K_XL MTP2|$Q3|$BASE $MTP|77824 73728 69632 65536 61440 57344"
  "qwen3.8 IQ3_S MTP2|$I3|$BASE $MTP|98304 90112 81920 73728 65536 61440"
  "qwen3.8 IQ3_S|$I3|$BASE|122880 114688 106496 98304"
)
say "== $(date '+%F %T') крок 1: найбільший контекст, з яким сервер піднімається"
for l in "${LADDERS[@]}"; do
  IFS='|' read -r name gguf extra ctxs <<< "$l"
  found=""
  for ctx in $ctxs; do
    log="$D/llama-fit-$(echo "$name" | tr ' ' '_')-$ctx.log"
    # shellcheck disable=SC2086
    LD_LIBRARY_PATH="$BIN:$VEND" "$BIN/llama-server" -m "$gguf" --mmproj "$MM" --no-mmproj-offload -c "$ctx" -ngl 999 -fa on -np 1 --jinja \
      --host 127.0.0.1 --port $PORT $extra > "$log" 2>&1 &
    pid=$!; ok=0
    for _ in $(seq 240); do curl -sf -m 3 localhost:$PORT/health >/dev/null && { ok=1; break; }; kill -0 $pid 2>/dev/null || break; sleep 1; done
    if [ $ok = 1 ]; then
      say "  $name, ctx $ctx: ✅ піднявся, вільно $(nvidia-smi --query-gpu=memory.free --format=csv,noheader)"
      found=$ctx
    else
      say "  $name, ctx $ctx: ❌ $(grep -iE 'out of memory|failed to' "$log" | tail -1 | cut -c1-160)"
    fi
    kill $pid 2>/dev/null; wait $pid 2>/dev/null; sleep 3
    [ -n "$found" ] && break
  done
  if [ -z "$found" ]; then say "  → $name: не піднявся на жодному"; continue; fi
  if [ "$found" -lt 62000 ]; then say "  → $name: найбільший $found — менший за найдовшу підказку серії (61 312), серію пропускаю"; continue; fi
  say "  → $name: найбільший $found — у серію"
  echo "$name $found|q38|$gguf|$MM|2.66.0|$found|$extra" >> "$CF"
done
say ""
if [ ! -s "$CF" ]; then say "== $(date '+%F %T') крок 2: нема чого заміряти → $OUT"; exit 0; fi
say "== $(date '+%F %T') крок 2: серії з 30 кроків ($(wc -l < "$CF") варіант(и)) — окремий файл results-*-mtp-series.txt"
CONFIGS_FILE="$CF" OUT_TAG=mtp-series "$D/run.sh" | tail -n +1
rm -f "$CF"
say "== $(date '+%F %T') готово → $OUT і results-*-mtp-series.txt"
