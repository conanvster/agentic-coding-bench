# CUDA-графи llama.cpp для LM Studio (source у bash). Кожне завантаження моделі — новий llama-server, який бере
# змінні оточення від демона llmster; тому графи вмикаються/вимикаються перезапуском демона перед `lms load`.
#   graphs_now        → on | off | none (демон не запущено)
#   set_graphs on|off → перезапускає демон, лише якщо стан інший; код 1, якщо не вдалося
# Навіщо: model-rules.json, проблема xid8-cuda-graphs (Xid 8 на RTX 5060 Ti).
LMS="${LMS:-$HOME/.lmstudio/bin/lms}"

graphs_now() {
  local pid
  pid=$(pgrep -x llmster | head -1)
  [ -z "$pid" ] && { echo none; return; }
  if tr '\0' '\n' < "/proc/$pid/environ" | grep -q '^GGML_CUDA_DISABLE_GRAPHS=1$'; then echo off; else echo on; fi
}

set_graphs() {
  local want="$1" i
  [ "$want" = on ] || want=off
  if [ "$(graphs_now)" != "$want" ]; then
  "$LMS" daemon down >/dev/null 2>&1
  for i in $(seq 30); do pgrep -x llmster >/dev/null || break; sleep 1; done
  if [ "$want" = off ]; then
    GGML_CUDA_DISABLE_GRAPHS=1 "$LMS" daemon up >/dev/null 2>&1 8>&- 9>&-
  else
    env -u GGML_CUDA_DISABLE_GRAPHS "$LMS" daemon up >/dev/null 2>&1 8>&- 9>&-
  fi
  fi
  # 8>&- 9>&- — демон не повинен успадкувати замок прогону (.lock на fd 8 у v4, 9 у v3), інакше він тримає його вічно
  # сервер (порт 1234) після daemon up стартує не одразу — чекати, поки справді відповідає
  for i in $(seq 30); do
    "$LMS" server start >/dev/null 2>&1
    curl -sf -m 3 http://localhost:1234/v1/models >/dev/null && break
    sleep 2
  done
  curl -sf -m 3 http://localhost:1234/v1/models >/dev/null && [ "$(graphs_now)" = "$want" ]
}
