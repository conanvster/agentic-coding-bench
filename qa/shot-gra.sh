#!/bin/bash
# qa/shot-gra.sh <каталог роботи моделі> <куди скласти PNG> — копія проєкту + автозавантаження shot-gra.gd, 1408×768.
SRC="$1"; mkdir -p "$2"; OUT=$(readlink -f "$2"); Q=$(dirname "$(readlink -f "$0")")
T=$(mktemp -d); cp -a "$SRC/." "$T/"; cp "$Q/shot-gra.gd" "$T/zz_shot.gd"; mkdir -p "$OUT"
grep -q '^\[autoload\]' "$T/project.godot" || printf '\n[autoload]\n' >> "$T/project.godot"
sed -i '/^\[autoload\]/a ZzShot="*res://zz_shot.gd"' "$T/project.godot"
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 DISPLAY=:0
export XAUTHORITY=$(ls -t /run/user/1000/.mutter-Xwaylandauth.* | head -1) OUT
timeout 120 godot --headless --path "$T" --import > "$OUT/import.log" 2>&1
timeout 120 godot --path "$T" --resolution 1408x768 > "$OUT/run.log" 2>&1; echo "rc=$?"
rm -rf "$T"; ls -la "$OUT"/*.png 2>/dev/null; grep -cE 'ERROR|SCRIPT ERROR' "$OUT/run.log"
