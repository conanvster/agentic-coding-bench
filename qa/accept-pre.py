#!/usr/bin/env python3
"""Незалежна перевірка результатів претесту за ТЗ-сума.md: чорна скринька проти контейнера.
accept.py <порт> → рядок JSON з результатом кожної перевірки."""
import json
import sys
import urllib.error
import urllib.request

port = sys.argv[1]


def get(path):
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=5) as r:
            return r.status, r.headers.get("Content-Type", ""), r.read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.headers.get("Content-Type", ""), e.read().decode(errors="replace")
    except Exception as e:
        return 0, "", str(e)


def js(b):
    try:
        return json.loads(b)
    except ValueError:
        return None


def rez_eq(path, want, exact_type=None):
    st, ct, b = get(path)
    d = js(b)
    if st != 200 or not isinstance(d, dict) or "rez" not in d:
        return False, f"{st} {b[:60]}"
    v = d["rez"]
    ok = isinstance(v, (int, float)) and not isinstance(v, bool) and abs(v - want) < 1e-9
    if exact_type and type(v) is not exact_type:
        ok = False
    return ok, f"{st} {b[:60]}"


def err400(path):
    st, ct, b = get(path)
    d = js(b)
    return st == 400 and isinstance(d, dict) and "error" in d, f"{st} {b[:60]}"


checks = {
    "4+5=9 (ціле)": lambda: rez_eq("/sum?num1=4&num2=5", 9, int),
    "2.5+0.5=3": lambda: rez_eq("/sum?num1=2.5&num2=0.5", 3),
    "-3+7=4": lambda: rez_eq("/sum?num1=-3&num2=7", 4),
    "-3.7+5.8≈2.1": lambda: (lambda st_ct_b: (st_ct_b[0] == 200 and abs((js(st_ct_b[2]) or {}).get("rez", 1e9) - 2.1) < 1e-6,
                                               f"{st_ct_b[0]} {st_ct_b[2][:60]}"))(get("/sum?num1=-3.7&num2=5.8")),
    "abc → 400": lambda: err400("/sum?num1=abc&num2=5"),
    "без num2 → 400": lambda: err400("/sum?num1=4"),
    "порожнє → 400": lambda: err400("/sum?num1=&num2=5"),
    "інший шлях → 404": lambda: (get("/other")[0] == 404, str(get("/other")[0])),
    "JSON Content-Type": lambda: ("json" in get("/sum?num1=1&num2=2")[1], get("/sum?num1=1&num2=2")[1]),
    "nan → 400 (додатково)": lambda: err400("/sum?num1=nan&num2=1"),
    "inf → 400 (додатково)": lambda: err400("/sum?num1=inf&num2=1"),
}
res = {}
for name, fn in checks.items():
    try:
        ok, info = fn()
    except Exception as e:
        ok, info = False, f"виняток {e}"
    res[name] = [bool(ok), info]
print(json.dumps(res, ensure_ascii=False))
