#!/bin/bash
# 09.11 (слово користувача): етапний тест — спільний старт для всіх моделей. Копіює базу (етапи 0–2, зроблені Claude)
# у робочий каталог моделі й фіксує її комітом; node_modules копіюються як є (як після етапу 2).
# deploy_base.sh <каталог бази> <робочий каталог моделі>
set -e
src="$1"; wd="$2"
[ -d "$src" ] || { echo "немає бази $src"; exit 1; }
[ -e "$wd" ] && { echo "$wd уже існує"; exit 1; }
mkdir -p "$(dirname "$wd")"
cp -a "$src" "$wd"
cd "$wd"
git init -q
git add -A
git -c user.name="stand-base" -c user.email="stand@local" commit -qm "Етапи 0–2 (спільна база стенду): план, перелік функцій, рішення, каркас, Docker, make test"
echo "база → $wd ($(git log --oneline | wc -l) коміт)"
