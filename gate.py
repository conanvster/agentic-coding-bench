#!/usr/bin/env python3
"""Перевірка етапу v3: кожна підперевірка пише «✓ що» або «✗ що — як виправити».

gate.py <задача gra|shop|pre> <етап N>      (у робочому каталозі агента)
Змінні оточення від run-v4.sh: GATE_NSTAGES — кількість етапів, GATE_SIBLINGS — файл зі списком
сусідніх каталогів на момент старту задачі (щоб помітити роботу поза своєю текою).
Код виходу 0 — усі підперевірки пройшли.
"""
import glob
import os
import re
import signal
import subprocess
import sys
from pathlib import Path

V = Path(__file__).resolve().parent
task = sys.argv[1]
# 02.11: етап може бути частиною — «8a»…«8d» (етап поділено, щоб вмістився в контекст моделі)
# 04.11 (v4.1): ще й частини, на які модель сама поділила етап після невдач: «3.1», «3.1.2», «8b.1» (stand_split_stage)
_m = re.fullmatch(r"(\d+)([a-z]?)((?:\.\d+)*)", sys.argv[2])
if not _m:
    print(f"✗ невідомий етап «{sys.argv[2]}»\n    → етап — число (3), частина стенду (8a) або частина поділу (3.1, 3.1.2)")
    sys.exit(1)
stage, sub, part_path = int(_m.group(1)), _m.group(2), _m.group(3)
label = sys.argv[2]
LABEL_RE = re.escape(label) + r"(?![a-z]|\.?\d)"  # «Етап 3» не зараховує «Етап 3.1» і навпаки
LAST_SUB = os.environ.get("LAST_SUB", "f")  # остання частина — повна перевірка етапу (03.11: етап 8 на 6 частин a–f)
wd = Path.cwd()
results = []

# Частина поділу: опис — у V4_SPLIT_DIR/<батько>.json (пише stand_split_stage; моделі каталог стенду недоступний).
# Остання частина на кожному рівні (3.2, 3.2.2 …) перевіряється ПОВНОЮ перевіркою етапу; інші — своєю командою check.
PART, PART_LAST = None, True
PART_CHECKS = []  # (мітка, частина): своя команда + команди батьків, які ця частина завершує (3.1.2 завершує 3.1)
if part_path:
    import json
    _cur = f"{stage}{sub}"
    for _k in part_path.strip(".").split("."):
        _f = Path(os.environ.get("V4_SPLIT_DIR", "/nonexistent")) / f"{_cur}.json"
        try:
            _parts = json.loads(_f.read_text())["parts"]
            PART = _parts[int(_k) - 1]
        except (OSError, ValueError, KeyError, IndexError):
            print(f"✗ поділ етапу {_cur} не знайдено (частина {label})\n    → етап ділить лише стенд через stand_split_stage")
            sys.exit(1)
        _cur = f"{_cur}.{_k}"
        _last = int(_k) == len(_parts)
        PART_CHECKS = (PART_CHECKS if _last else []) + [(_cur, PART)]  # завершує батька лише остання на рівні
        PART_LAST = PART_LAST and _last
    PART_CHECKS.reverse()  # спершу своя, далі батьки


def ok(what):
    results.append((True, what, ""))


def bad(what, fix):
    results.append((False, what, fix))


def run(cmd, timeout=3600):
    # зависання (напр. Godot без quit()) — код 124 і вбита вся група процесів, а не падіння перевірки;
    # kat у грі 1 втратила так ~34 хв бюджету
    p = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                         stdin=subprocess.DEVNULL, start_new_session=True)
    try:
        out, _ = p.communicate(timeout=timeout)
        return p.returncode, out
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        out, _ = p.communicate()
        return 124, (out or "") + f"\n[перевірка: команда не завершилась за {timeout} с — зависла? Godot у тесті має закінчуватись quit()]"


def tail(text, n=12):
    return "\n      ".join(text.strip().splitlines()[-n:])


def need_file(path, why, nonempty=True):
    files = glob.glob(path)
    if not files:
        bad(f"немає {path}", f"створи {path}: {why}")
    elif nonempty and all(os.path.getsize(f) == 0 for f in files):
        bad(f"{path} порожній", f"заповни {path}: {why}")
    else:
        ok(f"{path} є")
    return bool(files)


# 04.11: було «\d+ tests?» — хибно ловило echo "Running Stage 5 tests..." (gemma-26b, етапи 5–6). Тепер — лише готовий результат:
# «5 passed», «5 tests passed», «5 тестів пройдено», «passed: 5», «5/5 passed», «TOTAL: 5 passed»; число не зі змінної ($ у рядку — не ловимо)
FAKE_COUNT = re.compile(r"^\s*(?:echo|printf)\b[^\n$]*(?:\b\d+(?:/\d+)?\s+(?:tests?\s+|тест\w*\s+)?(?:passed|пройдено|ok)\b|\b(?:passed|пройдено)\s*[:=]\s*\d+)", re.M | re.I)


