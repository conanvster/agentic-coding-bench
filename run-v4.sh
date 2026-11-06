#!/usr/bin/env bash
# v4 (01.11.2026): як v3, але для моделі — чистий світ і кращі інструменти (однаково для всіх моделей):
#  - робочі каталоги й вхідні файли латиницею: /home/alex/v4_test/{inputs,game,shop}/…; заборона лише на код стенду;
#  - MCP-сервер стенду (tools/stand_tools.py): godot_run (без зависань, модальні вікна помилок текстом, скриншоти +
#    звіт сцени), read_lines/edit_lines (якорі рядків), write_file (перевірка синтаксису одразу), stage_check;
#  - обгортка bin/godot для shell: перехоплює вікна помилок (zenity), не дає зависнути;
#  - proxy.py: запобіжник циклу — 3 однакові виклики поспіль → попередження моделі;
#  - моделі із зором бачать скриншоти (opencode.json attachment), на llama-server — mmproj на CPU;
#  - перевірка етапу: падіння Godot і порожній екран — ✗.
# Запуск (з `su - alex`): nohup /home/alex/v4_stand/run-v4.sh > /home/alex/v4_stand/logs/run.out 2>&1 &
# Змінні: TASKS="gra shop", MODELS_ONLY, RUNS_FILE (типово runs-v4.txt).
set -u
V="/home/alex/v4_stand"
T="/home/alex/v4_test"
LMS="${LMS:-$HOME/.lmstudio/bin/lms}"
# 02.11: lms може підняти демон llmster, який живе після стенду й успадкував би дескриптор лока (8) — закриваємо його.
# 03.11: відбиток робочого каталогу — коміт + незакомічені зміни (без службового .stand/)
wd_fp() { (cd "$1" 2>/dev/null && { git rev-parse HEAD 2>/dev/null; git status --porcelain --untracked-files=all -- . ':!.stand' 2>/dev/null; git diff 2>/dev/null; } | md5sum); }
lmsc() { "$LMS" "$@" 8>&-; }
LOGS="$V/logs"
META="$LOGS/meta.tsv"
STASH="$V/stash"
STAGE_CAP="${STAGE_CAP:-2700}"
ATTEMPTS="${ATTEMPTS:-3}"
# 04.11 (v4.1, слово користувача): етап, що не пройшов за ATTEMPTS спроб (або NOPROG_MAX спроб без змін), модель сама ділить
# на 2–3 частини (stand_split_stage): 3 → 3.1, 3.2; застрягла на 3.1 → 3.1.1, 3.1.2, 3.2. Межі — глибина й кількість поділів.
SPLIT_DEPTH="${SPLIT_DEPTH:-3}"   # найглибша частина — 3.1.1.1
SPLIT_MAX="${SPLIT_MAX:-8}"       # поділів на задачу
SPLIT_CAP="${SPLIT_CAP:-1200}"    # секунд на сесію поділу
TASKS="${TASKS:-gra}"
MODELS_ONLY="${MODELS_ONLY:-}"
RUNS_FILE="${RUNS_FILE:-$V/runs-v4.txt}"
export OPENCODE_CONFIG="$V/opencode.json"
# stage-check (перевірка етапу) — без шляху до стенду в підказці; читати каталог стенду моделям заборонено в opencode.json
export PATH="$V/bin:$PATH"
mkdir -p "$LOGS" "$STASH"
# Дисплей для Godot (скриншоти гри, §7): прогін запускають з `su - alex`, де немає змінних графічної сесії.
# Godot типово йде через X11 (Xwayland :0); ключ Xwayland від mutter міняється з кожним входом — беремо поточний.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
[ -z "${WAYLAND_DISPLAY:-}" ] && [ -S "$XDG_RUNTIME_DIR/wayland-0" ] && export WAYLAND_DISPLAY=wayland-0
[ -z "${DISPLAY:-}" ] && [ -S /tmp/.X11-unix/X0 ] && export DISPLAY=:0
[ -z "${XAUTHORITY:-}" ] && XAUTHORITY=$(ls -t "$XDG_RUNTIME_DIR"/.mutter-Xwaylandauth.* 2>/dev/null | head -1) && export XAUTHORITY
echo "== $(date '+%F %T') дисплей: DISPLAY=${DISPLAY:-—} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-—} XAUTHORITY=${XAUTHORITY:-—}"
exec 9> "$V/.lock"
flock -n 9 || { echo "run-v4.sh уже запущено — другий екземпляр не стартує"; exit 1; }
# одна відеокарта: не стартувати, поки йде прогін v3
exec 8> "$HOME/стенд-кодингу/opencode-v3/.lock"
flock -n 8 || { echo "== СТОП: іде прогін v3 (opencode-v3/.lock зайнятий)"; exit 1; }
[ -f "$META" ] || printf 'task\tmodel\tstage\tattempt\tstart\tseconds\toc_rc\tgate_rc\tsteps\tout_tokens\n' > "$META"
mapfile -t RUNS < <(grep -v '^#' "$RUNS_FILE" | grep .)

