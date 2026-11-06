#!/usr/bin/env python3
"""Проксі між OpenCode і LM Studio (127.0.0.1:1235 → localhost:1234).

Навіщо: у gpt-oss рівень міркування в LM Studio за замовчуванням low, а OpenCode
з @ai-sdk/openai-compatible може не передати reasoningEffort з конфігу
(issue anomalyco/opencode#27361). Проксі сам додає reasoning_effort у кожен запит
до моделі, ім'я якої є в REASONING_EFFORT, і пише рядок журналу на кожен запит.

Запуск: python3 proxy.py [журнал.tsv]
"""
import http.client
import json
import os
import random
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = ("localhost", int(os.environ.get("PROXY_UPSTREAM_PORT", 1234)))
LISTEN = ("127.0.0.1", int(os.environ.get("PROXY_PORT", 1245)))  # v4: 1245 (v3 — 1235)
# Повтор на «The model produced output that does not match the expected peg-native format» (v3, з 2-го претесту).
# Це llama.cpp відкидає вже згенеровану відповідь, бо не розібрав її формат: gpt-oss — зіпсований заголовок каналу
# Harmony (llama.cpp #27720, ~1 % ходів), Qwen3.8 — зайвий <think> (#27733). Відповідь буферизуємо (клієнту йдуть
# лише коментарі SSE «: keepalive», щоб з'єднання не вмирало), і якщо в ній ця помилка — тихо питаємо модель ще раз.
# Невдалі запити зберігаються в PEG_DUMP для аналізу.
PEG_RETRIES_ENV = os.environ.get("PEG_RETRIES")  # якщо задано — перекриває peg_retries з правил (для перевірок)
PEG_MARK = b"peg-native"


def peg_failed(data):
    """Помилка розбору формату — лише як подія помилки: прямий llama-server у кожній відповіді має
    метадані "chat_format":"peg-native" (__lmstudio), це не збій."""
    return PEG_MARK in data and (b"event: error" in data or data.lstrip().startswith(b'{"error"'))
# Кожен запит і відповідь — у logs/req/<модель>/ (з 30.10: щоб відтворювати збої на справжніх запитах; PROXY_DUMP_ALL=0 вимикає)
DUMP_ALL = os.environ.get("PROXY_DUMP_ALL", "1") != "0"
KEEPALIVE_S = 10
# Усе, що залежить від моделі (вибірка, рівень міркування, повернення міркувань, повтори), — у model-rules.json
# (опис: МОДЕЛІ-ПРАВИЛА.md). Читається один раз при старті: правила не міняються посеред прогону.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from model_rules import load as load_rules, rules_for  # noqa: E402

RULES = load_rules()
_cache = {}


def rules(model):
    if model not in _cache:
        _cache[model] = rules_for(model, RULES)
    return _cache[model]


# v4: запобіжник циклу (слово користувача 01.11: «ставити на 3 однакових викликах»). У грі v3 qwen3.6 записала той самий
# файл 92 рази поспіль. Якщо останні LOOP_N викликів інструментів однакові (назва + аргументи) — до результату
# останнього виклику в ЦЬОМУ запиті дописується попередження (історія OpenCode не змінюється).
LOOP_N = int(os.environ.get("LOOP_N", 3))


def loop_guard(messages):
    calls = []
    for m in messages:
        if m.get("role") == "user":
            calls = []
        for tc in m.get("tool_calls") or []:
            f = tc.get("function") or {}
            try:
                args = json.dumps(json.loads(f.get("arguments") or "{}"), sort_keys=True)
            except (ValueError, TypeError):
                args = str(f.get("arguments"))
            calls.append((f.get("name"), args))
    if not calls:
        return 0
    n = 0
    for c in reversed(calls):
        if c != calls[-1]:
            break
        n += 1
    if n < LOOP_N:
        return 0
    idx = next((i for i in range(len(messages) - 1, -1, -1) if messages[i].get("role") == "tool"), None)
    if idx is None or idx < len(messages) - 3:  # після останнього виклику вже було щось інше
        return 0
    last_tool = messages[idx]
    note = (f"\n\n[СТЕНД] Ти {n}-й раз поспіль робиш той самий виклик {calls[-1][0]} з тими самими аргументами — "
            "результат не зміниться. Зупинись, прочитай вивід вище й зміни підхід: інша команда чи файл, "
            "або перечитай свій план і ТЗ.")
    c = last_tool.get("content")
    if isinstance(c, list):
        c.append({"type": "text", "text": note})
    else:
        last_tool["content"] = (c or "") + note
    return n