def honest_runner(cmd):
    """Підрахунок має брати числа з запуску, а не з тексту скрипта (gpt-oss, гра 1: echo "5 passed")."""
    script = cmd.split()[-1] if cmd.startswith("bash ") else ""
    text = Path(script).read_text(errors="ignore") if script and Path(script).is_file() else ""
    hits = [l.strip() for l in FAKE_COUNT.findall(text)]
    if hits:
        bad(f"{script} друкує готову кількість тестів: {hits[0][:80]}",
            "кількість пройдених має рахувати сам запуск тестів (змінна з результату), а не echo з числом")
    return not hits


def godot_tests_compile(minimum):
    """Кожен тестовий .gd компілюється, і в тестах є перевірки (assert/check/expect) — не менше, ніж заявлено тестів."""
    files = sorted(glob.glob("tests/unit/*.gd") + glob.glob("tests/scenario/*.gd"))
    broken = []
    for f in files:
        rc, out = run(f"godot --headless --path . --check-only --script {f}", 120)
        if rc != 0 or re.search(r"SCRIPT ERROR|Parse Error|Can't load|Failed to load", out):
            broken.append(f"{f}: " + (re.search(r"(?:Parse Error|SCRIPT ERROR|ERROR)[^\n]*", out) or [out.strip()[-120:]])[0][:120])
    if broken:
        bad("тестові файли не компілюються:\n      " + "\n      ".join(broken[:6]),
            "виправ синтаксис; тест, що не компілюється, нічого не перевіряє")
    checks = 0
    for f in files:
        code = re.sub(r"#.*", "", Path(f).read_text(errors="ignore"))
        checks += len(re.findall(r"\b_?(?:assert|check|expect)\w*\s*\(", code))
    if files and checks < minimum:
        bad(f"у тестах лише {checks} викликів перевірок (assert…/check…/expect…), потрібно ≥ {minimum}",
            "кожен тест має порівнювати результат коду з очікуваним за ТЗ")
    return not broken and checks >= minimum


def tests(cmd, minimum=1, what="тести", timeout=3600, godot=False):
    """Тести мають реально виконатися: рахуємо пройдені й проваленні з виводу."""
    honest = honest_runner(cmd)
    compiled = godot_tests_compile(minimum) if godot else True
    if not (honest and compiled):
        return
    rc, out = run(cmd, timeout)
    LAST_TESTS["out"] = out
    if godot and rc == 0 and "Godot Engine v" not in out:
        bad(f"{what}: у виводі `{cmd}` немає запуску Godot", "тести гри мають запускатися в Godot (godot --headless …)")
        return
    passed = sum(int(x) for x in re.findall(r"(\d+)\s+passed", out)) or \
        sum(int(x) for x in re.findall(r"Ran (\d+) tests?", out))
    failed = sum(int(x) for x in re.findall(r"(\d+)\s+failed", out)) + \
        (1 if re.search(r"^FAILED\b", out, re.M) else 0)
    if rc != 0:
        bad(f"{what}: `{cmd}` завершився з кодом {rc}", "виправ причину (вивід нижче), не послаблюючи тести:\n      " + tail(out))
    elif passed < minimum:
        bad(f"{what}: у виводі `{cmd}` знайдено {passed} пройдених тестів, потрібно ≥ {minimum}",
            "команда має реально запускати тести й друкувати їх кількість (напр. «5 passed» або «Ran 5 tests»); "
            "порожня команда чи echo не рахуються:\n      " + tail(out, 6))
    elif failed:
        bad(f"{what}: є проваленні тести ({failed})", "виправ код або тест:\n      " + tail(out))
    else:
        ok(f"{what}: {passed} пройдено, проваленних немає")


# v4.3 (07.11, слово користувача): сайт — копії макетів, справжні e2e, скриншоти 1440 для звірки з макетами
LAST_TESTS = {}
SHOP_INPUTS = Path("/home/alex/v4_test/inputs/shop")
SHOP_SHOTS = ["landing", "catalog", "game", "cart", "receipt"]


def design_copies():
    for name, src in (("landing", "design-landing.jpg"), ("catalog", "design-catalog.jpg")):
        p = Path(f"docs/design/{name}.jpg")
        if not p.exists():
            bad(f"немає docs/design/{name}.jpg", f"скопіюй макет {SHOP_INPUTS / src} у docs/design/{name}.jpg без змін (§0 ТЗ)")
        elif p.read_bytes() != (SHOP_INPUTS / src).read_bytes():
            bad(f"docs/design/{name}.jpg не збігається з макетом {src}", f"скопіюй файл {SHOP_INPUTS / src} без змін (cp)")
        else:
            ok(f"docs/design/{name}.jpg — копія макета")