# CUDA-графи — для кожної моделі свої (model-rules/, проблема xid8-cuda-graphs): демон LM Studio перезапускається
# з GGML_CUDA_DISABLE_GRAPHS=1 або без нього перед завантаженням моделі (lib-graphs.sh).
. "$V/lib-graphs.sh"
# Моделі з полем правил "server" — на llama-server напряму, без LM Studio (lib-direct.sh; gpt-oss з 30.10).
. "$V/lib-direct.sh"
# після перезавантаження ПК сервер LM Studio сам не стартує
lmsc server status 2>&1 | grep -q "not running" && lmsc server start >/dev/null 2>&1
# Рушій llama.cpp: 2.28.2. LM Studio сама вибирає новий після встановлення, а на 2.66.0 gpt-oss ламає формат 12/12
# (model-rules/_загальні.json, issue runtime). Вибрати й перевірити.
RUNTIME="${RUNTIME:-llama.cpp-linux-x86_64-nvidia-cuda12-avx2@2.28.2}"
lmsc runtime select "$RUNTIME" < /dev/null >/dev/null 2>&1
lmsc runtime ls 2>/dev/null | grep "^$RUNTIME " | grep -q '✓' || { echo "== СТОП: не вдалося вибрати рушій $RUNTIME"; exit 1; }
echo "== $(date '+%F %T') рушій $RUNTIME; правила: $(ls "$V/model-rules" | tr '\n' ' ')"
python3 "$V/proxy.py" "$LOGS/proxy.tsv" &
proxy_pid=$!
trap 'kill $proxy_pid 2>/dev/null; direct_stop' EXIT

jsonl_stats() {
  python3 - "$1" <<'PY'
import json, sys
steps = out = 0
for line in open(sys.argv[1]):
    try:
        e = json.loads(line)
    except ValueError:
        continue
    if e.get("type") == "step_finish":
        k = (e.get("part") or {}).get("tokens") or {}
        steps += 1
        out += k.get("output", 0) + k.get("reasoning", 0)
print(f"{steps}\t{out}")
PY
}

session_of() {
  grep -o '"sessionID":"[^"]*"' "$1" | head -1 | cut -d'"' -f4
}

