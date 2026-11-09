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
    (r"ПАУЗА: ", "стенд на паузі"),  # v4.5 (09.11): пауза 17:54–19:54 08.11 пройшла без сповіщення
    (r"перевірку зупинено ззовні", "перевірка етапу зависла й зупинена"),
]


SENT = {}  # заголовок → час: те саме критичне не частіше разу на 15 хв (07.11: збій сервера дав 15 сповіщень)


def notify(title, text=""):
    if title.startswith("❌") and time.time() - SENT.get(title, 0) < 900:
        print(time.strftime("%F %T"), "пропущено (повтор):", title, flush=True)
        return
    SENT[title] = time.time()
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


def foreign_gpu():
    """Сторонні процеси на відеокарті (не llama-server/LM Studio): 07.11 Godot з рендером MyWay (1,4 ГБ) поклав qwen3.6 Q4."""
    import subprocess
    try:
        out = subprocess.run(["nvidia-smi", "--query-compute-apps=pid,process_name,used_memory", "--format=csv,noheader"],
                             capture_output=True, text=True, timeout=20).stdout
    except Exception:
        return []
    return [l.strip() for l in out.splitlines() if l.strip() and "llama" not in l and "lmstudio" not in l.lower()]


SPEED = {}  # журнал llama-server → {"pos", "vals", "base", "warned"}
EVAL = re.compile(r"\|\s+eval time =.*?([\d.]+) tokens per second")


def slowdown():
    """v4.5 (09.11): flint на сайті 5 год ішла на 40 % швидкості (оперативку з'їли Chrome/Godot) — і ніхто не знав.
    База — середнє перших 10 відповідей; ⚠, якщо середнє останніх 8 < половини бази."""
    logs = sorted((V / "logs").glob("llama-server-*.log"), key=lambda f: f.stat().st_mtime)
    if not logs:
        return None
    f = logs[-1]
    st = SPEED.setdefault(str(f), {"pos": 0, "vals": [], "base": None, "warned": False})
    try:
        with open(f, encoding="utf-8", errors="replace") as h:
            h.seek(st["pos"])
            for line in h:
                m = EVAL.search(line)
                if m and "prompt eval" not in line:
                    st["vals"].append(float(m.group(1)))
            st["pos"] = h.tell()
    except OSError:
        return None
    v = st["vals"]
    if st["base"] is None and len(v) >= 10:
        st["base"] = sum(v[:10]) / 10
    if st["base"] and len(v) >= 18:
        cur = sum(v[-8:]) / 8
        if cur < st["base"] / 2 and not st["warned"]:
            st["warned"] = True
            return f"{f.name}: {cur:.0f} ток/с проти {st['base']:.0f} на старті — бракує оперативки (своп?) чи чужий процес"
        if cur > st["base"] * 0.7:
            st["warned"] = False
    return None


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
                cur["fresh"] = True  # нова задача: лічильник етапів моделі — з нуля (07.11: Q2 показала 4 замість 2)
            m = re.search(r"(gra|shop) (\S+) етап (\S+) спроба (\d+): oc=(\S+) перевірка=(\S+)", line)
            if m:
                task, slug, sid, att, oc, g = m.groups()
                cur["slug"] = slug
                if cur.pop("fresh", False):
                    state.pop(slug, None)
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
        alien = foreign_gpu() if run_alive() else []
        if alien:
            notify("❌ стенд: чужий процес на відеокарті", "; ".join(alien)[:400] + " — модель може впасти з нестачі пам'яті")
        slow = slowdown() if run_alive() else None
        if slow:
            notify("⚠ стенд: модель сповільнилась удвічі", slow)
        free = shutil.disk_usage("/").free / 1e9
        if free < DISK_GB and not warned_disk:
            notify("⚠ мало місця на диску", f"вільно {free:.1f} ГБ")
            warned_disk = True
        elif free > DISK_GB + 2:
            warned_disk = False
        time.sleep(30)


if __name__ == "__main__":
    main()