def e2e_passed(minimum):
    """Playwright справді запустився в make test і пройшов; спеки відкривають сторінки, а не заглушки."""
    out = LAST_TESTS.get("out")
    if out is None:
        return  # make test не запускався — причину вже записав tests()
    specs = glob.glob("e2e/**/*.spec.ts", recursive=True)
    if not any("page.goto" in Path(f).read_text(errors="ignore") for f in specs):
        bad("e2e: жоден e2e/*.spec.ts не відкриває сторінку (page.goto)",
            "E2E-тести мають відкривати сайт у браузері й перевіряти поведінку (§7); заглушки не рахуються")
    pw = sum(int(x) for x in re.findall(r"^\s*(\d+) passed \(\d[\d.]*(?:ms|s|m|h)\)", out, re.M))
    if pw < minimum:
        bad(f"e2e: у виводі make test {pw} пройдених Playwright-тестів, потрібно ≥ {minimum}",
            "make test має запускати Playwright у Docker (§6) і тести мають проходити (рядок «N passed (…s)»):\n      " + tail(out, 6))
    else:
        ok(f"e2e (Playwright): {pw} пройдено")


def screenshots_1440():
    import hashlib
    seen = {}
    for n in SHOP_SHOTS:
        p = Path(f"docs/screenshots/{n}-1440.png")
        if not p.exists():
            bad(f"немає {p}", f"збережи Playwright-скриншот сторінки ({', '.join(SHOP_SHOTS)}) при ширині 1440 px як {p} — для звірки з макетом (§7)")
            continue
        head = p.read_bytes()[:24]
        w = int.from_bytes(head[16:20], "big") if head[:8] == b"\x89PNG\r\n\x1a\n" else None
        if w != 1440:
            bad(f"{p}: ширина {w if w else '— не PNG'}, потрібно 1440", "знімай у Playwright з viewport 1440 px: page.screenshot({ path, fullPage: true })")
            continue
        h = hashlib.sha1(p.read_bytes()).hexdigest()
        if h in seen:
            bad(f"{p} однаковий із {seen[h]}", "кожен скриншот — своя сторінка")
            continue
        seen[h] = p
        ok(f"{p} є, ширина 1440")


def godot_clean():
    if not re.search(r'run/main_scene\s*=', Path("project.godot").read_text() if Path("project.godot").exists() else ""):
        bad("у project.godot не задано головну сцену (run/main_scene)",
            "додай у [application] рядок run/main_scene=\"res://scenes/main.tscn\" — без нього гра не запускається")
        return
    # qwen3.6, гра 1: «SceneBuilder: "res://…"» замість «SceneBuilder="*res://…"» — Godot мовчки пропускає рядок,
    # скрипт не вантажиться, і його помилки компіляції (API Godot 3) не видно на запуску
    text = Path("project.godot").read_text(errors="ignore")
    sect = re.search(r"(?ms)^\[autoload\]\s*$(.*?)(?=^\[|\Z)", text)
    wrong = [l.strip() for l in (sect.group(1) if sect else "").splitlines()
             if l.strip() and not l.strip().startswith(";") and not re.match(r'^\w+="\*?res://[^"]+"$', l.strip())]
    if wrong:
        bad(f"project.godot [autoload]: рядки не в форматі Godot 4, рушій їх мовчки пропускає: {'; '.join(wrong[:4])}",
            'формат: Name="*res://шлях.gd" (зірочка — синглтон)')
    broken = []
    for f in sorted(p for p in Path(".").rglob("*.gd") if not set(p.parts) & {".godot", "addons", ".git"}):
        rc, out = run(f"godot --headless --path . --check-only --script '{f}'", 120)
        if rc != 0 or re.search(r"SCRIPT ERROR|Parse Error", out):
            m = re.search(r"Parse Error:[^\n]*", out)
            broken.append(f"{f}: {(m.group(0) if m else out.strip()[-120:])[:130]}")
    if broken:
        bad(f"скрипти не компілюються ({len(broken)}) — у грі вони не працюють, навіть якщо запуск мовчить:\n      "
            + "\n      ".join(broken[:8]), "виправ під API Godot 4 (напр. SpatialMaterial → StandardMaterial3D)")
    rc, out = run("timeout 120 godot --headless --path . --quit", 180)
    errors = [l for l in out.splitlines() if "ERROR" in l or "GODOT POPUP" in l]
    # v4.2 (06.11): kat — 97 вузлів з parent="Main" (корінь сам Main): Godot лише WARNING, вузли чіпляються до кореня без
    # зміщень батька — камера в 0,0,0 у гільзі. Тепер ✗ з поясненням.
    lost = [l.strip() for l in out.splitlines() if "has vanished when instantiating" in l]
    if lost:
        bad(f"у сцені {len(lost)} вузлів втратили батька — Godot чіпляє їх прямо до кореня й губить позицію батька",
            'у .tscn прямий нащадок кореня має parent=".", онук — parent="Дитина", глибше — parent="Дитина/Онук" '
            "(ніколи не ім'я самого кореня):\n      " + "\n      ".join(lost[:6]))
    # v4: діра 1 v3 — падіння (signal 11, handle_crash) без слова ERROR проходило; тепер код виходу й ознаки падіння
    crashed = re.search(r"handle_crash|Program crashed|signal \d+|Segmentation fault", out)
    if crashed:
        bad("Godot ПАДАЄ при запуску (" + crashed.group(0) + ")",
            "знайди причину (godot_run mode=check, потім play); вивід:\n      " + tail(out, 10))
    elif errors:
        bad(f"Godot при запуску пише помилки ({len(errors)})", "виправ їх:\n      " + "\n      ".join(errors[:8]))
    elif rc not in (0,):
        bad(f"Godot завершився з кодом {rc}", "запусти godot_run mode=check і виправ:\n      " + tail(out, 8))
    else:
        ok("Godot стартує без ERROR і без падіння, головна сцена задана")