run_oc() {  # wd model log session prompt → код виходу
  local wd="$1" model="$2" log="$3" session="$4" prompt="$5" rc pid
  local sflag=()
  [ -n "$session" ] && sflag=(-s "$session")
  export V4_WORKDIR="$wd"
  # v4.1: модель із зором (opencode.json attachment: true) — godot_run повертає скриншот картинкою прямо в результаті
  export V4_VISION=$(python3 -c 'import json,sys; m=json.load(open(sys.argv[1]))["provider"]["lmv4"]["models"].get(sys.argv[2],{}); print(1 if m.get("attachment") else 0)' "$V/opencode.json" "$model" 2>/dev/null || echo 0)
  setsid bash -c 'cd "$1" && shift && exec timeout --kill-after=30 "$@"' _ "$wd" "${OC_CAP:-$STAGE_CAP}" \
    opencode run --auto --format json -m "lmv4/$model" "${sflag[@]}" "$prompt" < /dev/null >> "$log" 2>> "${log%.jsonl}.stderr" &
  pid=$!
  # Запобіжник: STORM_N відповідей 5xx поспіль для цієї моделі (proxy.tsv) — спробу перервано, код 125.
  # Претест 5: Devstral отримала 12 308 відповідей 500 за 40 хв — OpenCode повторює запит без паузи й не здається.
  local storm=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 10
    if tail -n 2000 "$LOGS/proxy.tsv" 2>/dev/null | awk -F'\t' -v m="$model" -v n="${STORM_N:-30}" \
         '$2==m {s = ($4 ~ /^5/) ? s+1 : 0} END {exit !(s >= n)}'; then
      storm=1; echo "== $(date '+%F %T') ЗАПОБІЖНИК: $model — ${STORM_N:-30} відповідей 5xx поспіль, спробу перервано"
      kill -TERM -- "-$pid" 2>/dev/null; break
    fi
  done
  wait "$pid"; rc=$?
  kill -TERM -- "-$pid" 2>/dev/null; sleep 2; kill -KILL -- "-$pid" 2>/dev/null
  [ "$storm" = 1 ] && rc=125
  return "$rc"
}

ABILITIES="Твої можливості: повний термінал у своєму каталозі (усі шляхи латиницею, обмежень у ньому нема) — залежності став
локально в проєкт (npm install, python -m venv + pip), запускай docker, godot, blender, тести; читай вхідні файли.
Не можна: sudo, git push, вбивати чужі процеси, працювати поза своїм каталогом.
Інструменти стенду (імена саме такі — stand_read_lines, stand_edit_lines, stand_write_file, stand_godot_run, stand_stage_check;
зручніші за shell — користуйся ними; якщо виклик неправильний, інструмент пише, що не так, і дає приклад правильного виклику):
- stand_read_lines — читає файл з якорями рядків «12:a3f| код»; stand_edit_lines — правка за якорями (replace/insert_after/insert_before/
  delete): старий текст не треба передруковувати; після правки — нові якорі й перевірка синтаксису.
- stand_write_file — файл цілком (теки створює сам) з перевіркою синтаксису одразу: GDScript компілюється, .tscn/.tres вантажаться
  в Godot, Python, JSON, bash, JS. Не пиши файли через heredoc (cat <<EOF) — так легко зіпсувати файл.
- stand_godot_run — запуск Godot без зависань: mode=play — гра у вікні, скриншоти й звіт «що бачить камера» (EMPTY/UNIFORM —
  порожній екран, WASHED OUT — пересвічений), вікна помилок Godot приходять текстом; mode=check — компіляція всіх скриптів;
  mode=script — тест-скрипт. Моделям із зором скриншот приходить картинкою прямо в результаті.
- stand_stage_check — перевірка етапу.
- stand_split_stage — поділ етапу на частини; доступний лише тоді, коли стенд сам його запропонує після невдалих спроб.
ОБОВ'ЯЗКОВО (починаючи з етапу 3): після кожної зміни сцени, скриптів чи ресурсів запусти stand_godot_run mode=play і подивись,
що вийшло (із зором — на картинку, без зору — на звіт сцени); порівняй з ТЗ і референсом, виправ розбіжності. У docs/PROGRESS.md
у розділі етапу запиши рядок «Переглянуто: .stand/shots/<файл>.png — що видно на кадрі і чого бракує проти ТЗ».
Без свіжого перегляду гри після останньої зміни етап не зараховується.
Команда godot у терміналі теж не зависає (ліміт 90 с) і друкує вікна помилок текстом; скрипт для -s має викликати quit().
Якщо повторюєш той самий виклик — результат не зміниться, зміни підхід.
Імена — лише латиницею (ASCII): змінні, функції, класи, сигнали, вузли сцен, дії вводу, ключі конфігів і JSON, параметри
командного рядка, файли й каталоги; регістр — як заведено в мові (snake_case, PascalCase, camelCase, UPPER_CASE).
Кирилиця — лише в текстах для людини: написи інтерфейсу, документація, коментарі, коміти.
Сам каталог проєкту не переміщуй, не перейменовуй і не видаляй. Код стенду закритий: виправляй за виводом stand_stage_check;
тести мають справді перевіряти код за ТЗ — перевірка сама компілює тестові файли й шукає підроблений підрахунок."