# v4, 02.11: переповнення контексту. llama-server відповідає 400 «request (N tokens) exceeds the available context size
# (M tokens)», а OpenCode 1.19.5 не впізнає це як переповнення — не стискає розмову, а повторює той самий запит
# безкінечно (етап 7 iq4_xs: 20 тис. повторів за 2 год після читання 51-КБ main.tscn). Тут: найбільший результат
# інструмента обрізаємо так, щоб запит уліз із запасом OVERFLOW_ROOM токенів, і пояснюємо моделі, чому.
OVERFLOW_RE = re.compile(rb"request \((\d+) tokens\) exceeds the available context size \((\d+) tokens\)")
OVERFLOW_ROOM = int(os.environ.get("OVERFLOW_ROOM", 8000))


def _text(c):
    return c if isinstance(c, str) else "".join(x.get("text", "") for x in c if isinstance(x, dict)) if c else ""


def shrink_for_context(req, need_tokens, total_tokens):
    """Обрізає найбільший результат інструмента на need_tokens (+запас). Повертає скільки символів прибрано або 0."""
    msgs = req.get("messages", [])
    tools = [(len(_text(m.get("content"))), i) for i, m in enumerate(msgs) if m.get("role") == "tool"]
    if not tools:
        return 0
    size, idx = max(tools)
    chars_all = sum(len(_text(m.get("content"))) + len(m.get("reasoning_content") or "") for m in msgs) or 1
    per_tok = max(2.0, chars_all / max(total_tokens, 1))
    cut = int((need_tokens + OVERFLOW_ROOM) * per_tok)
    keep = size - cut
    if keep < 500:
        keep = min(500, size)
    if keep >= size:
        return 0
    text = _text(msgs[idx].get("content"))
    note = (f"\n\n[СТЕНД] Вивід обрізано: показано {keep} з {size} символів — разом з розмовою він не вміщався "
            "у вікно контексту моделі. Великі файли читай частинами: stand_read_lines з start/count "
            "(або read з offset/limit), шукай потрібне через grep.")
    msgs[idx]["content"] = text[:keep] + note
    return size - keep


# Повернення попередніх міркувань у ланцюжку інструментів: OpenCode з `interleaved` шле їх у reasoning_content для
# всіх кроків; тут — у полі passback.field правил моделі і лише за останні passback.keep кроків після останнього
# повідомлення користувача (у gpt-oss за етап набирається до 126 тис. токенів роздумів — усе не вміститься).
REASONING_FIELDS = ("reasoning", "reasoning_content", "reasoning_text", "thinking")