def scene_visible():
    """v4: діра 2 v3 — порожня сцена (сірий екран) проходила етапи 3–7. Запуск у вікні через godot_run (play):
    скриншот не однотонний і камера бачить хоча б одну сітку."""
    import tempfile
    sys.path.insert(0, str(V / "tools"))
    import stand_tools as st
    st.WD = Path(tempfile.mkdtemp(prefix="gate-shots-"))
    text = st.t_godot_run({"mode": "play", "project": str(wd), "frames": 120})[0]
    m = re.search(r"visible in camera view: (\d+)", text)
    in_view = int(m.group(1)) if m else 0
    if "SCENE REPORT: missing" in text:
        bad("гра у вікні не дожила до скриншота (падіння або вихід)", "godot_run mode=play — вивід:\n      " + text[:900])
    elif "EMPTY/UNIFORM" in text or in_view == 0:
        # v4.1: сказати, що в main.tscn насправді (gemma-26b 03.11: 75 байт, лише корінь — і так 3 спроби)
        ms = Path("scenes/main.tscn")
        n_nodes = len(re.findall(r"(?m)^\[node ", ms.read_text(errors="ignore"))) if ms.exists() else 0
        why = (f"\n      у scenes/main.tscn збережено вузлів: {n_nodes}" +
               (" — лише корінь: сцену, зібрану скриптом, PackedScene.pack() зберігає тільки вузли з owner = корінь "
                "(задай child.owner = root після add_child, і для вкладених теж)" if n_nodes <= 1 else ""))
        bad(f"екран гри порожній: камера бачить сіток — {in_view}, кадр однотонний або без вмісту",
            "запусти stand_godot_run mode=play і подивись скриншот і звіт сцени: чого бракує (Camera3D current, "
            "MeshInstance3D з mesh, світло)" + why)
    else:
        # v4.2 (06.11): засвічений кадр, закритий кадр і втрачені батьки — ✗, а не лише рядок у звіті
        probs = []
        m = re.search(r"WASHED OUT — [^;]*", text)
        if m:
            probs.append("кадр засвічений: " + m.group(0)[len("WASHED OUT — "):][:160])
        m = re.search(r"BLOCKED VIEW: [^\n]*", text)
        if m:
            probs.append("кадр закрито: " + m.group(0)[len("BLOCKED VIEW: "):][:220])
        m = re.search(r"LOST PARENTS: (\d+)", text)
        if m:
            probs.append(f"{m.group(1)} вузлів втратили батька (див. LOST PARENTS у звіті stand_godot_run)")
        if probs:
            bad(f"гравець не бачить сцени (сіток у полі зору камери {in_view}, але):\n      " + "\n      ".join(probs),
                "запусти stand_godot_run mode=play і прочитай FRAME COVERAGE / BLOCKED VIEW / LOST PARENTS у звіті: "
                "що заповнює кадр і де насправді стоїть камера")
        else:
            ok(f"гра у вікні показує сцену: камера бачить сіток — {in_view}")


