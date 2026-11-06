#!/usr/bin/env python3
"""Перевірка docs/PLAN.md як чекліста по етапах.

check_plan.py <PLAN.md> all <кількість етапів>  — етап 0: для кожного етапу 1..N є розділ «## Етап N»
                                                  з ≥ 3 пунктами «- [ ]»/«- [x]», і кожен пункт посилається на ТЗ (§…)
check_plan.py <PLAN.md> <N>                     — етап N: розділ є, у ньому ≥ 3 пункти і всі позначені «- [x]»
"""
import re
import sys

path, what = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
parts = re.split(r"(?m)^##\s+Етап\s+(\d+)\b.*$", text)
sections = {int(parts[i]): parts[i + 1] for i in range(1, len(parts) - 1, 2)}
problems = []


def items(n):
    return re.findall(r"(?m)^\s*[-*]\s+\[([ xX])\]\s+(.+)$", sections.get(n, ""))


if what == "all":
    for n in range(1, int(sys.argv[3]) + 1):
        it = items(n)
        if n not in sections:
            problems.append(f"немає розділу «## Етап {n}»")
        elif len(it) < 3:
            problems.append(f"Етап {n}: пунктів чекліста {len(it)}, потрібно ≥ 3 у форматі «- [ ] …»")
        else:
            no_ref = [t for _, t in it if "§" not in t]
            if no_ref:
                problems.append(f"Етап {n}: {len(no_ref)} пунктів без посилання на ТЗ (§…), напр.: {no_ref[0][:70]}")
else:
    n = int(what)
    it = items(n)
    if n not in sections:
        problems.append(f"немає розділу «## Етап {n}»")
    elif len(it) < 3:
        problems.append(f"Етап {n}: пунктів чекліста {len(it)}, потрібно ≥ 3")
    else:
        open_items = [t for mark, t in it if mark == " "]
        for t in open_items:
            problems.append(f"Етап {n}: не виконано — {t[:100]}")

for p in problems:
    print("PLAN.md:", p)
sys.exit(1 if problems else 0)