def passback(model, messages):
    pb = rules(model).get("passback") or {}
    field, keep_n, step = pb.get("field"), pb.get("keep", 6), pb.get("step", 24)
    last_user = max((i for i, m in enumerate(messages) if m.get("role") == "user"), default=-1)
    asst = [i for i, m in enumerate(messages) if m.get("role") == "assistant" and i > last_user]
    # Ступінчасте вікно (гра 1: ковзне вікно щокроку міняло історію за ~12 повідомлень від кінця → кеш префікса
    # ламався на кожному запиті; гібридні моделі й SWA перераховували 25–40 тис. токенів). Межа зсувається стрибками
    # по step: роздуми лишаються для keep…keep+step−1 останніх кроків, історія між стрибками лише дописується.
    cut = max(0, (len(asst) - keep_n) // step * step) if step else max(0, len(asst) - keep_n)
    keep = set(asst[cut:]) if field else set()
    kept = chars = 0
    for i, m in enumerate(messages):
        if m.get("role") != "assistant":
            continue
        text = next((m[f] for f in REASONING_FIELDS if isinstance(m.get(f), str) and m[f].strip()), "")
        for f in REASONING_FIELDS:
            m.pop(f, None)
        if i not in keep or not text:
            continue
        if field == "content" and (not m.get("tool_calls") or (m.get("content") or "").strip()):
            continue
        m[field] = text
        kept += 1
        chars += len(text)
    return kept, chars


# Модель з полем правил "server" (llama-server напряму, lib-direct.sh) — запити на її порт, решта — у LM Studio.
# Суворе чергування ролей (шаблон Mistral/Devstral): після стиснення історії OpenCode дає два повідомлення асистента
# підряд (підсумок + останній текст), шаблон кидає виняток → HTTP 500, і OpenCode повторює той самий запит без паузи
# (претест 5: 12 308 відповідей 500 за 40 хв). Правило "alternate_roles": true — зливати сусідні повідомлення однієї ролі.
def merge_roles(model, messages):
    if not rules(model).get("alternate_roles"):
        return 0
    out, merged = [], 0
    for m in messages:
        prev = out[-1] if out else None
        if (prev and m.get("role") == prev.get("role") and m.get("role") in ("user", "assistant")
                and not prev.get("tool_calls") and isinstance(prev.get("content") or "", str)
                and isinstance(m.get("content") or "", str)):
            text = "\n\n".join(t for t in ((prev.get("content") or "").strip(), (m.get("content") or "").strip()) if t)
            m = {**m, "content": text}
            out[-1] = m
            merged += 1
        else:
            out.append(m)
    messages[:] = out
    return merged


def upstream_of(model):
    srv = rules(model).get("server") if model else None
    return ("localhost", int(srv["port"])) if srv else UPSTREAM


LOG = sys.argv[1] if len(sys.argv) > 1 else None


def log_line(*cols):
    if not LOG:
        return
    with open(LOG, "a") as f:
        f.write("\t".join(str(c) for c in cols) + "\n")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _forward(self, method):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None
        model = effort = ""
        sent = {}
        req_obj = None
        if body and self.path.endswith("/chat/completions"):
            try:
                req = json.loads(body)
                model = req.get("model", "")
                sent = {k: req.get(k) for k in ("temperature", "top_p", "max_tokens") if k in req}
                # чи повертає клієнт моделі її попередні міркування (важливо для gpt-oss і Gemma 4 у ланцюжку інструментів)
                asst = [m for m in req.get("messages", []) if m.get("role") == "assistant"]
                sent["assistant_msgs"] = len(asst)
                sent["with_reasoning"] = sum(1 for m in asst if m.get("reasoning") or m.get("reasoning_content"))
                sent["tools"] = len(req.get("tools") or [])
                sent["passed_back"], sent["passed_chars"] = passback(model, req.get("messages", []))
                sent["loop"] = loop_guard(req.get("messages", []))
                if rules(model).get("alternate_roles"):
                    sent["merged"] = merge_roles(model, req.get("messages", []))
                if rules(model).get("reasoning_effort"):
                    effort = req["reasoning_effort"] = rules(model)["reasoning_effort"]
                    if rules(model).get("server"):  # llama-server напряму бере рівень із chat_template_kwargs
                        req.setdefault("chat_template_kwargs", {})["reasoning_effort"] = effort
                req.update(rules(model)["sampling"])
                if rules(model).get("seed") == "random" and "seed" not in req:  # LM Studio без seed відповідає однаково
                    req["seed"] = random.randrange(1 << 30)
                body = json.dumps(req).encode()
                req_obj = req
            except (ValueError, TypeError):
                pass
        headers = {k: v for k, v in self.headers.items()
                   if k.lower() not in ("host", "content-length", "connection", "accept-encoding")}
        if body is not None:
            headers["Content-Length"] = str(len(body))
        started = time.time()
        if not model:  # не запит до моделі (наприклад, /v1/models) — просто передати
            status, resp_headers, data = self._upstream(method, body, headers, None)
            self._reply(status, resp_headers, data)
            return
        streaming = '"stream": true' in body.decode(errors="ignore").replace('"stream":true', '"stream": true')
        if streaming:  # заголовки одразу: далі до готової відповіді йдуть лише коментарі SSE
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.send_header("Connection", "close")
            self.end_headers()
        retries = 0
        while True:
            status, resp_headers, data = self._upstream(method, body, headers, self._keepalive if streaming else None,
                                                        upstream_of(model))
            # v4.2 (06.11): LM Studio віддає ту саму помилку з кодом 200 усередині потоку SSE (kat, 8c.1) — ловити за текстом
            m = OVERFLOW_RE.search(data[:4000]) if status == 400 or b"exceed" in data[:4000] else None
            if m and req_obj is not None and sent.get("shrunk", 0) < 3:
                need, have = int(m.group(1)), int(m.group(2))
                cut = shrink_for_context(req_obj, need - have, need)
                if cut:
                    sent["shrunk"] = sent.get("shrunk", 0) + 1
                    sent["shrunk_chars"] = sent.get("shrunk_chars", 0) + cut
                    body = json.dumps(req_obj).encode()
                    headers["Content-Length"] = str(len(body))
                    log_line(time.strftime("%F %T"), model, effort or "-", status, f"{time.time() - started:.1f}",
                             len(data), f"переповнення {need}>{have}: обрізано {cut} символів")
                    continue
            if not peg_failed(data):
                break
            self._dump(model, retries, body, data)
            limit = int(PEG_RETRIES_ENV if PEG_RETRIES_ENV is not None else rules(model).get("peg_retries", 0))
            if retries >= limit:
                break
            retries += 1
            log_line(time.strftime("%F %T"), model, effort or "-", status, f"{time.time() - started:.1f}",
                     len(data), f"повтор {retries}/{limit}: peg-native")
        if streaming:
            self._chunk(data)
            self.wfile.write(b"0\r\n\r\n")
        else:
            self._reply(status, resp_headers, data)
        sent["peg_retries"] = retries
        sent["peg"] = peg_failed(data)  # відповідь лишилась зламаною — OpenCode отримав помилку
        if DUMP_ALL:
            self._dump(model, None, body, data)
        log_line(time.strftime("%F %T"), model, effort or "-", status,
                 f"{time.time() - started:.1f}", len(data), "opencode: " + json.dumps(sent))

    def _upstream(self, method, body, headers, keepalive, upstream=UPSTREAM):
        """Повна відповідь моделі; поки чекаємо — keepalive() не рідше ніж раз на KEEPALIVE_S."""
        conn = http.client.HTTPConnection(*upstream, timeout=3600)
        conn.request(method, self.path, body=body, headers=headers)
        resp = conn.getresponse()
        parts, last = [], time.time()
        while True:
            chunk = resp.read1(65536)
            if not chunk:
                break
            parts.append(chunk)
            if keepalive and time.time() - last > KEEPALIVE_S:
                keepalive()
                last = time.time()
        conn.close()
        return resp.status, resp.getheaders(), b"".join(parts)

    def _chunk(self, data):
        if data:
            self.wfile.write(b"%x\r\n%s\r\n" % (len(data), data))
            self.wfile.flush()

    def _keepalive(self):
        self._chunk(b": keepalive\n\n")

    def _reply(self, status, resp_headers, data):
        self.send_response(status)
        for k, v in resp_headers:
            if k.lower() not in ("content-length", "transfer-encoding", "connection"):
                self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)

    def _dump(self, model, retry, body, data):
        if not LOG:
            return
        sub = "peg-fail" if retry is not None else os.path.join("req", model.replace("/", "_"))
        d = os.path.join(os.path.dirname(os.path.abspath(LOG)), sub)
        os.makedirs(d, exist_ok=True)
        tag = f"r{retry}" if retry is not None else f"{time.time():.3f}"
        name = f"{time.strftime('%Y%m%d-%H%M%S')}-{model.replace('/', '_')}-{tag}"
        with open(os.path.join(d, name + ".request.json"), "wb") as f:
            f.write(body)
        with open(os.path.join(d, name + ".response.txt"), "wb") as f:
            f.write(data)

    def do_GET(self):
        self._forward("GET")

    def do_POST(self):
        try:
            self._forward("POST")
        except (BrokenPipeError, ConnectionResetError):
            pass  # OpenCode обірвав з'єднання (ліміт часу етапу) — відповідати нікому


if __name__ == "__main__":
    ThreadingHTTPServer(LISTEN, Handler).serve_forever()
