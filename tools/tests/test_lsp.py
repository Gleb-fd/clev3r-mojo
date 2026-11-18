#!/usr/bin/env python3
"""Фокусные тесты LSP-сервера Basic Plus (t16).

Запуск из корня репозитория:

    python3 tools/tests/test_lsp.py
    BP_BINARY=/path/to/bp python3 tools/tests/test_lsp.py

Бинарь по умолчанию — <repo>/tools/bp (ignored build output). Тесты НЕ
собирают Mojo и не требуют свежего baseline: при отсутствии бинаря скрипт
падает с кодом 2, а не зеленеет.

Проверяется только доверенная граница LSP (новый C#-функционал не
существует): приватный tmp, project_dir из file URI, изоляция процессов,
JSON-RPC id, UTF-16 позиции, честные диагностики и fail-closed кадрирование.
Все subprocess ограничены по времени, stdin/stdout/stderr захвачены, чужие
процессы/глобальный /tmp/bp_lsp_docs не трогаются.
"""

from __future__ import annotations

import json
import os
import pathlib
import select
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import traceback

ROOT = pathlib.Path(__file__).resolve().parents[2]
BIN = pathlib.Path(
    os.environ.get("BP_BINARY") or (ROOT / "tools" / "bp")
).resolve()
TEST_ROOT = pathlib.Path()
TIMEOUT = 15.0
ACTIVE_CLIENTS: set["Client"] = set()


class LspError(AssertionError):
    pass