for run in "${RUNS[@]}"; do
  IFS='|' read -r model slug ctx opts <<< "$run"
  if [ -n "$MODELS_ONLY" ] && ! grep -qw -- "$slug" <<< "$MODELS_ONLY"; then continue; fi
  # правила моделі: model-rules/<файл>.json; 4-те поле runs-файлу (graphs=on|off) перекриває graphs з правил
  graphs=$(python3 "$V/model_rules.py" "$model" graphs 2>> "$LOGS/rules.err")
  case "${opts:-}" in *graphs=on*) graphs=on ;; *graphs=off*) graphs=off ;; esac
  python3 "$V/model_rules.py" "$model" file | grep -q json \
    || echo "== $(date '+%F %T') УВАГА: для $model немає файлу правил — лише загальні (без рекомендованої вибірки)"
  lmsc unload --all >/dev/null 2>&1
  if ! set_graphs "$graphs"; then echo "== $(date '+%F %T') не вдалося виставити CUDA-графи $graphs для $model"; continue; fi
  direct=$(python3 "$V/model_rules.py" "$model" server 2>> "$LOGS/rules.err")
  if [ -n "$direct" ]; then
    if ! direct_start "$model" "$ctx" "$graphs" "$LOGS/llama-server-$slug.log"; then
      echo "== $(date '+%F %T') load failed (llama-server): $model"; continue
    fi
    echo "== $(date '+%F %T') $model: llama-server напряму, порт $DIRECT_PORT, CUDA-графи $graphs"
  else
    echo "== $(date '+%F %T') $model: CUDA-графи $(graphs_now)"
    if ! lmsc load "$model" -c "$ctx" --gpu max --identifier "$model" -y < /dev/null >/dev/null 2>&1; then
      echo "== $(date '+%F %T') load failed: $model"; continue
    fi
  fi

  for task in $TASKS; do
    if [ "$task" = pre ]; then
      tz="$T/inputs/pre/TZ.md"; wd="$T/pre/$slug"; budget="${PRE_BUDGET:-3000}"  # 50 хв на модель, однаково для всіх (слово користувача 30.10; було 2700, потім 1800)
      extra="Твій робочий каталог: '$wd' (уже створено, він поточний)."
    elif [ "$task" = gra ]; then
      tz="$T/inputs/game/TZ.md"; wd="$T/game/$slug"; budget="${GRA_BUDGET:-9000}"
      extra="Ідентифікатор твоєї моделі для імені каталогу: $slug (каталог уже створено, він поточний)."
    else
      if ! docker info >/dev/null 2>&1; then echo "== немає доступу до Docker — магазин пропущено"; continue; fi
      tz="$T/inputs/shop/TZ.md"; wd="$T/shop/$slug"
      budget="${SHOP_BUDGET:-9000}"  # 2,5 год, як гра (слово користувача 30.10; було 14400)
      extra="Розташування проєкту замість ~/cybersphere: '$wd' (каталог уже створено, він поточний)."
    fi
    stages="${STAGES_FILE:-$V/stages-$task.txt}"  # 02.11: STAGES_FILE — інший перелік (напр. етап 8 частинами 8a…8d)
    inputs=$(find "$(dirname "$tz")" -maxdepth 1 -type f ! -name '*.jpg' -printf "'%p' " ; find "$(dirname "$tz")" -maxdepth 1 -type f -name '*.jpg' -printf "'%p' ")
    [ -n "${EXTRA_NOTE:-}" ] && extra="$extra $EXTRA_NOTE"
    extra="$extra Вхідні файли (абсолютні шляхи, лише читати; .jpg бачать лише моделі із зором): $inputs"
    mkdir -p "$wd" "$(dirname "$wd")"
    ls -1 "$(dirname "$wd")" > "$LOGS/.siblings-$task-$slug"
    export GATE_SIBLINGS="$LOGS/.siblings-$task-$slug"
    ls -1 ~/.local/lib/python3*/site-packages 2>/dev/null | grep -v ':$' > "$LOGS/.site-$task-$slug"
    export GATE_SITE="$LOGS/.site-$task-$slug"
    n_stages=$(cut -d'|' -f1 "$stages" | sed 's/[^0-9].*//' | sort -u | grep -c .)  # частини 8a…8d — один етап
    export GATE_NSTAGES="$n_stages"
    stage_list=$(sed 's/|/. /' "$stages")
    task_start=$(date +%s)
    fails_in_row=0
    splits=0
    export V4_SPLIT_DIR="$LOGS/split-$task-$slug" V4_SPLIT_ALLOWED=0
    mkdir -p "$V4_SPLIT_DIR"
    reloads=0
    echo "== $(date '+%F %T') start $task $model"

    { echo "0|Планування: docs/PLAN.md (чекліст по етапах) і docs/PROGRESS.md, код не писати"; cat "$stages"; } > "$LOGS/.stages-$task-$slug"
    # v4.1: черга етапів (а не читання файлу) — поділений етап замінюється своїми частинами просто в черзі
    q_ids=(); q_titles=()
    while IFS='|' read -r a b; do q_ids+=("$a"); q_titles+=("$b"); done < "$LOGS/.stages-$task-$slug"
    qi=0
    while [ "$qi" -lt "${#q_ids[@]}" ]; do
      sid="${q_ids[$qi]}"; title="${q_titles[$qi]}"; qi=$((qi + 1))
      # v4: START_STAGE=N — продовжити з етапу N (каталог моделі вже містить попередні етапи)
      snum=${sid%%[!0-9]*}  # 8a → 8
      [ "$snum" -lt "${START_STAGE:-0}" ] && continue
      part_note=""
      [ "$sid" != "$snum" ] && [[ "$sid" != *.* ]] && part_note="
