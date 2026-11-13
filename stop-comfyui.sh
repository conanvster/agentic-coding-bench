#!/bin/bash
# 13.11 (слово користувача): звільнити відеокарту від ComfyUI перед прогоном стенду.
# Шукає процеси, чий робочий каталог — ~/ComfyUI (через /proc, не pkill -f), шле TERM, через 20 с — KILL.
# Інших процесів на карті не чіпає — лише показує їх.
#   ./stop-comfyui.sh            — лише зупинити ComfyUI
#   ./stop-comfyui.sh --start    — зупинити й одразу запустити ./start-resume3.sh
CU="$HOME/ComfyUI"
pids=()
for p in /proc/[0-9]*; do
  [ "$(readlink "$p/cwd" 2>/dev/null)" = "$CU" ] || continue
  case "$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)" in *main.py*) pids+=("${p#/proc/}");; esac
done 2>/dev/null
if [ ${#pids[@]} = 0 ]; then
  echo "== ComfyUI не запущено"
else
  echo "== зупиняю ComfyUI: ${pids[*]}"
  kill "${pids[@]}" 2>/dev/null
  for _ in $(seq 20); do
    alive=0; for p in "${pids[@]}"; do [ -d "/proc/$p" ] && alive=1; done
    [ $alive = 0 ] && break; sleep 1
  done
  for p in "${pids[@]}"; do [ -d "/proc/$p" ] && { echo "== $p не зупинився за 20 с — KILL"; kill -9 "$p" 2>/dev/null; }; done
  sleep 2
fi
f=$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null)
if [ -n "$f" ]; then
  echo "== на відеокарті ще є процеси (не чіпаю):"; echo "$f"
  exit 1
fi
echo "== відеокарта вільна: $(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader)"
if [ "${1:-}" = "--start" ]; then
  exec /home/alex/v4_stand/start-resume3.sh
fi
echo "== далі: cd /home/alex/v4_stand && ./start-resume3.sh"
