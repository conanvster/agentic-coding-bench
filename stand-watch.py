#!/usr/bin/env python3
"""Сторож стенду (07.11, слово користувача): сповіщення на телефон через хаб (U9, /api/notify → HA).

Читає logs/run.out (переживає перенесення logs/ в архів — чекає нового файлу) і надсилає:
  ✅ кінець задачі моделі: скільки етапів пройдено, де й чому зупинилась; 🏁 кінець прогону;
  ❌ критичне: збій/перезавантаження сервера моделі, запобіжник 5xx, СТОП, немає Docker, ПОТРІБЕН ПОДІЛ,
     зник каталог, не завантажилась модель;
  ⚠ стенд мовчить ≥ 60 хв при живому прогоні; на диску < 8 ГБ.
Стенд не змінює. Запуск: setsid nohup ./stand-watch.py > archive/stand-watch.out 2>&1 &
"""
import json
import os
import re
import shutil
import time
import urllib.request
from pathlib import Path

V = Path("/home/alex/v4_stand")
RUN_OUT = V / "logs" / "run.out"
ENV = {k: v for k, v in (l.split("=", 1) for l in (Path.home() / ".config/hub/env").read_text().splitlines()
                         if "=" in l and not l.lstrip().startswith("#"))}
SILENT_MIN, DISK_GB = 60, 8

CRIT = [
    (r"контекст злетів", "сервер моделі впав — перезавантаження"),
    (r"ЗАПОБІЖНИК", "запобіжник: шквал помилок 5xx"),
    (r"СТОП", "стенд зупинився"),
    (r"немає доступу до Docker", "немає Docker — сайт пропущено"),
    (r"ПОТРІБЕН ПОДІЛ", "модель застрягла, межа поділу — задачу зупинено"),
    (r"каталог моделі .* зник", "модель видалила свій каталог"),
    (r"load failed", "модель не завантажилась"),
    (r"два етапи поспіль не пройшли", "два етапи поспіль не пройшли — задачу зупинено"),
    (r"не вдалося виставити CUDA-графи", "не вдалося виставити CUDA-графи"),
    (r"Traceback", "помилка Python у стенді"),
]


def notify(title, text=""):
    body = json.dumps({"title": title[:120], "text": text[:900]}).encode()
    req = urllib.request.Request(ENV["HUB_URL"].rstrip("/") + "/api/notify", body,
                                 {"Authorization": f"Bearer {ENV['HUB_KEY']}", "Content-Type": "application/json"})
    for i in range(3):
        try:
            urllib.request.urlopen(req, timeout=20).read()
            print(time.strftime("%F %T"), "надіслано:", title, "|", text, flush=True)
            return
        except Exception as e:  # хаб недоступний — повторити, потім лише журнал
            print(time.strftime("%F %T"), "не надіслано:", title, e, flush=True)
            time.sleep(10 * (i + 1))


def run_alive():
    for p in Path("/proc").iterdir():
        if p.name.isdigit():
            try:
                if b"run-v4.sh" in (p / "cmdline").read_bytes():
                    return True
            except OSError:
                pass
    return False


def last_activity():
    logs = V / "logs"
    try:
        return max(f.stat().st_mtime for f in logs.iterdir() if f.is_file())
    except (OSError, ValueError):
        return time.time()


def main():
    state = {}  # модель → {"passed": [...], "task": ...}
    cur = {"slug": None}
    f, ino, warned_silent, warned_disk = None, None, False, False
    first = RUN_OUT.exists()  # старий журнал на момент старту — без сповіщень; новий — з ними
    notify("👀 сторож стенду запущено", "стежу за logs/run.out: кінець задач і прогону, критичні збої")
    while True:
        try:
            st = RUN_OUT.stat()
            if ino != st.st_ino:
                f = open(RUN_OUT, encoding="utf-8", errors="replace")
                if ino is not None:
                    first = False  # новий журнал після старту сторожа — читати з повідомленнями
                ino = st.st_ino
        except FileNotFoundError:
            f, ino = None, None
        quiet = first  # перший прочит наявного журналу — лише відновити стан, без сповіщень про минуле
        first = False if f else first
        lines = f.readlines() if f else []
        say = (lambda *a: None) if quiet else notify
        for line in lines:
            line = line.rstrip()
            m = re.search(r"start (gra|shop) (\S+)", line)
            if m:
                cur["slug"] = None
            m = re.search(r"(gra|shop) (\S+) етап (\S+) спроба (\d+): oc=(\S+) перевірка=(\S+)", line)
            if m:
                task, slug, sid, att, oc, g = m.groups()
                cur["slug"] = slug
                s = state.setdefault(slug, {"passed": [], "task": task, "fails": 0})
                if g == "0":
                    s["passed"].append(sid)
            m = re.search(r"end (gra|shop) (\S+) (\d+)s", line)
            if m:
                task, model, secs = m.group(1), m.group(2), int(m.group(3))
                s = state.get(cur["slug"] or "", {"passed": []})
                why = next((l for l in lines if "вичерпано" in l or "зупинено" in l), "")
                p = s["passed"]
                say(f"✅ {cur['slug'] or model}: {'гра' if task == 'gra' else 'сайт'} завершено",
                       f"{secs / 3600:.1f} год; пройдено етапів: {len(p)}"
                       + (f", останній {p[-1]}" if p else "") + (f"; {why.strip('= ').strip()}" if why else ""))
            if "all done" in line:
                say("🏁 прогін стенду завершено", ", ".join(
                    f"{k}: до {v['passed'][-1] if v['passed'] else '—'}" for k, v in state.items()))
                state.clear()
            for pat, what in CRIT:
                if re.search(pat, line):
                    say(f"❌ стенд: {what}", line.strip("= ").strip())
        if lines:
            warned_silent = False
        if run_alive() and not warned_silent and time.time() - last_activity() > SILENT_MIN * 60:
            notify("⚠ стенд мовчить", f"≥ {SILENT_MIN} хв без нових записів у logs/ — завис?")
            warned_silent = True
        free = shutil.disk_usage("/").free / 1e9
        if free < DISK_GB and not warned_disk:
            notify("⚠ мало місця на диску", f"вільно {free:.1f} ГБ")
            warned_disk = True
        elif free > DISK_GB + 2:
            warned_disk = False
        time.sleep(30)


if __name__ == "__main__":
    main()