def looked_at_game():
    """v4.1 (04.11, слово користувача): модель ОБОВ'ЯЗКОВО дивиться, що вийшло. Після останньої зміни сцени/скриптів/
    ресурсів має бути свіжий скриншот stand_godot_run mode=play (.stand/shots), і в docs/PROGRESS.md у розділі етапу —
    назва цього кадру й що на ньому видно. gemma-26b (03.11) і iq4_xs за всі етапи майже не дивились на гру."""
    src = [f for d in ("scenes", "scripts", "assets") if Path(d).is_dir() for f in Path(d).rglob("*")
           if f.is_file() and f.suffix != ".import"] + [Path("project.godot")]
    newest = max((f.stat().st_mtime for f in src if f.exists()), default=0)
    shots = sorted(Path(".stand/shots").glob("*.png"), key=lambda f: f.stat().st_mtime) if Path(".stand/shots").is_dir() else []
    how = ("запусти stand_godot_run mode=play, подивись скриншот (із зором — картинка прийде в результаті; без зору — "
           "звіт сцени) і порівняй з ТЗ/референсом; виправ, що не так")
    if not shots:
        bad("ти жодного разу не подивився гру: немає скриншотів stand_godot_run (.stand/shots)", how)
        return
    if shots[-1].stat().st_mtime < newest - 1:
        changed = max((f for f in src if f.exists()), key=lambda f: f.stat().st_mtime)
        bad(f"після останньої зміни ({changed}) гру не переглянуто — найсвіжіший скриншот старший", how)
    else:
        ok(f"гру переглянуто після останньої зміни: {shots[-1].name}")
    p = Path("docs/PROGRESS.md")
    text = p.read_text(errors="ignore") if p.exists() else ""
    m = re.search(rf"(?ms)^#+[^\n]*Етап\s+{LABEL_RE}.*?(?=^#+[^\n]*Етап\s|\Z)", text)
    sect = m.group(0) if m else ""
    names = {f.name for f in shots}
    cited = [n for n in re.findall(r"(\d{6}-frame-\d+\.png)", sect) if n in names]
    if not cited:
        bad(f"у розділі «Етап {label}» docs/PROGRESS.md немає, який кадр ти переглянув",
            "допиши рядок «Переглянуто: .stand/shots/<файл>.png — що видно на кадрі (і чого бракує проти ТЗ)»")
    else:
        ok(f"у PROGRESS записано переглянутий кадр: {cited[-1]}")


def tmp_scripts():
    """v4.1: скрипти моделі в /tmp — це робота поза своїм каталогом (gemma-26b 03.11: 30+ gen_scene_v*.gd)."""
    t0 = float(os.environ.get("V4_STAGE_START") or 0)
    if not t0:
        return
    mine = [f for f in Path("/tmp").iterdir() if f.is_file() and f.suffix in (".gd", ".py", ".sh", ".tscn", ".js", ".ts")
            and f.stat().st_uid == os.getuid() and f.stat().st_mtime >= t0]
    if mine:
        bad(f"файли поза робочим каталогом: {', '.join(sorted(f.name for f in mine)[:8])} у /tmp",
            "тимчасові скрипти клади у свій каталог (напр. tools/ або .stand/tmp/), а з /tmp видали свої файли")


def plan(section):
    rc, out = run(f"python3 {V}/check_plan.py docs/PLAN.md {section}")
    if rc:
        example = ("## Етап 3\n      - [x] Сцена main.tscn — scenes/main.tscn — godot --headless --path . --quit (§5)\n"
                   "      - [ ] Наступний пункт — файли — команда перевірки (§…)")
        bad("чекліст docs/PLAN.md:\n      " + tail(out, 10),
            "розділ має виглядати так (заголовок рівно «## Етап N», пункти «- [ ]» / «- [x]», у кожному § з ТЗ):\n      "
            + example + "\n      позначай «- [x]» лише те, що перевірив командою")
    else:
        ok("чекліст docs/PLAN.md у порядку")


def progress():
    p = Path("docs/PROGRESS.md")
    if not p.exists() or not p.read_text().strip():
        bad("немає docs/PROGRESS.md або він порожній",
            "створи docs/PROGRESS.md і допиши розділ про цей етап: що зроблено, що ні, вивід перевірки")
    elif label != "0" and not re.search(rf"Етап\s+{LABEL_RE}", p.read_text()):
        bad(f"у docs/PROGRESS.md немає запису про етап {label}",
            f"допиши розділ «Етап {label}»: що зроблено, що ні, вивід перевірки")
    else:
        ok("docs/PROGRESS.md оновлено")


def committed():
    rc, out = run("git log --oneline -1")
    if rc or not out.strip():
        bad("немає жодного коміту", "git init (якщо треба), git add -A, git commit -m \"…\"")
        return
    rc, st = run("git status --porcelain -- . ':!.stand'")
    if part_path and st.strip():  # v4.1: частина поділу зараховується лише зафіксованою — до неї можна повернутись
        bad("частина поділу не зафіксована: є незакомічені зміни\n      " + tail(st, 6),
            f"закоміть результат частини: git add -A && git commit -m \"Етап {label}: …\"")
    else:
        ok("є коміти" + ("" if not st.strip() else " (є незакомічені зміни — закоміть наприкінці етапу)"))