class Client:
    """Один процесс `bp lsp`; кадры читаются с жёстким таймаутом."""

    def __init__(self, tmpdir: pathlib.Path, cwd: pathlib.Path | None = None):
        env = dict(os.environ)
        env["TMPDIR"] = str(tmpdir)
        self.proc = subprocess.Popen(
            [str(BIN), "lsp"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            cwd=str(cwd) if cwd else None,
        )
        self.buf = b""
        self.eof = False
        self._stdin_open = True
        ACTIVE_CLIENTS.add(self)

    def send_raw(self, data: bytes) -> None:
        assert self.proc.stdin is not None
        self.proc.stdin.write(data)
        self.proc.stdin.flush()

    def send_frame(self, body: bytes) -> None:
        self.send_raw(b"Content-Length: %d\r\n\r\n" % len(body) + body)

    def send_json(self, obj) -> None:
        body = json.dumps(
            obj, ensure_ascii=False, separators=(",", ":")
        ).encode("utf-8")
        self.send_frame(body)

    def _pump(self, deadline: float) -> None:
        rem = deadline - time.monotonic()
        if rem <= 0:
            raise TimeoutError("LSP: таймаут ожидания кадра")
        ready, _, _ = select.select([self.proc.stdout], [], [], rem)
        if not ready:
            raise TimeoutError("LSP: таймаут ожидания кадра")
        chunk = os.read(self.proc.stdout.fileno(), 65536)
        if not chunk:
            self.eof = True
        else:
            self.buf += chunk

    def read_frame(self, timeout: float = TIMEOUT):
        deadline = time.monotonic() + timeout
        while True:
            head = self.buf.find(b"\r\n\r\n")
            if head >= 0:
                length = None
                for line in self.buf[:head].split(b"\r\n"):
                    if line.lower().startswith(b"content-length:"):
                        length = int(line.split(b":", 1)[1].strip())
                if length is None:
                    raise LspError("ответ без Content-Length")
                end = head + 4 + length
                if len(self.buf) >= end:
                    body = self.buf[head + 4 : end]
                    self.buf = self.buf[end:]
                    return json.loads(body.decode("utf-8", "strict"))
            if self.eof:
                if self.buf.strip():
                    raise LspError(f"неполный кадр в конце: {self.buf!r}")
                return None
            self._pump(deadline)

    def expect(self, timeout: float = TIMEOUT):
        frame = self.read_frame(timeout)
        if frame is None:
            raise LspError("процесс закрыл stdout без ответа")
        return frame

    def close_stdin(self) -> None:
        if self._stdin_open and self.proc.stdin is not None:
            try:
                self.proc.stdin.close()
            except (BrokenPipeError, OSError):
                pass
            self._stdin_open = False

    def kill(self) -> None:
        """Аварийно завершить ТОЛЬКО свой процесс (на ошибке теста)."""
        ACTIVE_CLIENTS.discard(self)
        if self.proc.poll() is None:
            self.proc.kill()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
        try:
            self.close_stdin()
        except OSError:
            pass

    def finish(self, timeout: float = TIMEOUT) -> tuple[int, str]:
        ACTIVE_CLIENTS.discard(self)
        self.close_stdin()
        killed = False
        try:
            rc = self.proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            killed = True
            self.proc.kill()
            self.proc.wait(timeout=5)
            rc = self.proc.returncode
        err = self.proc.stderr.read().decode("utf-8", "replace")
        if killed:
            raise LspError("процесс не завершился за таймаут")
        return rc, err

    def stop_cleanly(self) -> str:
        self.send_json({"jsonrpc": "2.0", "id": 9001, "method": "shutdown"})
        assert self.expect()["id"] == 9001
        self.send_json({"jsonrpc": "2.0", "method": "exit"})
        rc, err = self.finish()
        if rc != 0:
            raise LspError(f"чистый выход дал rc={rc}: {err}")
        return err


# ---------------------------------------------------------------------------
# Общие помощники
# ---------------------------------------------------------------------------


def workspace(name: str) -> pathlib.Path:
    d = TEST_ROOT / name
    d.mkdir(mode=0o700)
    return d


def tmpdir_for(ws: pathlib.Path) -> pathlib.Path:
    d = ws / "tmp"
    d.mkdir(mode=0o700)
    return d


def file_uri(path: pathlib.Path) -> str:
    return path.resolve().as_uri()


def write(path: pathlib.Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")


def diags_of(frame) -> list:
    if frame.get("method") != "textDocument/publishDiagnostics":
        raise LspError(f"ожидался publishDiagnostics: {frame}")
    return frame["params"]["diagnostics"]


def open_doc(client: Client, path: pathlib.Path | str, text: str, version=1):
    uri = path if isinstance(path, str) else file_uri(path)
    client.send_json(
        {
            "jsonrpc": "2.0",
            "method": "textDocument/didOpen",
            "params": {
                "textDocument": {
                    "uri": uri,
                    "languageId": "bp",
                    "version": version,
                    "text": text,
                }
            },
        }
    )
    return diags_of(client.expect())


def change_doc(client: Client, path: pathlib.Path | str, text: str, version=2):
    uri = path if isinstance(path, str) else file_uri(path)
    client.send_json(
        {
            "jsonrpc": "2.0",
            "method": "textDocument/didChange",
            "params": {
                "textDocument": {"uri": uri, "version": version},
                "contentChanges": [{"text": text}],
            },
        }
    )
    return diags_of(client.expect())


def hover(client: Client, path: pathlib.Path, line: int, character: int):
    client.send_json(
        {
            "jsonrpc": "2.0",
            "id": 77,
            "method": "textDocument/hover",
            "params": {
                "textDocument": {"uri": file_uri(path)},
                "position": {"line": line, "character": character},
            },
        }
    )
    frame = client.expect()
    assert frame["id"] == 77, frame
    return frame["result"]


def codes(diags) -> list[int]:
    return [int(d["code"]) for d in diags]


def message_of(diag) -> str:
    return str(diag.get("message", ""))


VALID_MAIN = (
    'include "Inc"\n'
    'import "Module1"\n'
    "Module1.x = 3\n"
    "Module1.Show(1)\n"
    'LCD.Text(1,0,0,1,"ok")\n'
)


def make_project(ws: pathlib.Path) -> pathlib.Path:
    proj = ws / "proj"
    proj.mkdir()
    write(
        proj / "Module1.bpm",
        'number x\n\nFunction Show(in number n)\n'
        '  LCD.Text(1,0,0,1,"mod")\nEndFunction\n',
    )
    write(proj / "Inc.bpi", 'LCD.Text(1,0,0,1,"inc")\n')
    write(proj / "Bad.bpi", 'LCD.Text(1,0,0,1,"x"\n')
    (proj / "BadUtf.bpi").write_bytes(b"\xff\xfe\x00bad\n")
    noread = proj / "NoRead.bpi"
    write(noread, 'LCD.Text(1,0,0,1,"noread")\n')
    if not (hasattr(os, "geteuid") and os.geteuid() == 0):
        noread.chmod(0)
    write(proj / "Main.bp", "SENTINEL: НЕ МЕНЯТЬ\n")
    return proj


# ---------------------------------------------------------------------------
# Тесты
# ---------------------------------------------------------------------------


def test_initialize_shutdown_id_null():
    ws = workspace("idnull")
    tmp = tmpdir_for(ws)
    c = Client(tmp)
    c.send_json({"jsonrpc": "2.0", "id": None, "method": "initialize", "params": {}})
    init = c.expect()
    assert init["jsonrpc"] == "2.0" and init["id"] is None
    assert "capabilities" in init["result"]
    c.send_json({"jsonrpc": "2.0", "id": None, "method": "shutdown"})
    sd = c.expect()
    assert sd["id"] is None and sd["result"] is None
    c.send_json({"jsonrpc": "2.0", "method": "exit"})
    rc, err = c.finish()
    assert rc == 0, (rc, err)
    assert list(tmp.iterdir()) == []


def test_id_types_and_errors():
    ws = workspace("ids")
    c = Client(tmpdir_for(ws))
    c.send_json({"jsonrpc": "2.0", "id": 'a"b\u00e9', "method": "initialize"})
    r = c.expect()
    assert r["id"] == 'a"b\u00e9', r
    c.send_json({"jsonrpc": "2.0", "id": 42, "method": "initialize"})
    r = c.expect()
    assert r["id"] == 42, r
    for bad in (True, False, [], {}):
        c.send_json({"jsonrpc": "2.0", "id": bad, "method": "initialize"})
        r = c.expect()
        assert r["id"] is None and r["error"]["code"] == -32600, (bad, r)
    c.send_json({"jsonrpc": "2.0", "id": 3, "method": "no/such"})
    r = c.expect()
    assert r["id"] == 3 and r["error"]["code"] == -32601, r
    # уведомление неизвестного метода не должно давать ответ
    c.send_json({"jsonrpc": "2.0", "method": "no/such/notification"})
    c.send_json({"jsonrpc": "2.0", "id": 4, "method": "shutdown"})
    assert c.expect()["id"] == 4
    c.send_json({"jsonrpc": "2.0", "method": "exit"})
    rc, err = c.finish()
    assert rc == 0, (rc, err)


def test_native_flow_include_module_hover_completion_change():
    ws = workspace("flow")
    proj = make_project(ws)
    tmp = tmpdir_for(ws)
    c = Client(tmp)
    c.send_json({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
    assert c.expect()["id"] == 1

    main = proj / "Main.bp"
    d = open_doc(c, main, VALID_MAIN)
    assert d == [], d
    hover_file = proj / "Hover.bp"
    write(hover_file, "disk\n")
    hover_text = 'x = "😀" : LCD.Text(1,0,0,1,"ok")\n'
    d = open_doc(c, hover_file, hover_text)
    assert codes(d) == [1401], d  # синтаксис не важен: важна позиция hover

    res = hover(c, hover_file, 0, 11)  # UTF-16 offset сразу после emoji
    assert res and "LCD" in res["contents"]["value"], res
    assert hover(c, hover_file, 0, 6) is None, "середина суррогатной пары"
    assert hover(c, hover_file, 0, 10) is None, "пробел перед LCD"
    ascii_line = proj / "Ascii.bp"
    write(ascii_line, "disk\n")
    open_doc(c, ascii_line, 'LCD.Text(1,0,0,1,"ok")\n')
    assert "LCD" in hover(c, ascii_line, 0, 1)["contents"]["value"]

    c.send_json(
        {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "textDocument/completion",
            "params": {"textDocument": {"uri": file_uri(main)}},
        }
    )
    comp = c.expect()
    assert comp["id"] == 2
    labels = [it["label"] for it in comp["result"]]
    assert "lcd" in labels and "if" in labels, labels[:10]

    # didChange: ошибка появляется и сменяется чистой версией; диск не тронут
    d = change_doc(c, main, 'include "Missing"\n')
    assert codes(d) == [1101], d
    assert str(proj) in message_of(d[0]), d[0]
    d = change_doc(c, main, VALID_MAIN, version=3)
    assert d == [], d
    assert main.read_text(encoding="utf-8") == "SENTINEL: НЕ МЕНЯТЬ\n"

    # didClose чистит диагностики и удаляет ТОЛЬКО свой временный файл
    c.send_json(
        {
            "jsonrpc": "2.0",
            "method": "textDocument/didClose",
            "params": {"textDocument": {"uri": file_uri(main)}},
        }
    )
    assert diags_of(c.expect()) == []
    roots = [p for p in tmp.iterdir() if p.is_dir()]
    assert len(roots) == 1, roots
    # Main закрыт -> удалён только его d0.bp; открытые Hover/Ascii остаются.
    assert sorted(p.name for p in roots[0].iterdir()) == ["d1.bp", "d2.bp"], (
        list(roots[0].iterdir())
    )
    assert main.read_text(encoding="utf-8") == "SENTINEL: НЕ МЕНЯТЬ\n"
    c.stop_cleanly()
    assert list(tmp.iterdir()) == []


def test_external_include_diagnostic_anchor_and_related():
    ws = workspace("external")
    proj = make_project(ws)
    c = Client(tmpdir_for(ws))
    c.send_json({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
    c.expect()
    d = open_doc(c, proj / "Main.bp", 'include "Bad"\n')
    assert codes(d) == [1001], d
    diag = d[0]
    assert diag["range"]["start"] == {"line": 0, "character": 0}
    assert diag["range"]["end"] == {"line": 0, "character": 0}
    assert "Bad.bpi" in message_of(diag)
    rel = diag.get("relatedInformation")
    assert rel and rel[0]["location"]["uri"] == file_uri(proj / "Bad.bpi"), rel
    assert rel[0]["location"]["range"]["start"]["line"] == 0
    c.stop_cleanly()


def test_related_info_uri_byte_exact_unicode_space_percent_hash():
    """relatedInformation.uri == Path.resolve().as_uri() байт-в-байт.

    Каталог И имя include-файла содержат пробел, кириллицу, é, emoji, '%'
    и '#'. Прежний генератор percent-escape кодировал старший ниббл как
    '0'+hi: для байтов 0xA0..0xFF выходило '%:0'..'%?0' вместо '%A0'..'%FF',
    то есть битый/чужой URI. Ожидание берётся из stdlib Path.as_uri(),
    а не из нашей же реализации.
    """
    ws = workspace("uriinfo")
    proj = ws / "проект с пробелом %# é 😀"
    proj.mkdir()
    name = "Bad %# é 😀"
    bad = proj / (name + ".bpi")
    write(bad, 'LCD.Text(1,0,0,1,"x"\n')
    main = proj / "M ain.bp"
    write(main, "disk\n")
    c = Client(tmpdir_for(ws))
    c.send_json({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
    c.expect()
    d = open_doc(c, main, 'include "' + name + '"\n')
    assert codes(d) == [1001], d
    want = bad.resolve().as_uri()
    rel = d[0].get("relatedInformation")
    assert rel and len(rel) == 1, rel
    got = rel[0]["location"]["uri"]
    assert got == want, (got, want)
    # Ни сырых '%25'/'%23'-двойников, ни не-ASCII байтов в URI быть не может.
    assert "%25" in want and "%23" in want, want
    assert got.isascii(), got
    assert rel[0]["location"]["range"]["start"] == {"line": 0, "character": 0}
    assert str(bad) in message_of(d[0]), d[0]
    assert main.read_text(encoding="utf-8") == "disk\n"
    c.stop_cleanly()


def test_file_uri_percent_localhost_and_remote_reject():
    ws = workspace("uri")
    proj = ws / "проект с пробелом"
    proj.mkdir()
    write(proj / "Inc.bpi", 'LCD.Text(1,0,0,1,"inc")\n')
    main = proj / "M ain.bp"
    write(main, "disk\n")
    c = Client(tmpdir_for(ws))
    c.send_json({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
    c.expect()
    # Path.as_uri() percent-кодирует пробел и кириллицу; project_dir обязан
    # декодироваться в реальный каталог, иначе sibling include не найдётся.
    d = open_doc(c, main, 'include "Inc"\nLCD.Text(1,0,0,1,"ok")\n')
    assert d == [], d
    local = proj / "Local.bp"
    write(local, "disk\n")
    uri = file_uri(local).replace("file://", "file://localhost", 1)
    c.send_json(
        {
            "jsonrpc": "2.0",
            "method": "textDocument/didOpen",
            "params": {
                "textDocument": {
                    "uri": uri,
                    "languageId": "bp",
                    "version": 1,
                    "text": "LCD.Text(1,0,0,1,\"ok\")\n",
                }
            },
        }
    )
    assert diags_of(c.expect()) == []
    # удалённый authority не поддерживается и отвергается ЯВНО
    c.send_json(
        {
            "jsonrpc": "2.0",
            "method": "textDocument/didOpen",
            "params": {
                "textDocument": {
                    "uri": "file://example.com/tmp/x.bp",
                    "languageId": "bp",
                    "version": 1,
                    "text": "LCD.Text(1,0,0,1,\"ok\")\n",
                }
            },
        }
    )
    d = diags_of(c.expect())
    assert codes(d) == [9000] and "authority" in message_of(d[0]), d
    # битый percent-escape — тоже явная ошибка, а не угаданный путь
    c.send_json(
        {
            "jsonrpc": "2.0",
            "method": "textDocument/didOpen",
            "params": {
                "textDocument": {
                    "uri": "file:///tmp/%ZZ.bp",
                    "languageId": "bp",
                    "version": 1,
                    "text": "LCD.Text(1,0,0,1,\"ok\")\n",
                }
            },
        }
    )
    d = diags_of(c.expect())
    assert codes(d) == [9000] and "percent" in message_of(d[0]), d
    assert main.read_text(encoding="utf-8") == "disk\n"
    c.stop_cleanly()


def test_stage3_expanded_line_is_anchor_zero():
    ws = workspace("stage3")
    c = Client(tmpdir_for(ws))
    c.send_json({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
    c.expect()
    text = 'LCD.Text(1,0,0,1,"ok")\nfoo 1 2 3\n'
    d = open_doc(c, ws / "S3.bp", text)
    assert codes(d) == [3000], d
    diag = d[0]
    assert diag["range"]["start"] == {"line": 0, "character": 0}
    assert diag["range"]["end"] == {"line": 0, "character": 0}
    msg = message_of(diag)
    assert "ошибка в развёрнутом коде" in msg and "строка 2" in msg, msg
    assert "точное место в исходнике неизвестно" in msg
    c.stop_cleanly()


def test_analysis_failure_replaces_clean_and_no_internal_path():
    ws = workspace("failure")
    proj = make_project(ws)
    tmp = tmpdir_for(ws)
    c = Client(tmp)
    c.send_json({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
    c.expect()
    main = proj / "Main.bp"
    assert open_doc(c, main, VALID_MAIN) == []
    d = change_doc(c, main, 'include "BadUtf"\n')
    assert codes(d) == [9000], d
    assert "анализ не выполнен" in message_of(d[0])
    if not (hasattr(os, "geteuid") and os.geteuid() == 0):
        d = change_doc(c, main, 'include "NoRead"\n', version=3)
        assert codes(d) == [9000], d
    roots = [p for p in tmp.iterdir() if p.is_dir()]
    assert len(roots) == 1
    # предыдущая «чистая» версия не остаётся, а внутренний путь не утекает
    assert codes(change_doc(c, main, VALID_MAIN, version=4)) == []
    err = c.stop_cleanly()
    for root in roots:
        assert str(root) not in err, err
    assert "/tmp/bp_lsp_docs" not in err


def test_untitled_fallback_cwd_and_no_disk_source():
    ws = workspace("untitled")
    cwd = ws / "cwd"
    cwd.mkdir()
    c = Client(tmpdir_for(ws), cwd=cwd)
    c.send_json({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
    c.expect()
    d = open_doc(c, "untitled:Untitled-1", 'include "NoSuch"\n')
    assert codes(d) == [1101], d
    assert str(cwd) in message_of(d[0]), d[0]
    c.stop_cleanly()
    leftover = sorted(p.name for p in cwd.iterdir())
    assert leftover == [], leftover


def test_private_tmp_two_processes_and_sentinel():
    ws = workspace("iso")
    tmp = tmpdir_for(ws)
    sentinel = tmp / "bp_lsp_docs"
    sentinel.mkdir()
    keep = sentinel / "keep.txt"
    write(keep, "ГЛОБАЛЬНЫЙ СЕНТИНЕЛ\n")
    c1 = Client(tmp)
    c2 = Client(tmp)
    for c in (c1, c2):
        c.send_json({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
        assert c.expect()["id"] == 1
    roots = sorted(
        p for p in tmp.iterdir() if p.is_dir() and p.name != "bp_lsp_docs"
    )
    assert len(roots) == 2, roots
    for root in roots:
        mode = stat.S_IMODE(root.stat().st_mode)
        assert mode == 0o700, oct(mode)
    proj = make_project(ws)
    for c in (c1, c2):
        d = open_doc(c, proj / "Main.bp", VALID_MAIN)
        assert d == [], d
    c1.stop_cleanly()
    c2.stop_cleanly()
    assert sorted(p.name for p in tmp.iterdir()) == ["bp_lsp_docs"]
    assert keep.read_text(encoding="utf-8") == "ГЛОБАЛЬНЫЙ СЕНТИНЕЛ\n"
    assert list(sentinel.iterdir()) == [keep]


def test_framing_fail_closed():
    ws = workspace("framing")
    tmp = tmpdir_for(ws)
    init_body = json.dumps(
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
        separators=(",", ":"),
    ).encode()
    init_frame = b"Content-Length: %d\r\n\r\n" % len(init_body) + init_body
    cases = [
        b"X: y\r\n\r\n",
        b"Content-Length: 12x\r\n\r\n",
        b"Content-Length: -5\r\n\r\n",
        b"Content-Length: 99999999999999999999\r\n\r\n",
        b"Garbage\r\n\r\n",
        b"\r\n",
        b"\xff: y\r\n\r\n",
    ]
    for i, header in enumerate(cases):
        c = Client(tmp)
        c.send_raw(header + init_frame)
        frames = []
        while True:
            f = c.read_frame(timeout=5)
            if f is None:
                break
            frames.append(f)
        rc, err = c.finish()
        assert rc != 0, (i, header, rc, frames)
        assert frames == [], (i, header, frames)
        assert "фатальная ошибка кадрирования" in err, (i, err)
    # невалидный UTF-8 тела — фатально (strict decode), без ответа
    c = Client(tmp)
    c.send_frame(b'{"a":"\xff"}')
    frames = []
    while True:
        f = c.read_frame(timeout=5)
        if f is None:
            break
        frames.append(f)
    rc, err = c.finish()
    assert rc != 0, rc
    assert frames == [], frames
    # обрыв тела (Content-Length больше фактических байт) — фатально
    c = Client(tmp)
    c.send_raw(b"Content-Length: 50\r\n\r\n" + b'{"jsonrpc"')
    c.close_stdin()
    frames = []
    while True:
        f = c.read_frame(timeout=5)
        if f is None:
            break
        frames.append(f)
    rc, err = c.finish()
    assert rc != 0, rc
    assert frames == [], frames
    # а вот ПОЛНЫЙ кадр с битым JSON — -32700 и сервер продолжает работу
    c = Client(tmp)
    c.send_frame(b'{"jsonrpc"')
    r = c.expect()
    assert r["error"]["code"] == -32700 and r["id"] is None, r
    c.stop_cleanly()
    assert list(tmp.iterdir()) == []


def test_json_depth_and_parse_error_continue():
    ws = workspace("depth")
    c = Client(tmpdir_for(ws))
    deep129 = b"[" * 129 + b"0" + b"]" * 129
    deep128 = b"[" * 128 + b"0" + b"]" * 128
    c.send_frame(deep129)
    r = c.expect()
    assert r["error"]["code"] == -32700 and r["id"] is None, r
    c.send_frame(deep128)
    r = c.expect()
    assert r["error"]["code"] == -32600, r
    c.send_json({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
    assert c.expect()["id"] == 1
    c.stop_cleanly()


def _wide_array_body(kb: int, method: str = "x/json/wide") -> bytes:
    """Тело кадра ~kb KiB: широкий массив коротких чисел в params."""
    head = (
        '{"jsonrpc":"2.0","id":7,"method":"' + method + '","params":{"a":['
    ).encode()
    tail = b"]}}"
    n = max(1, (kb * 1024 - len(head) - len(tail)) // 2)
    return head + b"0," * (n - 1) + b"0" + tail


def _wide_object_body(kb: int) -> bytes:
    """Тело кадра ~kb KiB: широкий объект с уникальными ключами."""
    head = b'{"jsonrpc":"2.0","id":7,"method":"x/json/wide","params":{"b":{'
    tail = b"}}}"
    budget = max(1, kb * 1024 - len(head) - len(tail))
    parts = []
    used = 0
    i = 0
    while True:
        item = ('"k%d":%d' % (i, i)).encode()
        add = len(item) + (1 if parts else 0)
        if used + add > budget:
            break
        parts.append(item)
        used += add
        i += 1
    assert parts, kb
    return head + b",".join(parts) + tail


def test_wide_nested_json_frames_linear_not_quadratic():
    """Разбор широкого JSON линеен: 200 KB массив укладывается в секунды.

    Регрессия b580bcc: _link_child обходил ВСЕХ детей контейнера на каждой
    вставке -> O(n^2); 20/40/80/160 KB давали 0.31/1.23/5.42/>10 c, и
    ~200 KB не укладывались в таймаут. Порог 5 c — на порядки выше времени
    линейного разбора (~0.03 c) и заведомо ниже квадратичного, поэтому это
    не микробенчмарк, а функциональный предел.
    """
    ws = workspace("widejson")
    c = Client(tmpdir_for(ws))
    try:
        big = _wide_array_body(200)
        assert 195 * 1024 <= len(big) <= 201 * 1024, len(big)
        t0 = time.monotonic()
        c.send_frame(big)
        r = c.expect()
        wide_sec = time.monotonic() - t0
        assert r["id"] == 7 and r["error"]["code"] == -32601, r
        assert wide_sec < 5.0, ("квадратичный разбор?", wide_sec)
        obj = _wide_object_body(120)
        t0 = time.monotonic()
        c.send_frame(obj)
        r = c.expect()
        obj_sec = time.monotonic() - t0
        assert r["id"] == 7 and r["error"]["code"] == -32601, r
        assert obj_sec < 5.0, ("квадратичный разбор объекта?", obj_sec)
        print(
            f"  wide array {len(big)}B={wide_sec:.3f}s "
            f"object {len(obj)}B={obj_sec:.3f}s"
        )
        # вложенное чередование + дубликаты ключей + escapes/unicode:
        # дубликат "jsonrpc" -> берётся первый, id/строка декодируются точно.
        nested = (
            b'{"jsonrpc":"2.0","jsonrpc":"1.0","id":"\xd0\xb8\xf0\x9f\x98\x80",'
            b'"method":"x/json/nested","params":{"n":'
            + b"[" * 100
            + b'{"k":"\\u044e\\u00e9\\ud83d\\ude00","dup":1,"dup":2}'
            + b"]" * 100
            + b"}}"
        )
        c.send_frame(nested)
        r = c.expect()
        assert r["id"] == "и😀" and r["error"]["code"] == -32601, r
        # сервер жив и после широких кадров
        c.send_json({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
        assert c.expect()["id"] == 1
        c.stop_cleanly()
    finally:
        # на провале не ждём shutdown посреди квадратичного разбора
        if c.proc.poll() is None:
            c.kill()
    tmp = TEST_ROOT / "widejson" / "tmp"
    assert list(tmp.iterdir()) == []


def test_valid_unicode_frames_byte_accurate():
    ws = workspace("unicode")
    c = Client(tmpdir_for(ws))
    c.send_json({"jsonrpc": "2.0", "id": "идентификатор-😀", "method": "initialize"})
    r = c.expect()
    assert r["id"] == "идентификатор-😀"
    text = 'LCD.Text(1,0,0,1,"привет 😀")\n'
    d = open_doc(c, ws / "U.bp", text)
    assert isinstance(d, list)
    c.stop_cleanly()


def test_startup_tmp_failure_is_explicit():
    if hasattr(os, "geteuid") and os.geteuid() == 0:
        print("  SKIP: root игнорирует права каталога")
        return
    ws = workspace("startfail")
    ro = ws / "readonly"
    ro.mkdir()
    ro.chmod(0o500)
    try:
        c = Client(ro)
        frames = []
        while True:
            f = c.read_frame(timeout=5)
            if f is None:
                break
            frames.append(f)
        rc, err = c.finish()
        assert rc != 0, (rc, err)
        assert frames == [], frames
        assert "временн" in err.lower() or "tmp" in err.lower(), err
    finally:
        ro.chmod(0o700)


TESTS = [
    test_initialize_shutdown_id_null,
    test_id_types_and_errors,
    test_native_flow_include_module_hover_completion_change,
    test_external_include_diagnostic_anchor_and_related,
    test_related_info_uri_byte_exact_unicode_space_percent_hash,
    test_file_uri_percent_localhost_and_remote_reject,
    test_stage3_expanded_line_is_anchor_zero,
    test_analysis_failure_replaces_clean_and_no_internal_path,
    test_untitled_fallback_cwd_and_no_disk_source,
    test_private_tmp_two_processes_and_sentinel,
    test_framing_fail_closed,
    test_json_depth_and_parse_error_continue,
    test_wide_nested_json_frames_linear_not_quadratic,
    test_valid_unicode_frames_byte_accurate,
    test_startup_tmp_failure_is_explicit,
]


def main() -> int:
    global TEST_ROOT
    if not BIN.is_file() or not os.access(BIN, os.X_OK):
        print(
            "test_lsp: бинарь не найден: "
            f"{BIN}\n"
            "соберите: uv run mojo build src/bp/main.mojo -o tools/bp\n"
            "или задайте BP_BINARY (тесты не должны зеленеть без бинаря)",
            file=sys.stderr,
        )
        return 2
    TEST_ROOT = pathlib.Path(tempfile.mkdtemp(prefix="bp_lsp_test_"))
    print(f"test_lsp: binary={BIN}")
    failed = 0
    try:
        for test in TESTS:
            name = test.__name__
            try:
                test()
            except Exception as exc:  # noqa: BLE001 - отчёт с трейсом
                failed += 1
                print(f"FAIL {name}: {exc}")
                traceback.print_exc()
            else:
                print(f"PASS {name}")
    finally:
        for c in list(ACTIVE_CLIENTS):
            c.kill()
        ACTIVE_CLIENTS.clear()
        shutil.rmtree(TEST_ROOT, ignore_errors=True)
    print(
        f"test_lsp: {'OK' if failed == 0 else 'FAILED'} "
        f"({len(TESTS) - failed}/{len(TESTS)})"
    )
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
