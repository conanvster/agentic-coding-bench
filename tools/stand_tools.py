#!/usr/bin/env python3
"""Stand v4 tools for coding agents — an MCP server (stdio, JSON-RPC 2.0, no dependencies).

Tools (same for every model):
  read_lines  — file with line anchors "12:a3f| code" (hashline); anchors are copied into edit_lines
  edit_lines  — replace / insert / delete by anchors; no retyping of old text; tabs kept; result validated
  write_file  — whole file; creates folders; validates syntax (gd, tscn, py, json, sh, js) right away
  godot_run   — runs Godot safely: no hangs (timeout + quit), modal error windows captured as text,
                screenshots + a text report of what the camera sees (for models without vision too)
  stage_check — the stage gate (same as the old `stage-check` command)

Test from a shell:  python3 stand_tools.py call <tool> '<json args>'   (in the project folder)
Env: V4_WORKDIR (project folder; default cwd), V4_TASK, V4_STAGE, V4_STAND (this stand), REAL_GODOT.
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

STAND = Path(os.environ.get("V4_STAND", Path(__file__).resolve().parent.parent))
WD = Path(os.environ.get("V4_WORKDIR") or os.getcwd())
SHIM = STAND / "tools" / "alert-shim"
MAX_OUT = 24000  # v4.1 (04.11): було 7000 — кінець звіту godot_run (список скриншотів) міг відрізатись
VISION = os.environ.get("V4_VISION") == "1"  # модель із зором: godot_run повертає скриншот картинкою прямо в результаті


def real_godot():
    if os.environ.get("REAL_GODOT"):
        return os.environ["REAL_GODOT"]
    for d in os.environ.get("PATH", "").split(":"):
        p = Path(d) / "godot"
        if p.exists() and STAND not in p.resolve().parents and "v4_stand" not in d:
            return str(p.resolve())
    return "godot"


# ---------------------------------------------------------------- paths & anchors
def resolve(path):
    p = Path(path)
    if not p.is_absolute():
        p = WD / p
    return p.resolve()


def lhash(text):
    return hashlib.md5(text.rstrip().encode()).hexdigest()[:3]


def anchor_lines(lines, start, end):
    return "\n".join(f"{i}:{lhash(lines[i - 1])}| {lines[i - 1]}" for i in range(start, end + 1))


ANCHOR_PREFIX = re.compile(r"^\s*\d+:[0-9a-f]{3}\| ?")


PLAIN_PREFIX = re.compile(r"^(\s*)(\d+): ?")


def strip_anchor_prefixes(text):
    """Weak models often paste anchors into new text. Remove them when (almost) every line has one.
    v4.1: also plain «12: code» prefixes (gemma-26b, 03.11) — only when the numbers go up one by one."""
    lines = text.split("\n")
    marked = sum(1 for l in lines if ANCHOR_PREFIX.match(l))
    if lines and marked >= max(1, int(0.6 * len([l for l in lines if l.strip()]))):
        return "\n".join(ANCHOR_PREFIX.sub("", l) for l in lines), True
    nums = [PLAIN_PREFIX.match(l) for l in lines if l.strip()]
    if len(nums) >= 2 and all(nums):
        seq = [int(m.group(2)) for m in nums]
        if all(b == a + 1 for a, b in zip(seq, seq[1:])):
            return "\n".join(PLAIN_PREFIX.sub("", l, count=1) for l in lines), True
    return text, False


def uses_tabs(lines):
    tabs = sum(1 for l in lines if l.startswith("\t"))
    spaces = sum(1 for l in lines if l.startswith("    "))
    return tabs > spaces


def to_tabs(text, width=4):
    out = []
    for l in text.split("\n"):
        m = re.match(r"^( +)", l)
        if m and len(m.group(1)) >= width:
            n = len(m.group(1)) // width
            l = "\t" * n + l[n * width:]
        out.append(l)
    return "\n".join(out)


def project_root(p):
    for d in [p.parent, *p.parents]:
        if (d / "project.godot").exists():
            return d
    return None


# ---------------------------------------------------------------- validation
def run(cmd, timeout=60, cwd=None, env=None):
    try:
        r = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout,
                           stdin=subprocess.DEVNULL, errors="replace")
        return r.returncode, r.stdout + r.stderr
    except subprocess.TimeoutExpired as e:
        return 124, ((e.stdout or "") if isinstance(e.stdout, str) else "") + f"\n[timeout {timeout}s]"
    except FileNotFoundError as e:
        return 127, str(e)


def godot_env():
    env = dict(os.environ)
    env["PATH"] = f"{SHIM}:{env.get('PATH', '')}"
    env.setdefault("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    env.setdefault("DISPLAY", ":0")
    return env


def godot_errors(out, limit=25):
    keep, seen = [], set()
    lines = out.splitlines()
    for i, l in enumerate(lines):
        if re.search(r"ERROR|SCRIPT ERROR|Parse Error|Invalid|Failed|crash|signal \d+|handle_crash|has vanished when instantiating", l):
            nxt = lines[i + 1].strip() if i + 1 < len(lines) and lines[i + 1].strip().startswith("at:") else ""
            key = re.sub(r"\d+", "N", l.strip())
            if key in seen:
                continue
            seen.add(key)
            keep.append(l.strip() + (f"   [{nxt}]" if nxt else ""))
    return keep[:limit]


def validate(p):
    """Return (ok, message). Silent success for types we cannot check."""
    ext = p.suffix.lower()
    if ext == ".py":
        rc, out = run([sys.executable, "-m", "py_compile", str(p)], 30)
        return rc == 0, "python syntax OK" if rc == 0 else out.strip()[-800:]
    if ext == ".json":
        try:
            json.loads(p.read_text())
            return True, "JSON OK"
        except ValueError as e:
            return False, f"JSON error: {e}"
    if ext in (".sh", ".bash"):
        rc, out = run(["bash", "-n", str(p)], 15)
        return rc == 0, "bash syntax OK" if rc == 0 else out.strip()[-800:]
    if ext in (".js", ".mjs", ".cjs"):
        rc, out = run(["node", "--check", str(p)], 30)
        return rc == 0, "JS syntax OK" if rc == 0 else out.strip()[-800:]
    if ext in (".gd", ".tscn", ".tres"):
        root = project_root(p)
        if not root:
            return True, "(no project.godot above this file — Godot check skipped)"
        if ext == ".gd":
            rc, out = run([real_godot(), "--headless", "--path", str(root), "--check-only", "--script", str(p)],
                          60, env=godot_env())
            errs = godot_errors(out)
            if rc == 0 and not errs:
                return True, "GDScript compiles OK"
            return False, "GDScript errors:\n" + "\n".join(errs or [out.strip()[-800:]])
        res = "res://" + str(p.relative_to(root))
        rc, out = run([real_godot(), "--headless", "--path", str(root), "-s", str(STAND / "tools" / "load_res.gd"),
                       "--", res], 60, env=godot_env())
        if "LOAD_OK" in out and not godot_errors(out):
            return True, f"{ext[1:]} loads OK in Godot" + (scene_info(p) if ext == ".tscn" else "")
        return False, f"Godot cannot load {res}:\n" + "\n".join(godot_errors(out) or [out.strip()[-800:]])
    return True, ""


def scene_info(p):
    """v4.1: what the saved scene really contains — gemma-26b (03.11) saved a 75-byte scene with only the root node
    from a generator script 16 times and never understood why the camera saw nothing."""
    try:
        text = p.read_text(errors="replace")
    except OSError:
        return ""
    nodes = re.findall(r'(?m)^\[node name="([^"]+)" type="([^"]+)"', text)
    inst = len(re.findall(r'(?m)^\[node name="[^"]+"[^\]]*instance=', text))
    meshes = sum(1 for _, t in nodes if t in ("MeshInstance3D", "CSGBox3D", "CSGMesh3D", "MultiMeshInstance3D"))
    cams = sum(1 for _, t in nodes if t == "Camera3D")
    info = f"\nscene contents: {len(nodes) + inst} nodes ({meshes} meshes, {cams} cameras, {inst} instanced scenes)"
    if len(nodes) + inst <= 1:
        info += ("\nWARNING: only the root node is saved. If you build the scene from a script and save it with "
                 "PackedScene.pack(), every child needs child.owner = root (set it after add_child, also for "
                 "grandchildren) — nodes without owner are NOT saved.")
    return info


# ---------------------------------------------------------------- tools
def t_read_lines(a):
    p = resolve(a["path"])
    if not p.exists():
        near = sorted(x.name for x in p.parent.iterdir())[:30] if p.parent.exists() else []
        return f"ERROR: no such file {p}. Files in {p.parent}: {', '.join(near) or '(folder missing)'}", True
    if p.is_dir():
        items = sorted((x.name + ("/" if x.is_dir() else "")) for x in p.iterdir())
        return f"{p} is a folder: " + ", ".join(items[:200]), False
    lines = p.read_text(errors="replace").split("\n")
    if lines and lines[-1] == "":
        lines = lines[:-1]
    n = len(lines)
    start = max(1, int(a.get("start", 1)))
    count = min(int(a.get("count", 250)), 600)
    end = min(n, start + count - 1)
    head = f"{p.relative_to(WD) if WD in p.parents else p} — lines {start}-{end} of {n}"
    if p.suffix == ".gd" or uses_tabs(lines):
        head += " — indentation: TABS (edit_lines/write_file convert 4 spaces to a tab for you)"
    if n == 0:
        return head + "\n(empty file)", False
    more = f"\n… {n - end} more lines: read_lines with start={end + 1}" if end < n else ""
    return head + "\n" + anchor_lines(lines, start, end) + more, False


def find_anchor(lines, anchor):
    m = re.match(r"^\s*(\d+):([0-9a-f]{3})", str(anchor))
    if not m:
        raise ValueError(f"bad anchor '{str(anchor)[:60]}' — an anchor is the line number + 3 hex chars before '|' in "
                         f"stand_read_lines output, e.g. '12:a3f'. Call stand_read_lines on this file and copy it")
    num, h = int(m.group(1)), m.group(2)
    if 1 <= num <= len(lines) and lhash(lines[num - 1]) == h:
        return num
    hits = [i + 1 for i, l in enumerate(lines) if lhash(l) == h]
    if len(hits) == 1:
        return hits[0]  # file shifted since read — content still identifies the line
    raise ValueError(f"anchor {anchor} does not match the file any more (it changed). "
                     f"Call stand_read_lines again and use the new anchors.")


def t_edit_lines(a):
    p = resolve(a["path"])
    if not p.exists():
        return f"ERROR: no such file {p} — create it with stand_write_file", True
    raw = p.read_text(errors="replace")
    trailing_nl = raw.endswith("\n")
    lines = raw.split("\n")
    if trailing_nl:
        lines = lines[:-1]
    tabs = p.suffix == ".gd" or uses_tabs(lines)
    edits = a.get("edits") or []
    if isinstance(edits, dict):
        edits = [edits]
    if not edits:
        return "ERROR: edits is empty. Example: {\"op\":\"replace\",\"start\":\"12:a3f\",\"end\":\"14:0bc\",\"text\":\"new code\"}", True
    plan, notes = [], []
    try:
        for e in edits:
            op = e.get("op", "replace")
            s = find_anchor(lines, e["start"])
            en = find_anchor(lines, e["end"]) if e.get("end") else s
            if en < s:
                s, en = en, s
            text = e.get("text", "")
            text, stripped = strip_anchor_prefixes(text)
            if stripped:
                notes.append("removed line anchors you pasted into text")
            if tabs:
                text = to_tabs(text)
            new = [] if op == "delete" else text.split("\n")
            if op == "replace":
                plan.append((s, en, new))
            elif op == "insert_after":
                plan.append((en + 1, en, new))
            elif op == "insert_before":
                plan.append((s, s - 1, new))
            elif op == "delete":
                plan.append((s, en, []))
            else:
                return f"ERROR: unknown op '{op}' — use replace, insert_after, insert_before, delete", True
    except (ValueError, KeyError) as err:
        return f"ERROR: {err}", True
    plan.sort(key=lambda x: x[0], reverse=True)
    for i in range(len(plan) - 1):
        if plan[i + 1][1] >= plan[i][0]:
            return "ERROR: two edits overlap — merge them into one edit", True
    first = min(x[0] for x in plan)
    for s, en, new in plan:
        lines[s - 1:en] = new
    p.write_text("\n".join(lines) + ("\n" if trailing_nl or lines else ""))
    last = first + sum(len(n) for _, _, n in plan) + 2
    lo, hi = max(1, first - 3), min(len(lines), last + 3)
    ok, msg = validate(p)
    out = [f"edited {p.name}: {len(plan)} edit(s), now {len(lines)} lines" + (f" ({'; '.join(notes)})" if notes else ""),
           f"lines {lo}-{hi} now (new anchors):", anchor_lines(lines, lo, hi) if lines else "(file empty)"]
    if msg:
        out.append(("CHECK OK: " if ok else "CHECK FAILED — fix this before moving on:\n") + msg)
    return "\n".join(out), not ok


def t_write_file(a):
    p = resolve(a["path"])
    content = a.get("content", "")
    content, stripped = strip_anchor_prefixes(content)
    notes = ["removed line anchors you pasted"] if stripped else []
    if p.suffix == ".gd":
        fixed = to_tabs(content)
        if fixed != content:
            notes.append("converted space indentation to tabs (GDScript)")
        content = fixed
    if content and not content.endswith("\n"):
        content += "\n"
    p.parent.mkdir(parents=True, exist_ok=True)
    existed = p.exists()
    p.write_text(content)
    ok, msg = validate(p)
    n = content.count("\n")
    out = f"{'overwrote' if existed else 'created'} {p} ({n} lines)" + (f" — {'; '.join(notes)}" if notes else "")
    if msg:
        out += "\n" + (("CHECK OK: " if ok else "CHECK FAILED — fix this before moving on:\n") + msg)
    return out, not ok


def png_stats(path):
    try:
        from PIL import Image
    except ImportError:
        return ""
    im = Image.open(path).convert("RGB").resize((176, 96))
    colors = im.getcolors(176 * 96) or []
    colors.sort(reverse=True)
    top = colors[0][0] / (176 * 96) if colors else 1
    distinct = len([c for c in colors if c[0] > 3])
    hexes = ", ".join("#%02x%02x%02x %d%%" % (*c[1], round(100 * c[0] / (176 * 96))) for c in colors[:4])
    verdict = "EMPTY/UNIFORM — nothing visible is rendered" if top > 0.97 or distinct < 4 else "has visible content"
    # v4.1: iq4_xs (03.11) — 394 відтінки майже білого, землі й столу не видно, а звіт казав «has visible content»
    px = list(im.get_flattened_data()) if hasattr(im, "get_flattened_data") else list(im.getdata())
    bright = sum(1 for r, g, b in px if 0.299 * r + 0.587 * g + 0.114 * b > 215) / len(px)
    lower = [q for i, q in enumerate(px) if i >= len(px) // 2]
    bright_low = sum(1 for r, g, b in lower if 0.299 * r + 0.587 * g + 0.114 * b > 215) / len(lower)
    if verdict.startswith("has") and (bright > 0.6 or bright_low > 0.6):  # референс: 4% / 0%
        verdict = (f"WASHED OUT — {bright:.0%} of the frame (lower half {bright_low:.0%}) is near-white: ground, table "
                   f"and horizon are probably not visible (too strong light/exposure, white fog or white materials)")
    return f"{verdict}; main colors: {hexes}; distinct colors: {distinct}"


def t_godot_run(a):
    mode = a.get("mode", "play")
    root = resolve(a.get("project", "."))
    if not (root / "project.godot").exists():
        pr = project_root(root / "x")
        if not pr:
            return f"ERROR: no project.godot in {root} — create the Godot project first", True
        root = pr
    env = godot_env()
    alert_log = Path(tempfile.mkstemp(prefix="alerts-", suffix=".log")[1])
    env["ALERT_LOG"] = str(alert_log)
    timeout = min(int(a.get("timeout", 90)), 300)
    g = real_godot()
    report, shots_out, shot_files, tmp = [], [], [], None
    t0 = time.time()
    if mode == "import":
        rc, out = run([g, "--headless", "--path", str(root), "--import"], timeout, env=env)
    elif mode == "check":
        errs = []
        for f in sorted(x for x in root.rglob("*.gd") if not {".godot", ".git", "addons"} & set(x.parts)):
            ok, msg = validate(f)
            if not ok:
                errs.append(f"{f.relative_to(root)}: {msg}")
        rc, out = run([g, "--headless", "--path", str(root), "--quit-after", "30"], timeout, env=env)
        report.append(f"scripts with errors: {len(errs)}" + ("".join("\n  " + e for e in errs[:10])))
    elif mode == "script":
        script = a.get("script")
        if not script:
            return "ERROR: mode=script needs script (path to a .gd that extends SceneTree or MainLoop)", True
        rc, out = run([g, "--headless", "--path", str(root), "-s", script, "--quit-after",
                       str(int(a.get("frames", 600)))] + list(a.get("args", [])), timeout, env=env)
        if rc == 124:
            report.append("HANG: the script did not finish — call get_tree().quit() (or quit()) when done")
    elif mode == "play":
        tmp = Path(tempfile.mkdtemp(prefix="v4play-"))
        shutil.copytree(root, tmp / "p", ignore=shutil.ignore_patterns(".git", "screenshots"), symlinks=True)
        proj = tmp / "p"
        shutil.copy(STAND / "tools" / "probe.gd", proj / "zz_stand_probe.gd")
        text = (proj / "project.godot").read_text(errors="replace")
        if not re.search(r"(?m)^\[autoload\]", text):
            text += "\n[autoload]\n"
        text = re.sub(r"(?m)^\[autoload\]\s*$", '[autoload]\nZzStandProbe="*res://zz_stand_probe.gd"', text, count=1)
        if a.get("scene"):
            text = re.sub(r'(?m)^run/main_scene=.*$', f'run/main_scene="{a["scene"]}"', text)
        (proj / "project.godot").write_text(text)
        frames = max(30, min(int(a.get("frames", 150)), 3000))
        shots = a.get("screenshots_at") or [frames - 1]
        outd = tmp / "out"
        outd.mkdir()
        env.update(PROBE_OUT=str(outd), PROBE_FRAMES=str(frames), PROBE_SHOTS=",".join(str(int(s)) for s in shots),
                   PROBE_INPUT=a.get("input", ""))
        run([g, "--headless", "--path", str(proj), "--import"], 120, env=env)
        res = a.get("resolution", "1408x768")
        rc, out = run([g, "--path", str(proj), "--resolution", res], timeout, env=env)
        if (outd / "report.txt").exists():
            report.append("SCENE REPORT (what is loaded and what the camera sees):\n" + (outd / "report.txt").read_text()[:9000])
        else:
            report.append("SCENE REPORT: missing — the game crashed or quit before the probe finished")
        shot_dir = WD / ".stand" / "shots"
        shot_dir.mkdir(parents=True, exist_ok=True)
        stamp = time.strftime("%H%M%S")
        for png in sorted(outd.glob("frame-*.png")):
            dst = shot_dir / f"{stamp}-{png.name}"
            shutil.copy(png, dst)
            shots_out.append(f"{dst.relative_to(WD)} — {png_stats(dst)}")
            shot_files.append(dst)
    else:
        return "ERROR: mode must be play, check, script or import", True
    alerts = alert_log.read_text().strip().splitlines() if alert_log.exists() else []
    alert_log.unlink(missing_ok=True)
    if tmp:
        shutil.rmtree(tmp, ignore_errors=True)
    errs = godot_errors(out)
    crashed = bool(re.search(r"handle_crash|Program crashed|signal 11|Segmentation", out))
    lines = [f"godot {mode}: exit code {rc}{' (TIMEOUT — killed after %ds)' % timeout if rc == 124 else ''}"
             f"{' — CRASHED' if crashed else ''}, {time.time() - t0:.0f}s"]
    if alerts:
        lines.append("MODAL ERROR WINDOWS Godot tried to show (a human would see these pop up):")
        lines += ["  " + re.sub(r"^\S+\t", "", x) for x in alerts[:10]]
    lines.append(f"errors ({len(errs)}):" if errs else "errors: none")
    lines += ["  " + e for e in errs]
    if shots_out:  # v4.1: screenshots before the long scene report, so they are never cut off
        lines.append("screenshots (saved; also attached to this result as images for models with vision — LOOK at them "
                     "and compare with the reference / ТЗ; write in docs/PROGRESS.md which file you looked at and what is on it):"
                     if VISION else
                     "screenshots (saved; you have no vision — use the SCENE REPORT below; write in docs/PROGRESS.md which "
                     "file you checked and what the report says is visible):")
        lines += ["  " + s for s in shots_out]
        if any("EMPTY/UNIFORM" in s for s in shots_out):
            lines.append("NOTHING VISIBLE. Check: main.tscn really has child nodes (scene contents in write_file output; a "
                         "scene saved from code keeps only nodes with owner set), Camera3D is current and looks at the "
                         "objects, there is a light or environment, objects are in front of the camera.")
    lines += report
    if a.get("full_log"):
        lines.append("--- full log tail ---\n" + out[-6000:])
    text = "\n".join(lines)
    if len(text) > MAX_OUT:
        text = text[:MAX_OUT] + f"\n… [stand: output cut at {MAX_OUT} chars — run again with fewer frames or full_log=false]"
    bad = rc not in (0,) or crashed or bool(errs) or bool(alerts)
    return text, bad, (shot_files[-2:] if VISION else [])


def t_stage_check(a):
    task, stage = os.environ.get("V4_TASK"), os.environ.get("V4_STAGE")
    if not task or stage is None:
        return "ERROR: stage is not set for this session", True
    rc, out = run([sys.executable, str(STAND / "gate.py"), task, stage], 3000, cwd=str(WD),
                  env=dict(os.environ, PATH=f"{STAND / 'bin'}:{os.environ.get('PATH', '')}"))
    return out[-MAX_OUT:], rc != 0


# v4.1 (04.11, слово користувача): після 3 невдалих спроб модель сама ділить етап на 2–3 частини (3 → 3.1, 3.2;
# застрягла на 3.1 → 3.1.1, 3.1.2, 3.2). Інструмент працює лише в сесії поділу, яку відкриває стенд (V4_SPLIT_ALLOWED=1).
ALWAYS_OK = re.compile(r"^\s*(true|:|exit(\s+0)?\s*$|echo\b|printf\b)|(\|\||;)\s*(true|:|exit\s+0)\s*$", re.I)


def t_split_stage(a):
    cur, sdir = os.environ.get("V4_STAGE"), os.environ.get("V4_SPLIT_DIR")
    if os.environ.get("V4_SPLIT_ALLOWED") != "1" or not sdir or cur is None:
        return ("ERROR: splitting is not available now. The stand offers it itself when a stage fails 3 attempts "
                "(or 2 attempts change nothing). Keep working on the current stage and run stand_stage_check."), True
    stage = str(a["stage"]).strip()
    if stage != cur:
        return f"ERROR: you can split only the current stage {cur!r}; you sent stage={stage!r}.", True
    parts = a["parts"] if isinstance(a["parts"], list) else [a["parts"]]
    if not 2 <= len(parts) <= 3:
        return (f"ERROR: give 2 or 3 parts (you gave {len(parts)}). Each part must fit into one run: one small, "
                f"checkable step."), True
    problems, clean = [], []
    for i, p in enumerate(parts, 1):
        if not isinstance(p, dict):
            problems.append(f"part {i}: must be an object {{title, result, check}}, you sent {p!r:.80}")
            continue
        title, result, check = (" ".join(str(p.get(k) or "").split()) for k in ("title", "result", "check"))
        last = i == len(parts)
        if len(title) < 10:
            problems.append(f"part {i}: 'title' — what to do in this part (a short sentence)")
        if len(result) < 10:
            problems.append(f"part {i}: 'result' — what exists and works after this part (files, what is visible/printed)")
        if not last and not check:
            problems.append(f"part {i}: 'check' — a shell command (run in the project folder) that exits 0 only when "
                            f"this part is really done")
        if check and ALWAYS_OK.search(check):
            problems.append(f"part {i}: check `{check[:80]}` always succeeds — it must test the result "
                            f"(run the game/tests, grep a file, compare output)")
        if check:
            # v4.4 (07.11): qwen3.6 Q4 дала «… | ! grep …» — синтаксична помилка в bash (код 2) приймалась як
            # «ще не зроблено», і частина 4.1 з усіма підчастинами не могла пройти ~2 год
            src, serr = run(["bash", "-n", "-c", check], 10, cwd=str(WD))
            if src != 0:
                problems.append(f"part {i}: check `{check[:120]}` is not valid bash: {serr.strip()[-300:]} — "
                                f"fix the command (e.g. `! cmd | grep` is wrong; use `! (cmd | grep -q x)` or `cmd | grep -vq x`)")
        clean.append({"title": title, "result": result, "check": check})
    if problems:
        return "ERROR: the split is not accepted:\n- " + "\n- ".join(problems) + f"\n{usage('split_stage')}", True
    status = []
    for i, p in enumerate(clean, 1):
        if not p["check"]:
            status.append(f"  {stage}.{i}: no own check (last part — the full stage check decides)")
            continue
        rc, out = run(["bash", "-c", p["check"]], 180, cwd=str(WD), env=godot_env())
        if rc in (126, 127) or re.search(r"syntax error|синтаксична помилка", out, re.I):
            return (f"ERROR: the check of part {i} is broken, not just 'not done yet' (exit {rc}). Output:\n{out[-800:]}\n"
                    f"Fix the command and call split_stage again.\n{usage('split_stage')}"), True
        if i == 1 and rc == 0:
            return (f"ERROR: the check of part 1 already succeeds now (exit 0), so part 1 adds nothing or its check does "
                    f"not test it. Make part 1 the next real step and give a check that fails until it is done.\n"
                    f"Check output:\n{out[-1500:]}\n{usage('split_stage')}"), True
        status.append(f"  {stage}.{i}: check now → exit {rc}" + (" (not done yet — as expected)" if rc else " (already passes)"))
    rc, head = run(["git", "rev-parse", "--short", "HEAD"], 10, cwd=str(WD))
    rec = {"stage": stage, "parts": clean, "reason": str(a.get("reason") or "")[:2000],
           "head": head.strip() if rc == 0 else "", "time": time.strftime("%F %T")}
    Path(sdir).mkdir(parents=True, exist_ok=True)
    (Path(sdir) / f"{stage}.json").write_text(json.dumps(rec, ensure_ascii=False, indent=1))
    names = "\n".join(f"  {stage}.{i}: {p['title']}" for i, p in enumerate(clean, 1))
    return (f"OK: stage {stage} is split into {len(clean)} parts (each is a separate run with fresh context):\n{names}\n"
            f"Checks right now:\n" + "\n".join(status) +
            f"\nThe last part is also checked by the full check of stage {stage}.\n"
            f"Now, before this session ends: commit what already works (git add -A && git commit -m \"Етап {stage}: "
            f"проміжний результат перед поділом\") and write in docs/PROGRESS.md, section «Етап {stage}», what is done "
            f"and what is left. Do not start the parts now. You may call stand_split_stage again to change the split."), False


TOOLS = {
    "read_lines": (t_read_lines, "Read a text file with line anchors like `12:a3f| code`. Use the anchors with edit_lines. "
                   "Reading a folder lists it.",
                   {"path": {"type": "string", "description": "file path (relative to the project folder or absolute)"},
                    "start": {"type": "integer", "description": "first line, default 1"},
                    "count": {"type": "integer", "description": "how many lines, default 250"}}, ["path"]),
    "edit_lines": (t_edit_lines, "Change a file by line anchors from read_lines — no need to retype old code. "
                   "op: replace (lines start..end with text), insert_after, insert_before, delete. "
                   "Several edits at once use anchors from the same read. Returns the new lines with fresh anchors "
                   "and checks syntax (GDScript, scenes, Python, JSON, bash, JS).",
                   {"path": {"type": "string"},
                    "edits": {"type": "array", "items": {"type": "object", "properties": {
                        "op": {"type": "string", "enum": ["replace", "insert_after", "insert_before", "delete"]},
                        "start": {"type": "string", "description": "anchor, e.g. \"12:a3f\""},
                        "end": {"type": "string", "description": "last anchor of the range (optional)"},
                        "text": {"type": "string", "description": "new lines (without anchors)"}},
                        "required": ["op", "start"]}}}, ["path", "edits"]),
    "write_file": (t_write_file, "Create or overwrite a whole file (folders are created). Prefer this over shell "
                   "heredocs. Checks syntax right away (GDScript compiles, .tscn/.tres load in Godot, Python, JSON, bash, JS).",
                   {"path": {"type": "string"}, "content": {"type": "string"}}, ["path", "content"]),
    "godot_run": (t_godot_run, "Run Godot safely (never hangs, modal error windows are returned as text). "
                  "mode=play: run the game, take screenshots and report the scene tree, camera and which meshes are "
                  "really visible (EMPTY/UNIFORM means a blank screen). mode=check: compile every script and start "
                  "headless. mode=script: run a SceneTree script headless (tests). mode=import: import assets.",
                  {"mode": {"type": "string", "enum": ["play", "check", "script", "import"]},
                   "scene": {"type": "string", "description": "play: res:// scene instead of the main scene"},
                   "frames": {"type": "integer", "description": "play: frames to run (default 150)"},
                   "screenshots_at": {"type": "array", "items": {"type": "integer"}, "description": "play: frame numbers"},
                   "input": {"type": "string", "description": "play: scripted input, e.g. \"click 704 384 @60; key SPACE @90; action fire @100\""},
                   "script": {"type": "string", "description": "script: path to .gd"},
                   "args": {"type": "array", "items": {"type": "string"}},
                   "timeout": {"type": "integer", "description": "seconds, default 90"},
                   "full_log": {"type": "boolean"}}, []),
    "stage_check": (t_stage_check, "Run the acceptance check of the current stage. Fix every ✗ it reports.", {}, []),
    "split_stage": (t_split_stage, "Only when the stand asks you to: split the current stage that failed into 2–3 "
                    "smaller sequential parts (3 → 3.1, 3.2, 3.3). Each part is one run; parts except the last need a "
                    "shell `check` that exits 0 only when the part is done; the last part is checked by the full stage check.",
                    {"stage": {"type": "string", "description": "the current stage label, e.g. \"3\" or \"3.1\""},
                     "parts": {"type": "array", "items": {"type": "object", "properties": {
                         "title": {"type": "string", "description": "what to do in this part"},
                         "result": {"type": "string", "description": "what exists and works after it"},
                         "check": {"type": "string", "description": "shell command, exit 0 only when the part is done"}},
                         "required": ["title", "result"]}},
                     "reason": {"type": "string", "description": "why the stage got stuck"}}, ["stage", "parts"]),
}


EXAMPLES = {
    "read_lines": {"path": "scripts/player.gd", "start": 1, "count": 120},
    "edit_lines": {"path": "scripts/player.gd",
                   "edits": [{"op": "replace", "start": "12:a3f", "end": "14:0bc", "text": "var speed := 5.0"}]},
    "write_file": {"path": "scenes/main.tscn", "content": "[gd_scene format=3]\n\n[node name=\"Main\" type=\"Node3D\"]\n"},
    "godot_run": {"mode": "play", "frames": 150},
    "stage_check": {},
    "split_stage": {"stage": "3", "reason": "scene file never loaded: parse errors",
                    "parts": [{"title": "Minimal main.tscn: root Node3D, Camera3D, light, ground plane",
                               "result": "game starts without errors, ground visible on the screenshot",
                               "check": "test -s scenes/main.tscn && ! godot --headless --path . --quit 2>&1 | grep -q ERROR"},
                              {"title": "Ramparts, targets, table, sky, fog",
                               "result": "full scene per spec §5 visible on the screenshot"}]},
}


def usage(name):
    return f"Correct call example: stand_{name} {json.dumps(EXAMPLES[name], ensure_ascii=False)}"


def check_args(name, args):
    """v4.1: clear message instead of KeyError: 'path' (gemma-26b gave up the stand tools after 5 of those, 03.11)."""
    _, _, props, req = TOOLS[name]
    if not isinstance(args, dict):
        return f"ERROR: stand_{name} needs a JSON object of arguments, got {type(args).__name__}. {usage(name)}"
    missing = [k for k in req if k not in args or args[k] in (None, "")]
    unknown = [k for k in args if k not in props]
    if missing:
        return (f"ERROR: stand_{name}: missing required argument(s) {', '.join(missing)}. You sent: "
                f"{', '.join(args) or 'nothing'}" + (f" (unknown: {', '.join(unknown)})" if unknown else "") + f". {usage(name)}")
    for k, spec in props.items():
        if k in args and spec.get("type") == "array" and not isinstance(args[k], (list, dict)):
            return f"ERROR: stand_{name}: '{k}' must be a JSON array, you sent {type(args[k]).__name__}. {usage(name)}"
        if k in args and spec.get("type") == "integer":
            try:
                int(args[k])
            except (TypeError, ValueError):
                return f"ERROR: stand_{name}: '{k}' must be a whole number, you sent {args[k]!r}. {usage(name)}"
    if name == "edit_lines":
        edits = args["edits"] if isinstance(args["edits"], list) else [args["edits"]]
        for i, e in enumerate(edits, 1):
            if not isinstance(e, dict):
                return f"ERROR: stand_edit_lines: edit #{i} must be an object {{op, start, end, text}}, you sent {e!r:.80}. {usage(name)}"
            if not e.get("start"):
                return (f"ERROR: stand_edit_lines: edit #{i} has no 'start' anchor. Anchors come from stand_read_lines "
                        f"(the part before '|', e.g. '12:a3f'). {usage(name)}")
    return None


def call(name, args):
    fn = TOOLS[name][0]
    args = args or {}
    problem = check_args(name, args)
    if problem:
        return problem, True, []
    try:
        res = fn(args)
    except Exception as e:  # never kill the server — report to the model
        return (f"ERROR in stand_{name}: {type(e).__name__}: {e}. Arguments you sent: "
                f"{json.dumps(args, ensure_ascii=False)[:300]}. {usage(name)}. If it keeps failing, use another tool "
                f"(e.g. stand_write_file for the whole file)."), True, []
    if len(res) == 2:
        res = (*res, [])
    text, err, images = res
    if err and text.startswith("ERROR") and "example" not in text.lower():
        text += f"\n{usage(name)}"
    return text, err, images


def image_content(path):
    import base64
    return {"type": "image", "data": base64.b64encode(Path(path).read_bytes()).decode(), "mimeType": "image/png"}


def serve():
    def send(obj):
        sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
        sys.stdout.flush()
    for line in sys.stdin:
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        mid, method = msg.get("id"), msg.get("method")
        if mid is None:
            continue  # notification
        if method == "initialize":
            res = {"protocolVersion": msg.get("params", {}).get("protocolVersion", "2025-06-18"),
                   "capabilities": {"tools": {}}, "serverInfo": {"name": "stand", "version": "4.0"}}
        elif method == "tools/list":
            res = {"tools": [{"name": n, "description": d,
                              "inputSchema": {"type": "object", "properties": props, "required": req}}
                             for n, (_, d, props, req) in TOOLS.items()]}
        elif method == "tools/call":
            p = msg.get("params", {})
            if p.get("name") not in TOOLS:
                send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32602, "message": "unknown tool"}})
                continue
            text, err, images = call(p["name"], p.get("arguments"))
            content = [{"type": "text", "text": text}]
            for img in images:
                try:
                    content.append(image_content(img))
                except OSError:
                    pass
            # 05.11 (погоджено користувачем): OpenCode при isError лишає лише текст і викидає картинки
            # (opencode 1.19.5: if(a.isError) throw Error(text…)). Зі скриншотами — без isError, помилки лишаються в тексті.
            if err and len(content) > 1:
                content[0]["text"] = "GODOT REPORTED ERRORS — see the list below; the screenshots are attached anyway.\n" + text
                err = False
            res = {"content": content, "isError": bool(err)}
        elif method == "ping":
            res = {}
        else:
            send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": f"no method {method}"}})
            continue
        send({"jsonrpc": "2.0", "id": mid, "result": res})


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "call":
        text, err, images = call(sys.argv[2], json.loads(sys.argv[3]) if len(sys.argv) > 3 else {})
        print(text)
        for img in images:
            print(f"[image attached: {img}]")
        sys.exit(1 if err else 0)
    serve()