def part_check():
    """v4.1: команда, яку модель сама задала для частини при поділі (stand_split_stage)."""
    for lab, part in PART_CHECKS:
        cmd = part.get("check")
        if not cmd:
            continue
        rc, out = run(cmd, 900)
        (ok if rc == 0 else lambda w: bad(w, "доведи частину до кінця: цю команду ти сам задав при поділі, вона має "
                                             "завершуватись кодом 0. Вивід:\n      " + tail(out)))(
            f"перевірка частини {lab} «{part['title'][:70]}»: `{cmd[:120]}` → код {rc}")


def siblings():
    snap = os.environ.get("GATE_SIBLINGS")
    if not snap or not Path(snap).exists():
        return
    before = set(Path(snap).read_text().split("\n"))
    now = {p.name for p in wd.parent.iterdir()}
    extra = sorted(now - before - {wd.name})
    if extra:
        bad(f"створено каталоги поза своїм робочим: {', '.join(extra)}",
            f"працюй лише в {wd}; перенеси потрібне сюди, а зайві каталоги видали")
    else:
        ok("поза робочим каталогом нічого не створено")


def user_site():
    # Пакети, поставлені pip --user, ламають середовище наступним моделям (претест 3: gpt-oss поставила Flask 2.1.0
    # у ~/.local — несумісний з Werkzeug 3.1.9, import flask падав у всіх, хто йшов після).
    snap = os.environ.get("GATE_SITE")
    if not snap or not Path(snap).exists():
        return
    before = set(Path(snap).read_text().split("\n"))
    now = {p.name for p in Path.home().glob(".local/lib/python3*/site-packages/*")}
    extra = sorted(now - before)
    if extra:
        bad(f"встановлено пакети в ~/.local (pip --user): {', '.join(extra[:8])}",
            "став залежності лише у віртуальне оточення в робочому каталозі (python3 -m venv .venv); "
            "з ~/.local прибери своє: pip uninstall --user …")
    else:
        ok("~/.local не змінено (pip --user не використано)")


def ascii_names():
    # Імена латиницею (підказка run-v3.sh): кирилиця в іменах файлів, змінних і функцій ламає частину інструментів
    # (bash-масиви, імпорт ресурсів, Docker-томи). Тексти для людини (рядки в лапках, коментарі, docs/) — можна.
    cyr = re.compile(r"[А-Яа-яЇїІіЄєҐґЁё]")
    skip = {".git", ".godot", ".import", "venv", ".venv", "node_modules", "__pycache__", ".pytest_cache", "docs"}
    bad_files, bad_ids = [], []
    decl = re.compile(r"^\s*(?:var|const|func|signal|class_name|enum|def|class|function|let|for|export\s+\w+)\s+[^\s(:=]*" + cyr.pattern)
    assign = re.compile(r"^\s*(?:local\s+|export\s+|readonly\s+)?[^\s=\"'#/]*" + cyr.pattern + r"[^\s=\"']*=")
    for root, dirs, files in os.walk("."):
        dirs[:] = [d for d in dirs if d not in skip]
        for name in dirs + files:
            if cyr.search(name):
                # шлях відносно проєкту, у лапках — щоб було видно пробіл на початку (write " /home/…" створює каталог « »)
                bad_files.append('"' + os.path.join(root, name)[2:] + '"')
        for name in files:
            if not name.endswith((".gd", ".py", ".sh", ".ts", ".tsx", ".js")):
                continue
            path = os.path.join(root, name)
            try:
                lines = open(path, encoding="utf-8", errors="ignore").read().splitlines()
            except OSError:
                continue
            for i, line in enumerate(lines, 1):
                code = re.sub(r"(\"[^\"]*\"|'[^']*')", "", line).split("#")[0].split("//")[0]
                if decl.search(code) or assign.search(code):
                    bad_ids.append(f"{path[2:]}:{i}: {line.strip()[:70]}")
    if bad_files:
        hint = "перейменуй латиницею (A-Z, a-z, 0-9, _ - .; регістр і camelCase — як заведено в мові) і онови посилання"
        if any(p[1:].split("/")[0] != p[1:].split("/")[0].strip() for p in bad_files):
            hint = ("шлях, що починається з пробілу, — випадковий каталог (зайвий пробіл у шляху write/edit); видали саме його, "
                    "наприклад rm -r \"./ \"") + "; " + hint
        bad(f"імена файлів/каталогів з кирилицею (шляхи відносно кореня проєкту): {', '.join(bad_files[:6])}",
            hint + ". Сам каталог проєкту (його абсолютний шлях) не переміщуй і не перейменовуй — він поза перевіркою")
    if bad_ids:
        bad("ідентифікатори з кирилицею:\n      " + "\n      ".join(bad_ids[:8]),
            "імена змінних, функцій, класів, сигналів — латиницею; кирилиця лише в рядках для людини й коментарях")
    if not bad_files and not bad_ids:
        ok("імена латиницею")


