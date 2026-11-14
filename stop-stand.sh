#!/bin/bash
# 14.11: безпечно зупинити прогін стенду так, щоб продовжити з останнього завершеного етапу.
#   ./stop-stand.sh --dry   — лише показати, що буде зупинено, і з якого етапу продовжувати
#   ./stop-stand.sh         — зупинити
# Що зберігається: кожен ЗАВЕРШЕНИЙ етап — коміт моделі в каталозі сайту + рядок у logs/meta.tsv.
# Що губиться завжди: етап, що йшов у момент зупинки (продовження почне його з коміту попереднього).
# Порядок: спершу opencode (окрема група процесів через setsid — сама не вмирає), далі run-v4.sh
# (його trap гасить llama-server і проксі), далі чекаємо, поки обгортка start-full-shop-resume.sh
# сама перенесе logs/ в archive/full-shop-<час>-<частина>. hubjob пришле «❌ помилка» — це очікувано.
# Змінні латиницею (кирилиця ламає масиви й for).
V=/home/alex/v4_stand; T=/home/alex/v4_test
DRY=0; [ "${1:-}" = "--dry" ] && DRY=1

run=$(pgrep -x -f "bash $V/run-v4.sh")
oc=()
for p in $(pgrep -x opencode); do
  case "$(readlink /proc/$p/cwd 2>/dev/null)" in "$T"/*) oc+=("$p");; esac
done
llama=$(pgrep -x llama-server)
echo "== run-v4.sh: ${run:-нема}; opencode у $T: ${oc[*]:-нема}; llama-server: ${llama:-нема}"

# З якого етапу продовжувати: остання спроба з перевіркою 0 → +1 (окремо для кожної моделі).
resume_hint() {
  local meta="$1"
  [ -s "$meta" ] || { echo "== meta.tsv порожній — продовження з того ж start=, що й зараз"; return; }
  awk -F'\t' 'NR>1 && $8=="0" {ok[$2]=$3} NR>1 {seen[$2]=1}
    END {for (m in seen) printf "== %s: останній пройдений етап %s → у черзі start=%s\n", m, (m in ok ? ok[m] : "—"), (m in ok ? ok[m]+1 : "той самий, що був")}' "$meta"
  for d in "$T"/shop/*/; do
    [ -d "$d/.git" ] && echo "== сайт $(basename "$d"): HEAD $(git -C "$d" log -1 --format='%h %s' | cut -c1-90); незакомічено шляхів: $(git -C "$d" status --short | wc -l)"
  done
}

if [ $DRY = 1 ]; then resume_hint "$V/logs/meta.tsv"; echo "== --dry: нічого не зупинено"; exit 0; fi
[ -z "$run" ] && [ ${#oc[@]} = 0 ] && { echo "== прогін не йде — нічого зупиняти"; resume_hint "$V/logs/meta.tsv"; exit 0; }

# 1) opencode — групою (timeout + opencode + її дочірні: npm, docker compose тощо)
for p in "${oc[@]}"; do
  g=$(ps -o pgid= -p "$p" | tr -d ' '); [ -n "$g" ] && kill -TERM -- "-$g" 2>/dev/null
done
# 2) run-v4.sh — його trap гасить llama-server і проксі
[ -n "$run" ] && kill -TERM "$run" 2>/dev/null
for _ in $(seq 40); do
  pgrep -x -f "bash $V/run-v4.sh" >/dev/null || pgrep -x opencode >/dev/null || break; sleep 1
done
for p in $(pgrep -x opencode); do
  case "$(readlink /proc/$p/cwd 2>/dev/null)" in "$T"/*) kill -9 "$p";; esac
done
[ -n "$(pgrep -x -f "bash $V/run-v4.sh")" ] && kill -9 $(pgrep -x -f "bash $V/run-v4.sh")
# llama-server, якщо trap не встиг (лише той, що запустив стенд — з порту 1262)
for p in $(pgrep -x llama-server); do
  tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | grep -q -- '--port 1262' && kill "$p"
done
# Контейнери, які модель підняла для make test, лишаються — їх чистить наступна спроба сама.

# 3) обгортка переносить logs/ в архів
for _ in $(seq 30); do grep -q '== .*архів:' "$V/archive/full-shop-launch.out" 2>/dev/null && break; sleep 1; done
a=$(grep -o 'архів: .*' "$V/archive/full-shop-launch.out" 2>/dev/null | tail -1 | cut -d' ' -f2)
# сторожа читання (read-guard) обгортка гасить сама після run-v4.sh
echo "== зупинено. $( [ -n "$a" ] && echo "журнали: $a" || echo "архів обгортка не зробила — журнали лишились у logs/")"
echo "== на відеокарті: $(nvidia-smi --query-gpu=memory.used --format=csv,noheader 2>/dev/null)"
meta="$V/logs/meta.tsv"; [ -n "$a" ] && meta="$a/logs/meta.tsv"
resume_hint "$meta"
echo "== далі: новий файл черги з цим start= (як runs-full-shop-resume4.txt) і скрипт продовження — скажи мені, я підготую"
