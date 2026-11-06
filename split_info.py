#!/usr/bin/env python3
"""v4.1 (04.11): частини, на які модель сама поділила етап (stand_split_stage пише V4_SPLIT_DIR/<етап>.json).

split_info.py parts <етап>   → рядки «id<TAB>title» нових частин (3 → 3.1, 3.2 …) для черги run-v4.sh
split_info.py note <частина> → пояснення частини для промпту (мета, результат, перевірка, інші частини)
"""
import json
import os
import sys
from pathlib import Path

D = Path(os.environ["V4_SPLIT_DIR"])


def parts_of(stage):
    return json.loads((D / f"{stage}.json").read_text())["parts"]


def is_last(label):
    """Остання частина на кожному рівні (3.2, 3.2.2) завершує етап — її зараховує повна перевірка етапу."""
    while "." in label:
        parent, k = label.rsplit(".", 1)
        if int(k) != len(parts_of(parent)):
            return False
        label = parent
    return True


def parent_check(label):
    par, k = label.rsplit(".", 1)
    return parts_of(par)[int(k) - 1].get("check", "")


cmd, label = sys.argv[1], sys.argv[2]
if cmd == "parts":
    for i, p in enumerate(parts_of(label), 1):
        print(f"{label}.{i}\t{' '.join(p['title'].split())}")
elif cmd == "note":
    parent, k = label.rsplit(".", 1)
    parts, k = parts_of(parent), int(k)
    p, root = parts[k - 1], label.split(".")[0]
    others = "; ".join(f"{parent}.{i} «{q['title']}»" for i, q in enumerate(parts, 1) if i != k)
    print(f"Це ЧАСТИНА {label} (з {len(parts)}) етапу {parent}: ти сам поділив етап після невдалих спроб. Роби лише цю частину.\n"
          f"Мета частини: {p['title']}\nРезультат після частини: {p['result']}\n"
          + (f"Твоя перевірка частини (має дати код 0): {p['check']}\n" if p.get("check") else "")
          + (f"Це остання частина — вона завершує етап {root}: зараховується лише повною перевіркою етапу.\n" if is_last(label) else
             "Частину зараховує stand_stage_check: твоя команда, гра без помилок, перегляд гри, запис у PROGRESS і коміт.\n")
          + (f"Вона ж завершує частину {parent} — пройти має й її перевірка: {parent_check(parent)}\n"
             if k == len(parts) and "." in parent and parent_check(parent) else "")
          + f"Інші частини (окремими запусками): {others}.\n"
          f"Що вже зроблено — git log і docs/PROGRESS.md; робоче не переписуй. Наприкінці — розділ «Етап {label}» "
          f"у docs/PROGRESS.md і коміт: частина зараховується лише закомічена.")
