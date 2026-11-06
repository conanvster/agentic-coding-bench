#!/bin/bash
# Продовження прогону iq4_xs (день 2): з етапу 7. День 1 — archive/iq4-day1-2026-11-01
V=/home/alex/v4_stand
[ -s "$V/logs/run.out" ] && { echo "== СТОП: logs/ не порожній — спершу заархівуй попередній прогін"; exit 1; }
mkdir -p "$V/logs"
START_STAGE=7 GRA_BUDGET=172800 STAGE_CAP=10800 TASKS=gra RUNS_FILE=$V/runs-v4-iq4.txt \
EXTRA_NOTE="Роботу над етапом 7 перервано вчора посередині (пауза стенду, не твоя помилка). Незакомічені файли етапу 7 лежать у каталозі (scripts/hud.gd, crosshair.gd, pause_overlay.gd, game_over_overlay.gd, round_controller.gd, pixel_text.gd, font_atlas.gd, player.gd, tools/font_gen.py, assets/fonts/) — перевір git status, доведи їх до ладу й продовжуй етап 7. Останнє, що ти робив: виправляв помилку розбору в scripts/pixel_text.gd. Користуйся інструментами stand_* (read_lines/edit_lines/write_file/godot_run)." \
nohup "$V/run-v4.sh" > "$V/logs/run.out" 2>&1 &
echo "запущено, PID $!"