def features(prefix, minimum, keywords):
    rc, out = run(f"python3 {V}/check_features.py docs/FEATURES.md {prefix} {minimum} " +
                  " ".join(f"'{k}'" for k in keywords))
    if rc:
        bad("docs/FEATURES.md:\n      " + tail(out, 6),
            f"таблиця «| {prefix}-01 | конкретна функція своїми словами | джерело (рядок .txt / § ТЗ) | тест |», "
            f"≥ {minimum} різних рядків, без заглушок «Feature N»")
    else:
        ok("docs/FEATURES.md у порядку")


def decisions(minimum=5):
    p = Path("docs/DECISIONS.md")
    n = p.read_text().count("→") if p.exists() else 0
    if n < minimum:
        bad(f"docs/DECISIONS.md: рішень у форматі «Питання → Рішення → Чому» {n}, потрібно ≥ {minimum}",
            "запиши неоднозначності ТЗ і свої рішення, кожне рядком «Питання → Рішення → Чому»")
    else:
        ok(f"docs/DECISIONS.md: {n} стрілок «→»")


# --- етапи ------------------------------------------------------------------------------------------
n_stages = int(os.environ.get("GATE_NSTAGES", "0"))
if PART and not PART_LAST:
    # проміжна частина поділу: своя команда, гра запускається без помилок, перегляд гри, журнал, коміт
    part_check()
    if task == "gra" and stage >= 3:
        godot_clean()
        looked_at_game()
    progress()
    committed()
elif stage == 0:
    part_check()
    need_file("docs/PLAN.md", "план-чекліст за всіма етапами")
    progress()
    if Path("docs/PLAN.md").exists():
        plan(f"all {n_stages}")