Це ЧАСТИНА $sid етапу $snum (етап поділено на частини, щоб вмістився в пам'ять моделі): роби лише цю частину, наступні частини будуть окремими запусками. Пиши файл одразу й поступово (спершу мінімальний робочий варіант → запуск → доповнення), а не проєктуй усе в роздумах."
      [[ "$sid" == *.* ]] && part_note="
$(python3 "$V/split_info.py" note "$sid")"
      if [ $(( $(date +%s) - task_start )) -ge "$budget" ]; then
        echo "== бюджет $task вичерпано на етапі $sid"; break
      fi
      log="$LOGS/$task-$slug-s$sid.jsonl"
      gate="stage-check $task $sid"
      export V4_TASK="$task" V4_STAGE="$sid"
      gate_hint="інструмент stand_stage_check (те саме — команда stage-check $task $sid)"
      if [ "$sid" = 0 ]; then
        prompt="Ти — автономний агент-розробник. Велику задачу виконуємо поетапно, кожен етап — окремий запуск. Зараз — ЕТАП 0, ПЛАНУВАННЯ, код не пиши.
ТЗ: '$tz'. Робочий каталог (поточний): '$wd'. $extra
1) Прочитай ТЗ повністю і вхідні текстові файли.
2) Розбери ТЗ пункт за пунктом: кожна вимога, функція і тест, яких вимагає ТЗ, має потрапити в план.
3) Створи docs/PLAN.md — чекліст. Для кожного з етапів 1…$n_stages нижче — розділ із заголовком рівно «## Етап N» і 3–15 пунктів:
   - [ ] що зробити — файли — команда перевірки (§ пункт ТЗ)
   Нумерація — наша (1…$n_stages), навіть якщо ТЗ нумерує свої етапи інакше. Тести, яких вимагає ТЗ, — окремими пунктами.
   Етапи:
$stage_list
4) Наприкінці PLAN.md — розділ «## Покриття ТЗ»: кожен розділ ТЗ → етапи, де він реалізується.
5) Створи docs/PROGRESS.md з розділом «Етап 0 — планування: зроблено».
6) git init (якщо ще нема) і закоміть.
Перевірка етапу: $gate_hint — запусти сам; вона пише, що не так і як виправити; доведи до «Підсумок: … пройдено» без ✗.
$ABILITIES
Питань не став — замовник недоступний."
      else
        prompt="Ти — автономний агент-розробник. Велика задача виконується поетапно; кожен етап — окремий запуск. Зараз ЕТАП $sid з $n_stages: «$title».
