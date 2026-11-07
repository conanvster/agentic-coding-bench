#!/usr/bin/env python3
"""Нічний прибиральник стенду (07.11, слово користувача — «піду спати»).

Вада стенду v4.4.1: тести моделі, запущені нею самою або перевіркою етапу, переживають зупинку
(start_new_session / зовнішній timeout вбиває лише gate.py) і лишаються сиротами під systemd --user.
Зациклений vitest qwen3.6 Q2 так з'їв 9 ГБ оперативки і весь своп.

Раз на хвилину:
  1) сироти — процеси з робочим каталогом у /home/alex/v4_test, чий ланцюжок батьків не доходить
     до run-v4.sh, старші за 10 хв, і лише тест-ранери (vitest/jest/playwright/make test) → убити групу;
     сервери, що модель сама запустила у фоні (npm run dev), не чіпає — щоб не зламати їй e2e;
  2) запобіжник — якщо доступно < 3 ГБ оперативки, убити найбільший node/python із /home/alex/v4_test
     (навіть живу перевірку: краще провалений етап, ніж убитий llama-server).
Кожна дія — у журнал і на телефон. llama-server, opencode, run-v4.sh не чіпає.
"""
import json, os, signal, time, urllib.request
from pathlib import Path

ROOT = "/home/alex/v4_test"
ENV = {k: v for k, v in (l.split("=", 1) for l in (Path.home() / ".config/hub/env").read_text().splitlines()
                         if "=" in l and not l.lstrip().startswith("#"))}
TESTS = ("vitest", "jest", "playwright", "make test", "npm run test", "npm test", "npm exec vitest")
SAFE = ("llama-server", "opencode", "run-v4.sh", "orphan-guard", "stand-watch")


def notify(title, text):
    print(time.strftime("%F %T"), title, "|", text, flush=True)
    try:
        req = urllib.request.Request(ENV["HUB_URL"].rstrip("/") + "/api/notify",
                                     json.dumps({"title": title, "text": text[:900]}).encode(),
                                     {"Authorization": f"Bearer {ENV['HUB_KEY']}", "Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=20).read()
    except Exception as e:
        print("  не надіслано:", e, flush=True)


def info(pid):
    p = Path(f"/proc/{pid}")
    try:
        st = (p / "stat").read_text()
        f = st.rsplit(")", 1)[1].split()
        return {"pid": pid, "ppid": int(f[1]), "pgid": int(f[2]), "start": int(f[19]),
                "cmd": (p / "cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace").strip(),
                "cwd": os.readlink(p / "cwd"),
                "rss": int(next(l.split()[1] for l in (p / "status").read_text().splitlines() if l.startswith("VmRSS")))}
    except (OSError, StopIteration, IndexError, ValueError):
        return None


def under_stand(pid, procs):
    seen = 0
    while pid > 1 and seen < 64:
        i = procs.get(pid)
        if not i:
            return False
        if "run-v4.sh" in i["cmd"]:
            return True
        pid, seen = i["ppid"], seen + 1
    return False


def main():
    hz, boot = os.sysconf("SC_CLK_TCK"), time.time() - float(Path("/proc/uptime").read_text().split()[0])
    notify("🧹 прибиральник стенду запущено", "сироти тестів із v4_test старші 10 хв; запобіжник < 3 ГБ оперативки")
    while True:
        procs = {}
        for d in Path("/proc").iterdir():
            if d.name.isdigit():
                i = info(int(d.name))
                if i:
                    procs[i["pid"]] = i
        mine = [i for i in procs.values() if i["cwd"].startswith(ROOT) and not any(s in i["cmd"] for s in SAFE)]
        done = set()
        for i in mine:
            age = time.time() - (boot + i["start"] / hz)
            if age > 600 and any(t in i["cmd"] for t in TESTS) and not under_stand(i["pid"], procs) and i["pgid"] not in done:
                try:
                    os.killpg(i["pgid"], signal.SIGKILL)
                    done.add(i["pgid"])
                    notify("🧹 стенд: убито сироту", f"{i['cmd'][:150]} ({i['rss'] // 1024} МБ, {age / 60:.0f} хв) у {i['cwd']}")
                except OSError:
                    pass
        avail = int(next(l.split()[1] for l in open("/proc/meminfo") if l.startswith("MemAvailable"))) // 1024
        if avail < 3072:
            big = max((i for i in mine if i["pgid"] not in done and ("node" in i["cmd"] or "python" in i["cmd"])),
                      key=lambda i: i["rss"], default=None)
            if big:
                try:
                    os.killpg(big["pgid"], signal.SIGKILL)
                    notify("❌ стенд: мало пам'яті — убито тест",
                           f"доступно {avail} МБ; {big['cmd'][:150]} ({big['rss'] // 1024} МБ)")
                except OSError:
                    pass
        time.sleep(60)


if __name__ == "__main__":
    main()
