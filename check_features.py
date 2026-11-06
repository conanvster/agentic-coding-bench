#!/usr/bin/env python3
"""Перевірка docs/FEATURES.md: кількість різних рядків з ID, без шаблонних заглушок, з ключовими словами ТЗ.

check_features.py <файл> <префікс G|F> <мінімум рядків> <ключове слово>...
"""
import re
import sys

path, prefix, minimum, *keywords = sys.argv[1:]
try:
    text = open(path, encoding="utf-8").read()
except OSError:
    print(f"немає {path}")  # без трейсбеку: він показує моделі шлях до стенду
    sys.exit(1)
rows = [l for l in text.splitlines() if re.match(rf"^\W*{prefix}-\d+", l)]
bodies = {re.sub(rf"{prefix}-\d+", "", r).strip(" |-") for r in rows}
problems = []
if len(rows) < int(minimum):
    problems.append(f"рядків з {prefix}-xx: {len(rows)}, потрібно ≥ {minimum}")
if len(bodies) < len(rows):
    problems.append(f"однакових рядків: {len(rows) - len(bodies)}")
stubs = [r for r in rows if re.search(r"\b(Feature|Функція)\s*\d+\b|\|\s*Source\s*\||\|\s*Test\s*\|?\s*$", r)]
if stubs:
    problems.append(f"шаблонні заглушки ({len(stubs)}), напр.: {stubs[0][:80]}")
missing = [k for k in keywords if k.lower() not in text.lower()]
if missing:
    problems.append("не згадано вимог ТЗ: " + ", ".join(missing))
for p in problems:
    print("FEATURES.md:", p)
sys.exit(1 if problems else 0)
