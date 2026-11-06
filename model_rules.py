#!/usr/bin/env python3
"""Правила моделей: каталог model-rules/ — один файл на модель + _загальні.json.

Файл моделі знаходиться за ТОЧНИМ ключем LM Studio у полі "model" (без префіксів і «родин» — щоб не було плутанини,
звідки взялося значення). Поля файлу моделі перекривають _загальні.json; issues додаються до загальних.
Модель без файлу отримує лише загальні правила (вибірки немає — діють значення LM Studio) і позначку unknown.

Як модуль:  from model_rules import load, rules_for;  r = rules_for("openai/gpt-oss-20b")
Як команда: model_rules.py <ключ>            — зведені правила й проблеми моделі
            model_rules.py <ключ> <поле>     — одне поле (для bash: graphs, peg_retries …)
            model_rules.py --check           — перелік файлів, дублікати ключів
"""
import json
import os
import sys
from pathlib import Path

DIR = Path(os.environ.get("MODEL_RULES", Path(__file__).resolve().parent / "model-rules"))
COMMON = "_загальні.json"


def load(path=DIR):
    path = Path(path)
    common = json.loads((path / COMMON).read_text())
    models = {}
    for f in sorted(path.glob("*.json")):
        if f.name == COMMON:
            continue
        r = json.loads(f.read_text())
        if r["model"] in models:
            raise ValueError(f"ключ {r['model']} у двох файлах: {models[r['model']]['_file']} і {f.name}")
        models[r["model"]] = {**r, "_file": f.name}
    return {"common": common, "models": models}


def rules_for(model, rules=None):
    rules = rules or load()
    out = {k: v for k, v in rules["common"].items() if not k.startswith("_")}
    out.setdefault("sampling", {})
    issues = list(out.get("issues") or [])
    own = rules["models"].get(model)
    if own is None:
        out["unknown"] = True
        out["file"] = None
    else:
        for k, v in own.items():
            if k != "issues":
                out[k] = v
        issues += own.get("issues") or []
        out["file"] = own["_file"]
        out.pop("_file", None)
    out["issues"] = issues
    return out


if __name__ == "__main__":
    if sys.argv[1] == "--check":
        r = load()
        for k, v in r["models"].items():
            print(f"{v['_file']:32} {k}")
        sys.exit(0)
    r = rules_for(sys.argv[1])
    if r.get("unknown"):
        print(f"увага: для {sys.argv[1]} немає файлу в {DIR} — лише загальні правила", file=sys.stderr)
    if len(sys.argv) > 2:
        v = r.get(sys.argv[2], "")
        print(v if isinstance(v, (str, int, float)) else json.dumps(v, ensure_ascii=False))
    else:
        print(json.dumps(r, ensure_ascii=False, indent=1))