ТЗ: '$tz'. Робочий каталог (поточний): '$wd'. $extra План — docs/PLAN.md, журнал — docs/PROGRESS.md.
Порядок:
1) Прочитай docs/PROGRESS.md, розділ «## Етап $snum» у docs/PLAN.md і потрібні розділи ТЗ.$part_note
2) Звір розділ з ТЗ: якщо якоїсь вимоги цього етапу бракує — допиши пунктом «- [ ] … (§…)». Склади todo-список.
3) Виконуй пункти по одному, реалізуючи функціонал ПОВНІСТЮ за ТЗ; після кожного запускай команду, що доводить результат
   (тести, яких вимагає ТЗ, запуск, збірка), виправляй помилки й лише тоді познач «- [x]».
4) Перевірка етапу: $gate_hint — запусти сам; вона пише по пунктах, що не так і як виправити. Доведи до підсумку без ✗.
5) Допиши в docs/PROGRESS.md розділ «Етап $sid»: що зроблено, що ні, вивід перевірки. Закоміть (git commit).
$ABILITIES
Правила: роби лише цей етап; заборонені заглушки (TODO, порожні функції, тести без перевірок, echo замість тестів, «Feature N»),
підганяння під перевірку й відмітка «- [x]» без перевірки; не зупиняйся після першого успіху і не питай дозволу —
замовник недоступний, рішення пиши в docs/DECISIONS.md."
      fi

      session=""; gate_rc=1
      attempt=0; noprog=0
      while [ "$attempt" -lt "$ATTEMPTS" ]; do
        attempt=$((attempt + 1))
        # бюджет задачі — жорсткий: спроба не довша за залишок (раніше перевірявся лише на початку етапу)
        left=$(( budget - ($(date +%s) - task_start) ))
        if [ "$left" -le 0 ]; then echo "== бюджет $task вичерпано на етапі $sid (спроба $attempt)"; break; fi
        OC_CAP=$(( left < STAGE_CAP ? left : STAGE_CAP ))
        st=$(date +%s); st_h=$(date '+%F %T')
        fp0=$(wd_fp "$wd")
        export V4_STAGE_START="$st"  # v4.1: gate шукає скрипти моделі в /tmp, створені з початку спроби
        run_oc "$wd" "$model" "$log" "$session" "$prompt"; oc_rc=$?
        # Пастка: після збою llama-server (напр. Xid 8 на gemma-4-26b при 15,8 ГБ) LM Studio мовчки піднімає модель
        # з контекстом 8192 — далі кожен запит відкидається. Перезавантажити й не зараховувати спробу (до 2 разів).
        # для llama-server напряму — те саме, але ознака збою: процес помер або не відповідає
        if { [ -n "$direct" ] && ! direct_ok; } || { [ -z "$direct" ] && ! lmsc ps 2>/dev/null | grep -q "^$model .* $ctx "; }; then
          reloads=$(( ${reloads:-0} + 1 ))
          echo "== $(date '+%F %T') $model: контекст злетів (збій сервера моделі) — перезавантаження $reloads"
          printf '%s\t%s\t%s\t%s\t%s\t-\t%s\t-\t-\tмодель злетіла, перезавантажено\n' "$task" "$model" "$sid" "$attempt" "$st_h" "$oc_rc" >> "$META"
          if [ -n "$direct" ]; then
            direct_stop; direct_start "$model" "$ctx" "$graphs" "$LOGS/llama-server-$slug.log"
          else
            lmsc unload --all >/dev/null 2>&1
            lmsc load "$model" -c "$ctx" --gpu max --identifier "$model" -y < /dev/null >/dev/null 2>&1
          fi
          [ "$reloads" -le 2 ] && { attempt=$((attempt - 1)); continue; }
        fi
        # каталог моделі зник (gpt-oss, гра 1: перенесла проєкт у ~/Tasks) — далі всі спроби порожні, зупинити прямо
        if [ ! -d "$wd" ]; then
          echo "== $(date '+%F %T') каталог моделі $wd зник (модель перемістила або видалила його) — $task зупинено"
          printf '%s\t%s\t%s\t%s\t%s\t-\t%s\t-\t-\tкаталог моделі зник\n' "$task" "$model" "$sid" "$attempt" "$st_h" "$oc_rc" >> "$META"
          wd_gone=1; break
        fi
        [ -z "$session" ] && session=$(session_of "$log")
        gate_out=$(cd "$wd" && timeout 3600 bash -c "$gate" < /dev/null 2>&1); gate_rc=$?
        printf '%s\n' "$gate_out" > "$LOGS/$task-$slug-s$sid-a$attempt.gate"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$task" "$model" "$sid" "$attempt" "$st_h" "$(( $(date +%s) - st ))" \
          "$oc_rc" "$gate_rc" "$(jsonl_stats "$log")" >> "$META"
        echo "== $(date '+%F %T') $task $slug етап $sid спроба $attempt: oc=$oc_rc перевірка=$gate_rc"
        [ "$gate_rc" = 0 ] && break
        # 03.11: спроба без жодної зміни у файлах — модель не впоралась у межах контексту; дві такі поспіль → етап треба дробити
        if [ "$(wd_fp "$wd")" = "$fp0" ]; then noprog=$((noprog + 1)); else noprog=0; fi
        if [ "$noprog" -ge "${NOPROG_MAX:-2}" ]; then
          echo "== $(date '+%F %T') етап $sid — $noprog спроб поспіль без жодної зміни у файлах"
          break
        fi
        [ -z "$session" ] && continue
        prompt="Перевірка етапу $sid не пройшла. Її вивід (✗ — що не так, → — як виправити):