else:
    part_check()  # остання частина поділу: і своя команда (якщо є), і повна перевірка етапу
    if task == "pre":
        if stage == 1:
            need_file("app.py", "сервіс за §1–2")
            tests("bash run_tests.sh", 5, "тести за §4")
        elif stage == 2:
            need_file("Dockerfile", "образ за §3")
            need_file("README.md", "як зібрати, запустити, перевірити curl-ом")
            rc, out = run(f"bash {V}/check_pretest.sh", 900)
            (ok if rc == 0 else lambda w: bad(w, "виправ рядки з «НІ» вище"))("перевірка сервісу ззовні:\n      " + tail(out, 14))
    elif task == "gra":
        rt = "bash tools/run_tests.sh"
        if stage == 1:
            features("G", 25, ["РАХУНОК", "ПАТРОНИ", "Esc", "гільз", "гвинтівк", "приціл", "seed"])
            decisions()
        elif stage == 2:
            need_file("scripts/game_state.gd", "логіка рахунку, патронів і Game Over (§4)")
            need_file("tests/unit/*.gd", "unit-тести логіки (§7.1)")
            need_file("tools/run_tests.sh", "головний скрипт тестів (§7)")
            tests(rt, 5, "unit-тести", 600, godot=True)
        elif stage == 3:
            godot_clean()
            scene_visible()
        elif stage == 4:
            need_file("tools/blender/*.py", "Blender-скрипти моделей (§5 п.7)")
            need_file("assets/models/*.glb", "експорт моделей; після нових GLB — godot --headless --path . --import")
            godot_clean()
            scene_visible()
        elif stage in (5, 6, 7):
            if stage == 5:
                need_file("scripts/spawner.gd", "спавнер блоків (§4)")
            tests(rt, 5, "тести", 600, godot=True)
            godot_clean()
            scene_visible()
        elif stage == 8 and sub and sub != LAST_SUB:
            tests(rt, 5, "unit і сценарні тести", 900, godot=True)
            need_file("tests/scenario/*.gd", "сценарні тести (§7.2)")
            log = Path("docs/test-log.txt").read_text(errors="ignore") if Path("docs/test-log.txt").exists() else ""
            need_file("docs/test-log.txt", "журнал подій сценарного тесту (§7.2)")
            ev = lambda pat: len(re.findall(rf"(?im)^.*event=\S*({pat})", log))
            want = {"a": [("start|старт", 1, "старт")],
                    "b": [("hit|влуч", 1, "влучання")],
                    "c": [("hit|влуч", 5, "влучання")],
                    "d": [("miss|промах", 1, "промах"), ("fell|horizon|впав|паді", 1, "падіння за горизонт")],
                    "e": [("game_?over", 1, "Game Over"), ("restart|знову|reset", 1, "«Почати знову»"),
                          ("pause|пауз", 1, "пауза")]}[sub]
            for pat, n, what in want:
                k = ev(pat)
                (ok if k >= n else lambda w: bad(w, f"сценарний тест має записати в docs/test-log.txt рядок «frame=N event=… HUD before/after/expected» на кожну подію ({what})"))(
                    f"docs/test-log.txt: подій «{what}» — {k} (треба ≥ {n})")
            shots = {"a": ["start"], "b": ["hit_01"], "c": [f"hit_0{i}" for i in range(1, 6)], "d": [], "e": ["game_over"]}[sub]
            for f in shots:
                path = f"docs/screenshots/{f}.png"
                if need_file(path, "скриншот за §7.2") and os.path.getsize(path) < 10_000:
                    bad(f"{path} менше 10 КБ — схоже на порожній кадр", "зроби знімок справжнього рендеру (vsync вимкнено)")
        elif stage == 8:
            tests(rt, 5, "unit і сценарні тести", 900, godot=True)
            need_file("docs/test-log.txt", "журнал подій сценарного тесту (§7.2)")
            for f in ["hit_01", "hit_05", "game_over", "main_like_reference", "side_by_side"]:
                path = f"docs/screenshots/{f}.png"
                if need_file(path, "скриншот за §7.2–7.3") and os.path.getsize(path) < 10_000:
                    bad(f"{path} менше 10 КБ — схоже на порожній кадр", "зроби знімок справжнього рендеру (vsync вимкнено)")
        elif stage == 9:
            need_file("README.md", "запуск, керування, тести")
            need_file("docs/REPORT.md", "чесний звіт за §11")
            tests(rt, 5, "тести", 600, godot=True)
    elif task == "shop":
        mt = "make test"
        if stage == 1:
            features("F", 60, ["Neon Horizon", "промокод", "кешбек", "Quick View", "фільтр", "чек", "підписк"])
            decisions()
            need_file("docs/design/structure.txt", "копія опису лендінгу (§0)")
            design_copies()
        elif stage == 2:
            need_file("docker-compose.yml", "сервіси db, api, web (§6)")
            need_file("Makefile", "цілі up/down/test/coverage/reset-db (§6)")
            rc, out = run("docker compose config -q")
            (ok if rc == 0 else lambda w: bad(w, tail(out)))("docker compose config коректний")
            mk = Path("Makefile").read_text() if Path("Makefile").exists() else ""
            body = re.search(r"(?ms)^test:.*?(?=^\S|\Z)", mk)
            if not body or "docker" not in body.group(0):
                bad("ціль make test не запускає нічого в Docker", "make test має запускати lint/typecheck/тести в контейнерах (§6); echo не рахується")
            else:
                rc, out = run(mt)
                (ok if rc == 0 else lambda w: bad(w, tail(out)))("make test завершується з кодом 0")
        elif stage == 3:
            need_file("apps/api/prisma/schema.prisma", "схема БД (§3)")
            need_file("apps/api/prisma/migrations/*", "міграції Prisma")
            tests(mt, 1, "make test")
        elif stage in (4, 5, 7):
            tests(mt, 10 if stage == 4 else 20, "make test")
        elif stage == 6:
            need_file("e2e/*.spec.ts", "Playwright-тести (§7)")
            need_file("scripts/check-traceability*", "матриця відповідності (§2)")
            tests(mt, 20, "make test")
            e2e_passed(1)
            screenshots_1440()
        elif stage == 8:
            run("docker compose up --build -d", 1800)
            rc, out = run("curl -sf -o /dev/null -w '%{http_code}' http://localhost:8088/")
            (ok if rc == 0 else lambda w: bad(w, "сайт має відповідати на :8088 після docker compose up --build -d"))(
                f"http://localhost:8088/ → {out.strip() or 'немає відповіді'}")
            tests(mt, 20, "make test")
            e2e_passed(10)  # §7: 10 обов'язкових E2E-сценаріїв
            screenshots_1440()
        elif stage == 9:
            need_file("README.md", "запуск, тести, промокоди, «найновіша» гра")
            need_file("docs/REPORT.md", "чесний звіт за §10")
    if not sub or sub == LAST_SUB:  # проміжні частини не вимагають відмітити весь розділ плану
        plan(str(stage))
    if task == "gra" and stage >= 3:
        looked_at_game()
    progress()
    committed()
siblings()
tmp_scripts()
user_site()
if stage > 0:
    ascii_names()

for good, what, fix in results:
    print(("✓ " if good else "✗ ") + what + ("" if good else "\n    → " + fix))
failed = [r for r in results if not r[0]]
print(f"\nПідсумок: {len(results) - len(failed)} з {len(results)} пройдено" + ("" if not failed else " — виправ пункти з ✗"))
sys.exit(1 if failed else 0)
