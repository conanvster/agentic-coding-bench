# Модель на llama-server напряму, без LM Studio (source у bash). Той самий рушій, що всередині LM Studio (2.28.2).
# Для моделей з полем правил "server": {"kind": "llama-server", "port": N, "gguf": "шлях від ~/.lmstudio/models"}.
# Навіщо: gpt-oss через LM Studio ламає формат (peg-native) і не отримує своїх міркувань; напряму — 0/72 збоїв, і
# reasoning_content доходить до моделі (model-rules/gpt-oss-20b.json, gptoss-direct).
#   direct_start <модель> <ctx> <on|off графи> → запускає, чекає /health; DIRECT_PID, DIRECT_PORT
#   direct_ok                               → сервер живий і відповідає
#   direct_stop
# Запускати лише коли LM Studio вивантажила моделі (одна відеокарта).
LMS_BACKENDS="$HOME/.lmstudio/extensions/backends"
DIRECT_BIN="$LMS_BACKENDS/llama.cpp-linux-x86_64-nvidia-cuda12-avx2-2.28.2"
DIRECT_VENDOR="$LMS_BACKENDS/vendor/linux-llama-cuda12-vendor-v1"
DIRECT_PID=""; DIRECT_PORT=""

direct_start() {  # модель ctx графи [журнал]
  local model="$1" ctx="$2" graphs="$3" log="${4:-/dev/null}" gguf i
  local V_="${V:-/home/alex/v4_stand}"
  DIRECT_PORT=$(python3 "$V_/model_rules.py" "$model" server | python3 -c 'import json,sys; print(json.load(sys.stdin)["port"])')
  gguf="$HOME/.lmstudio/models/$(python3 "$V_/model_rules.py" "$model" server | python3 -c 'import json,sys; print(json.load(sys.stdin)["gguf"])')"
  [ -f "$gguf" ] || { echo "== немає файлу моделі $gguf"; return 1; }
  # "args" у правилі server — додаткові параметри llama-server (напр. ["-ctk","q8_0","-ctv","q8_0"] — кеш K/V у 8 бітах)
  local extra=()
  mapfile -t extra < <(python3 "$V_/model_rules.py" "$model" server | python3 -c 'import json,sys; [print(a) for a in json.load(sys.stdin).get("args", [])]')
  # v4: "mmproj" (шлях від ~/.lmstudio/models) — зір; кодувальник зображень на CPU (--no-mmproj-offload), щоб не брати відеопам'ять
  local mmproj
  mmproj=$(python3 "$V_/model_rules.py" "$model" server | python3 -c 'import json,sys; print(json.load(sys.stdin).get("mmproj", ""))')
  [ -n "$mmproj" ] && extra+=(--mmproj "$HOME/.lmstudio/models/$mmproj" --no-mmproj-offload)
  if [ "$graphs" = off ]; then
    GGML_CUDA_DISABLE_GRAPHS=1 LD_LIBRARY_PATH="$DIRECT_BIN:$DIRECT_VENDOR" "$DIRECT_BIN/llama-server" -m "$gguf" \
      -c "$ctx" -ngl 999 -fa on -np 1 --jinja --alias "$model" --host 127.0.0.1 --port "$DIRECT_PORT" "${extra[@]}" 9>&- > "$log" 2>&1 &
  else
    env -u GGML_CUDA_DISABLE_GRAPHS LD_LIBRARY_PATH="$DIRECT_BIN:$DIRECT_VENDOR" "$DIRECT_BIN/llama-server" -m "$gguf" \
      -c "$ctx" -ngl 999 -fa on -np 1 --jinja --alias "$model" --host 127.0.0.1 --port "$DIRECT_PORT" "${extra[@]}" 9>&- > "$log" 2>&1 &
  fi
  DIRECT_PID=$!
  for i in $(seq 180); do direct_ok && return 0; kill -0 "$DIRECT_PID" 2>/dev/null || break; sleep 1; done
  echo "== llama-server для $model не піднявся"; tail -5 "$log" 2>/dev/null
  direct_stop; return 1
}

direct_ok() {
  [ -n "$DIRECT_PID" ] && kill -0 "$DIRECT_PID" 2>/dev/null && curl -sf -m 3 "localhost:$DIRECT_PORT/health" >/dev/null
}

direct_stop() {
  [ -n "$DIRECT_PID" ] || return 0
  kill "$DIRECT_PID" 2>/dev/null
  for _ in $(seq 20); do kill -0 "$DIRECT_PID" 2>/dev/null || break; sleep 1; done
  kill -9 "$DIRECT_PID" 2>/dev/null
  DIRECT_PID=""
}