$(printf '%s\n' "$gate_out" | tail -400)
Продовжуй цей самий етап: виправ кожен пункт з ✗, запусти перевірку ($gate_hint) сам і доведи до підсумку без ✗,
потім онови docs/PROGRESS.md і закоміть."
      done
      [ -n "${wd_gone:-}" ] && break
      # v4.1: етап не пройшов, а бюджет ще є — модель сама ділить його на 2–3 частини (стенд лише перевіряє межі)
      if [ "$gate_rc" != 0 ] && [ $(( budget - ($(date +%s) - task_start) )) -gt 0 ]; then
        depth=$(tr -cd . <<< "$sid" | wc -c)
        if [ "$depth" -ge "$SPLIT_DEPTH" ] || [ "$splits" -ge "$SPLIT_MAX" ]; then
          echo "== $(date '+%F %T') ПОТРІБЕН ПОДІЛ: етап $sid не пройшов, межа поділу (глибина $depth з $SPLIT_DEPTH, поділів $splits з $SPLIT_MAX); $task зупинено"
          printf '%s\t%s\t%s\t%s\t%s\t-\t-\t-\t-\tмежа поділу\n' "$task" "$model" "$sid" "$attempt" "$st_h" >> "$META"
          break
        fi
        why="за $attempt спроб перевірка не пройшла"
        [ "$noprog" -ge "${NOPROG_MAX:-2}" ] && why="$noprog спроб поспіль не змінили жодного файлу"
        export V4_STAGE="$sid" V4_SPLIT_ALLOWED=1
        rm -f "$V4_SPLIT_DIR/$sid.json"
        sp_prompt="СТОП: етап $sid «$title» не вдався — $why. Останній вивід перевірки:
$(printf '%s\n' "$gate_out" | tail -400)

Зараз код НЕ виправляй. Задача цього запуску — поділити етап $sid на 2–3 менші послідовні частини, кожну з яких реально
зробити за один запуск і перевірити. Подумай, на чому саме ти застряг, і зроби першою частиною найменший наступний крок.
1) Виклич stand_split_stage: stage=\"$sid\", reason — чому застряг, parts — 2–3 об'єкти {title, result, check}:
   title — що зробити; result — що існує й працює після частини; check — shell-команда в каталозі проєкту, що дає код 0
   лише коли частина справді зроблена (напр. запуск godot/тестів, grep у файлі). Остання частина завершує весь етап і
   перевіряється повною перевіркою етапу $sid (її check — за бажанням). Частини стануть етапами ${sid}.1, ${sid}.2 …
2) Зафіксуй те, що вже працює: git add -A && git commit -m \"Етап $sid: проміжний результат перед поділом\".
3) У docs/PROGRESS.md, розділ «Етап $sid» — що зроблено, на чому застряг, на які частини поділено.
Кожну частину потім робитимеш окремим запуском зі свіжим контекстом; що зроблено раніше — у git log і docs/PROGRESS.md."
        st=$(date +%s); st_h=$(date '+%F %T')
        for sa in 1 2; do
          left=$(( budget - ($(date +%s) - task_start) )); [ "$left" -le 0 ] && break
          OC_CAP=$(( left < SPLIT_CAP ? left : SPLIT_CAP ))
          run_oc "$wd" "$model" "$log" "$session" "$sp_prompt"
          [ -z "$session" ] && session=$(session_of "$log")
          [ -f "$V4_SPLIT_DIR/$sid.json" ] && break
          sp_prompt="Поділ не записано: інструмент stand_split_stage не викликано або він повернув ERROR. Виклич stand_split_stage
stage=\"$sid\" з 2–3 частинами {title, result, check} і виправ те, на що вказує його повідомлення."
        done
        export V4_SPLIT_ALLOWED=0
        if [ ! -f "$V4_SPLIT_DIR/$sid.json" ]; then
          echo "== $(date '+%F %T') ПОТРІБЕН ПОДІЛ: модель не змогла поділити етап $sid; $task зупинено"
          printf '%s\t%s\t%s\tподіл\t%s\t%s\t-\t-\t-\tмодель не поділила\n' "$task" "$model" "$sid" "$st_h" "$(( $(date +%s) - st ))" >> "$META"
          break
        fi
        splits=$((splits + 1))
        new_ids=(); new_titles=()
        while IFS=$'\t' read -r a b; do new_ids+=("$a"); new_titles+=("$b"); done < <(python3 "$V/split_info.py" parts "$sid")
        q_ids=("${q_ids[@]:0:qi}" "${new_ids[@]}" "${q_ids[@]:qi}")
        q_titles=("${q_titles[@]:0:qi}" "${new_titles[@]}" "${q_titles[@]:qi}")
        echo "== $(date '+%F %T') ПОДІЛ $splits: етап $sid → ${new_ids[*]} (модель поділила сама: $why)"
        printf '%s\t%s\t%s\tподіл\t%s\t%s\t-\t-\t-\t→ %s\n' "$task" "$model" "$sid" "$st_h" "$(( $(date +%s) - st ))" "${new_ids[*]}" >> "$META"
        continue
      fi
      if [ "$gate_rc" = 0 ]; then fails_in_row=0; else fails_in_row=$((fails_in_row + 1)); fi
      if [ "$fails_in_row" -ge 2 ]; then echo "== два етапи поспіль не пройшли — $task зупинено"; break; fi
    done

    echo "== $(date '+%F %T') end $task $model $(( $(date +%s) - task_start ))s"
    [ "$task" = shop ] && (cd "$wd" && docker compose down -v >/dev/null 2>&1)
    mkdir -p "$STASH/$task"; [ -d "$wd" ] && mv "$wd" "$STASH/$task/"; wd_gone=
  done
  direct_stop
done

# v4: результати лишаються в $STASH/<задача>/ (моделям недоступно) — архівувати перед наступним прогоном
lmsc unload --all >/dev/null 2>&1
set_graphs "$(python3 "$V/model_rules.py" "qwen3.8-27b@iq2_xxs" graphs)"
lmsc load "qwen3.8-27b@iq2_xxs" -c 30720 --gpu max --identifier "qwen3.8-27b@iq2_xxs" -y < /dev/null >/dev/null 2>&1
echo "== all done $(date '+%F %T')"
