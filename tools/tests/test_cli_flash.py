#!/usr/bin/env python3
"""CLI + flash e2e/negative tests (hardware-free).

Запуск из корня репо:
    python3 tools/tests/test_cli_flash.py
    BP_BINARY=/path/to/bp python3 tools/tests/test_cli_flash.py

Проверяется:
  * коды возврата CLI: lmsb/rbf/lex/expand/compile/check при ошибке != 0,
    успех == 0, неизвестная команда != 0, help/noargs == 0 (документированная
    семантика справки не сломана);
  * реальный протокол ответов EV3: ответ [ctr u16][0x03][ЭХО команды]
    [статус][данные...] — сквозная заливка через tools/fake_ev3.py (TCP
    loopback) и tools/fake_ev3_serial.py (pty), принятый файл побайтово равен
    отправленному;
  * негативные сценарии протокола (потеря ACK на BEGIN, чужое эхо, обрезанный
    ответ, чужой счётчик): CLI падает ненулевым кодом, повторной заливки
    (дублей байтов) нет;
  * сбой setup транспорта: CLI не виснет и падает;
  * потеря ACK на неидемпотентном CONTINUE_DOWNLOAD: ровно один CONTINUE,
    abort, PROGRAM_START не отправляется;
  * ошибки CREATE_DIR: чужое эхо/обрезанный ответ/молчание -> abort до BEGIN;
    FILE_EXISTS (0x07) — валидный успех, заливка продолжается;
  * missing operand у каждой команды -> ненулевой код + подсказка, а
    help/-h/--help/noargs по-прежнему 0.

Строгий режим: BP_CLI_FLASH_STRICT=1 превращает ЛЮБОЙ mandatory skip в
ненулевой exit с явным объяснением (финальные ворота infra ставят этот env;
по умолчанию standalone-skip остаётся, но summary честно его печатает).

Порт 5555 у клиента фиксирован (спекулятивной опции порта нет), поэтому при
наличии bwrap весь тест перезапускается в приватном network namespace: чужие
listener'ы и файлы не трогаются. Без bwrap TCP-часть пропускается, если порт
занят. Временные файлы — только в своём tempdir (TMPDIR/mkdtemp), corpus не
загрязняется: фикстуры копируются в scratch перед использованием.

Тест НЕ требует железа, не делает внешних сетевых соединений (только
127.0.0.1) и не вызывает real flash/install.
"""
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BP = os.environ.get("BP_BINARY", os.path.join(ROOT, "tools", "bp"))
FAKE_TCP = os.path.join(ROOT, "tools", "fake_ev3.py")
FAKE_SERIAL = os.path.join(ROOT, "tools", "fake_ev3_serial.py")
PORT = 5555
NETNS_ENV = "BP_CLI_FLASH_TEST_NETNS"
STRICT_ENV = "BP_CLI_FLASH_STRICT"
INNER_ENV = "BP_CLI_FLASH_INNER"


def strict_mode():
    return os.environ.get(STRICT_ENV, "") not in ("", "0", "false", "no")

failures = []
passes = 0
skips = 0


def ok(what):
    global passes
    passes += 1
    print(f"ok: {what}")


def skip(what, detail=""):
    """Graceful skip: окружение не позволяет выполнить проверку безопасно.

    В strict-режиме это не разрешено: mandatory-проверка не выполнена, значит
    результат не «зелёный» — summary и код возврата будут ненулевыми.
    """
    global skips
    skips += 1
    tag = "SKIP(mandatory)" if strict_mode() else "skip"
    print(f"{tag}: {what}" + (f" ({detail})" if detail else ""))
    if strict_mode():
        failures.append(
            "mandatory skip in strict mode: "
            + what
            + (f" ({detail})" if detail else "")
        )


def bad(what, detail=""):
    failures.append(f"{what}: {detail}" if detail else what)
    print(f"FAIL: {what}" + (f" ({detail})" if detail else ""))


def check(cond, what, detail=""):
    if cond:
        ok(what)
    else:
        bad(what, detail)
    return cond


# --------------------------------------------------------------------------
# окружение
# --------------------------------------------------------------------------


def port_free(port):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("127.0.0.1", port))
        return True
    except OSError:
        return False
    finally:
        s.close()


def maybe_reexec_in_netns():
    """Перезапуск в приватном netns, чтобы порт 5555 был гарантированно свой."""
    if os.environ.get(NETNS_ENV):
        return False
    bwrap = shutil.which("bwrap")
    if not bwrap:
        return False
    if not port_free(PORT):
        # Порт занят чужим listener'ом — изолируемся.
        pass
    env = dict(os.environ)
    env[NETNS_ENV] = "1"
    cmd = [
        bwrap,
        "--unshare-net",
        "--dev-bind",
        "/",
        "/",
        "--chdir",
        os.getcwd(),
        sys.executable,
        os.path.abspath(__file__),
    ]
    print("info: перезапуск теста в приватном network namespace (bwrap)")
    try:
        rc = subprocess.call(cmd, env=env)
    except OSError as e:
        # Сломанный bwrap не должен молча превращаться в «пропустим TCP».
        print(f"FAIL: bwrap установлен, но не запускается: {e}")
        sys.exit(1)
    if rc != 0 and not port_free(PORT):
        print(
            "FAIL: bwrap-изоляция не удалась (rc={}), а порт {} занят чужим "
            "listener'ом — TCP-проверки нельзя выполнить безопасно".format(
                rc, PORT
            )
        )
        sys.exit(1)
    sys.exit(rc)


def run_bp(args, cwd=None, timeout=60, env=None):
    e = dict(os.environ)
    if env:
        e.update(env)
    return subprocess.run(
        [BP, *args],
        cwd=cwd,
        capture_output=True,
        text=True,
        timeout=timeout,
        env=e,
    )


# --------------------------------------------------------------------------
# 1. CLI exit codes
# --------------------------------------------------------------------------


def test_cli_exit_codes(tmp):
    if not os.access(BP, os.X_OK):
        bad("BP binary exists", f"{BP} not executable/not built")
        return

    # Фикстуры из corpus копируются в свой scratch (corpus не трогаем).
    good_bp = os.path.join(tmp, "good", "~Good.bp")
    good_lmsb = os.path.join(tmp, "good", "Good.lmsb")
    os.makedirs(os.path.dirname(good_bp), exist_ok=True)
    shutil.copy(
        os.path.join(ROOT, "tests/corpus/Functions/~Test1/~Test1.bp"), good_bp
    )
    shutil.copy(
        os.path.join(ROOT, "tests/corpus/Functions/~Test1/Test1.lmsb"), good_lmsb
    )

    r = run_bp(["lmsb", good_bp])
    check(r.returncode == 0, "lmsb good -> rc 0", r.stderr[-300:])

    bad_bp = os.path.join(tmp, "bad", "~Bad.bp")
    os.makedirs(os.path.dirname(bad_bp), exist_ok=True)
    with open(bad_bp, "w", encoding="utf-8") as f:
        f.write("Sub foo(\n")
    r = run_bp(["lmsb", bad_bp])
    check(
        r.returncode != 0,
        "lmsb bad -> rc != 0",
        f"rc={r.returncode}, out={r.stdout[-200:]!r}",
    )

    r = run_bp(["rbf", good_lmsb])
    check(r.returncode == 0, "rbf good -> rc 0", r.stderr[-300:])
    good_rbf = good_lmsb.replace(".lmsb", ".rbf")
    check(os.path.exists(good_rbf), "rbf good -> создан .rbf")

    bad_lmsb = os.path.join(tmp, "bad", "Bad.lmsb")
    with open(bad_lmsb, "w", encoding="utf-8") as f:
        f.write("BOGUS_OPCODE 1\n")
    r = run_bp(["rbf", bad_lmsb])
    check(
        r.returncode != 0,
        "rbf bad -> rc != 0",
        f"rc={r.returncode}, out={r.stdout[-200:]!r}",
    )

    # expand bad: ошибка развёртки -> exit 1 (не удваиваем обработку).
    bad_expand = os.path.join(tmp, "exp", "E.bp")
    os.makedirs(os.path.dirname(bad_expand), exist_ok=True)
    with open(bad_expand, "w", encoding="utf-8") as f:
        f.write('include "NoSuchFile.bpi"\n')
    r = run_bp(["expand", bad_expand])
    check(r.returncode == 1, "expand bad -> rc 1", f"rc={r.returncode}")
    r = run_bp(["compile", bad_expand])
    check(r.returncode != 0, "compile bad -> rc != 0", f"rc={r.returncode}")
    r = run_bp(["check", bad_expand])
    check(r.returncode != 0, "check bad -> rc != 0", f"rc={r.returncode}")

    # lex на несуществующий файл — ненулевой (исключение/ошибка).
    r = run_bp(["lex", os.path.join(tmp, "missing.bp")])
    check(r.returncode != 0, "lex missing -> rc != 0", f"rc={r.returncode}")

    # Unknown команда обязана быть ошибкой (было 0).
    r = run_bp(["frobnicate"])
    check(r.returncode != 0, "unknown command -> rc != 0", f"rc={r.returncode}")
    check(
        "неизвестная команда" in (r.stdout + r.stderr),
        "unknown command: есть сообщение",
        (r.stdout + r.stderr)[-200:],
    )

    # help / --help / -h — справка и код 0.
    for flag in ("help", "--help", "-h"):
        r = run_bp([flag])
        check(
            r.returncode == 0 and "Использование" in r.stdout,
            f"{flag} -> rc 0 + usage",
            f"rc={r.returncode}",
        )
    # noargs — документированная семантика: справка, код 0.
    r = run_bp([])
    check(
        r.returncode == 0 and "Использование" in r.stdout,
        "no args -> usage + rc 0",
        f"rc={r.returncode}",
    )

    # Missing operand: каждая команда без обязательного пути — ошибка
    # использования (ненулевой rc), а не тихий успех. Проверяется настоящим
    # subprocess, а не только unit-веткой.
    for cmd in ("lex", "lmsb", "rbf", "expand", "compile", "check", "flash"):
        r = run_bp([cmd])
        check(
            r.returncode != 0,
            f"{cmd} без операнда -> rc != 0",
            f"rc={r.returncode}, out={(r.stdout + r.stderr)[-200:]!r}",
        )
        out = r.stdout + r.stderr
        check(
            "нужен путь к файлу" in out,
            f"{cmd} без операнда: сообщение об использовании",
            out[-200:],
        )
        check(
            "bp help" in out,
            f"{cmd} без операнда: подсказка bp help",
            out[-200:],
        )

    # flash на несуществующий setup (rfcomm-путь — не tty) -> rc != 0.
    bogus = os.path.join(tmp, "notty", "rfcomm_probe")
    os.makedirs(os.path.dirname(bogus), exist_ok=True)
    with open(bogus, "w") as f:
        f.write("x")
    r = run_bp(["flash", good_rbf, bogus], timeout=30)
    check(r.returncode != 0, "flash bad transport setup -> rc != 0", f"rc={r.returncode}")
    combined = r.stdout + r.stderr
    check(
        "flash: не прочитать termios" in combined or "flash: не перевести" in combined,
        "flash bad transport setup: ошибка именно на setup (не на чтении .rbf)",
        combined[-300:],
    )


# --------------------------------------------------------------------------
# 2. flash e2e по Wi-Fi (loopback) и serial (pty)
# --------------------------------------------------------------------------


def write_payload(tmp, size=2000):
    """Синтетический .rbf: > CHUNK_SIZE, чтобы был CONTINUE-кадр."""
    rng = bytes((i * 37 + 11) & 0xFF for i in range(size))
    path = os.path.join(tmp, "payload.rbf")
    with open(path, "wb") as f:
        f.write(rng)
    return path, rng


def read_report(path):
    events = []
    if not os.path.exists(path):
        return events
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                events.append(json.loads(line))
    return events


def wait_line(log_path, needle, timeout=10):
    """Ждать строку в логе процесса (лог пишется дочерним процессом)."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with open(log_path, encoding="utf-8", errors="replace") as f:
                if needle in f.read():
                    return True
        except OSError:
            pass
        time.sleep(0.02)
    return False


def start_fake(cmd, log_path):
    log = open(log_path, "w", encoding="utf-8")
    return subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT), log


def stop_proc(p, timeout=5):
    if p is None:
        return
    if p.poll() is None:
        p.terminate()
        try:
            p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()


def test_tcp_e2e(tmp):
    if not port_free(PORT):
        skip(
            "tcp e2e",
            "порт 5555 занят (нет bwrap/netns); чужой listener не трогаем",
        )
        return
    upload = os.path.join(tmp, "tcp_upload.rbf")
    report = os.path.join(tmp, "tcp_report.jsonl")
    logp = os.path.join(tmp, "tcp_fake.log")
    src, wire = write_payload(tmp)
    proc, log = start_fake(
        [
            sys.executable,
            FAKE_TCP,
            "--port",
            str(PORT),
            "--upload",
            upload,
            "--report",
            report,
        ],
        logp,
    )
    try:
        if not wait_line(logp, "слушаю", timeout=10):
            bad("tcp e2e: fake_ev3 стартовал", open(logp).read()[-400:])
            return
        r = run_bp(["flash", src, "wifi:127.0.0.1"], timeout=60)
        check(r.returncode == 0, "tcp e2e: flash rc 0", (r.stdout + r.stderr)[-400:])
        check("flash: OK" in r.stdout, "tcp e2e: сообщение об успехе", r.stdout[-200:])
        got = open(upload, "rb").read() if os.path.exists(upload) else b""
        check(got == wire, "tcp e2e: принятый файл побайтово равен исходному")
        events = read_report(report)
        ctrs = [e["ctr"] for e in events if e.get("event") == "packet"]
        check(ctrs == sorted(set(ctrs)) and len(ctrs) >= 4,
              "tcp e2e: счётчики уникальны и растут", str(ctrs))
        begins = [e for e in events if e.get("event") == "begin"]
        conts = [e for e in events if e.get("event") == "continue"]
        check(len(begins) == 1 and len(conts) >= 1,
              "tcp e2e: один BEGIN + CONTINUE (файл >900 Б)",
              f"begin={len(begins)} cont={len(conts)}")
        direct = [e for e in events if e.get("event") == "direct"]
        check(len(direct) == 1, "tcp e2e: ровно один PROGRAM_START", str(len(direct)))
    finally:
        stop_proc(proc)
        log.close()


def test_tcp_failure_modes(tmp):
    if not port_free(PORT):
        skip("tcp negative", "порт 5555 занят (нет bwrap/netns)")
        return
    src, wire = write_payload(tmp, size=1000)
    cases = [
        ("handshake-close", "сбой setup (обрыв до handshake) -> ошибка"),
        ("bad-handshake", "неверный handshake -> ошибка"),
        ("drop-begin-reply", "нет ответа на BEGIN -> fail-safe, без дублей"),
        ("bad-echo", "чужое эхо команды -> ошибка протокола"),
        ("truncated-begin", "обрезанный ответ -> ошибка протокола"),
        ("bad-ctr", "чужой счётчик/таймаут -> ошибка"),
        ("drop-continue-reply", "потеря ACK на CONTINUE -> fail-safe, без дублей"),
        ("create-bad-echo", "CREATE_DIR: чужое эхо -> abort до BEGIN"),
        ("create-truncated", "CREATE_DIR: обрезанный ответ -> abort до BEGIN"),
        ("create-drop-reply", "CREATE_DIR: нет ответа -> abort до BEGIN"),
    ]
    for mode, what in cases:
        upload = os.path.join(tmp, f"{mode}_upload.rbf")
        report = os.path.join(tmp, f"{mode}_report.jsonl")
        logp = os.path.join(tmp, f"{mode}_fake.log")
        proc, log = start_fake(
            [
                sys.executable,
                FAKE_TCP,
                "--port",
                str(PORT),
                "--upload",
                upload,
                "--report",
                report,
                "--fail-mode",
                mode,
            ],
            logp,
        )
        try:
            if not wait_line(logp, "слушаю", timeout=10):
                bad(f"tcp {mode}: fake стартовал", open(logp).read()[-300:])
                continue
            r = run_bp(["flash", src, "wifi:127.0.0.1"], timeout=60)
            check(r.returncode != 0, f"tcp {mode}: rc != 0 ({what})",
                  f"rc={r.returncode}")
            events = read_report(report)
            if mode.startswith("create-"):
                # CREATE_DIR — trust boundary: битый/потерянный ACK не должен
                # приводить к BEGIN (иначе заливка идёт на непроверенном
                # состоянии протокола).
                begins = [e for e in events if e.get("event") == "begin"]
                direct = [e for e in events if e.get("event") == "direct"]
                creates = [e for e in events if e.get("event") == "syscmd"
                           and e.get("cmd") == 0x9B]
                check(len(creates) == 1,
                      f"tcp {mode}: CREATE_DIR отправлен ровно один раз",
                      str(len(creates)))
                check(len(begins) == 0,
                      f"tcp {mode}: BEGIN не отправлялся после сбоя CREATE_DIR",
                      str(len(begins)))
                check(len(direct) == 0,
                      f"tcp {mode}: PROGRAM_START не отправлялся",
                      str(len(direct)))
                continue
            if mode in ("handshake-close", "bad-handshake"):
                # До system-команд дело не дошло — заливки быть не должно.
                cmd_events = [
                    e for e in events if e.get("event") in ("syscmd", "direct")
                ]
                check(
                    len(cmd_events) == 0,
                    f"tcp {mode}: ни одной команды не отправлено",
                    str(cmd_events),
                )
                continue
            begins = [e for e in events if e.get("event") == "begin"]
            conts = [e for e in events if e.get("event") == "continue"]
            direct = [e for e in events if e.get("event") == "direct"]
            check(len(begins) == 1,
                  f"tcp {mode}: BEGIN отправлен ровно один раз (нет автоповтора)",
                  str(len(begins)))
            if mode == "drop-continue-reply":
                # Потеря ACK на CONTINUE: ровно один CONTINUE, abort, запуск
                # программы не происходит (иначе стартовал бы неполный файл).
                check(len(conts) == 1,
                      "tcp drop-continue-reply: CONTINUE отправлен ровно один раз",
                      str(len(conts)))
                check(len(direct) == 0,
                      "tcp drop-continue-reply: PROGRAM_START не отправлялся",
                      str(len(direct)))
                check(
                    "ACK неопределён" in (r.stdout + r.stderr)
                    or "неидемпотент" in (r.stdout + r.stderr),
                    "tcp drop-continue-reply: ясная fail-safe ошибка",
                    (r.stdout + r.stderr)[-300:],
                )
                continue
            check(len(conts) == 0,
                  f"tcp {mode}: после неопределённого ACK CONTINUE не шлётся",
                  str(len(conts)))
            if mode == "drop-begin-reply":
                check(
                    "ACK неопределён" in (r.stdout + r.stderr)
                    or "неидемпотент" in (r.stdout + r.stderr),
                    "tcp drop-begin-reply: ясная ошибка fail-safe",
                    (r.stdout + r.stderr)[-300:],
                )
        finally:
            stop_proc(proc)
            log.close()


def test_create_dir_exists_ok(tmp):
    """CREATE_DIR с FILE_EXISTS (0x07) — валидный успех: заливка идёт дальше."""
    if not port_free(PORT):
        skip("tcp create-exists", "порт 5555 занят (нет bwrap/netns)")
        return
    src, wire = write_payload(tmp, size=1200)
    upload = os.path.join(tmp, "create_exists_upload.rbf")
    report = os.path.join(tmp, "create_exists_report.jsonl")
    logp = os.path.join(tmp, "create_exists_fake.log")
    proc, log = start_fake(
        [
            sys.executable, FAKE_TCP,
            "--port", str(PORT),
            "--upload", upload,
            "--report", report,
            "--fail-mode", "create-exists",
        ],
        logp,
    )
    try:
        if not wait_line(logp, "слушаю", timeout=10):
            bad("tcp create-exists: fake стартовал", open(logp).read()[-300:])
            return
        r = run_bp(["flash", src, "wifi:127.0.0.1"], timeout=60)
        check(r.returncode == 0, "tcp create-exists: flash rc 0",
              (r.stdout + r.stderr)[-400:])
        got = open(upload, "rb").read() if os.path.exists(upload) else b""
        check(got == wire, "tcp create-exists: файл залит побайтово")
        events = read_report(report)
        direct = [e for e in events if e.get("event") == "direct"]
        check(len(direct) == 1,
              "tcp create-exists: ровно один PROGRAM_START", str(len(direct)))
    finally:
        stop_proc(proc)
        log.close()


def test_strict_skip_is_nonzero(tmp):
    """Strict-режим: mandatory skip (порт занят, bwrap недоступен) -> rc != 0.

    Изолированно: родитель сам держит 5555 (никого чужого не трогаем) и
    запускает дочернюю копию этого теста с NETNS=1 (без bwrap-перезапуска) и
    PATH без bwrap. В strict-режиме rc обязан быть ненулевым; в обычном —
    0 при тех же skip'ах. Сеть наружу не используется.
    """
    if os.environ.get(INNER_ENV):
        return  # не рекурсировать
    hold = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    hold.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        hold.bind(("127.0.0.1", PORT))
        hold.listen(1)
    except OSError as e:
        hold.close()
        skip("strict skip isolation", f"не удалось занять тестовый порт: {e}")
        return
    empty_path = os.path.join(tmp, "no_bwrap_path")
    os.makedirs(empty_path, exist_ok=True)
    base_env = dict(os.environ)
    base_env.pop(STRICT_ENV, None)
    base_env[NETNS_ENV] = "1"
    base_env[INNER_ENV] = "1"
    base_env["PATH"] = empty_path  # bwrap точно не найдётся
    try:
        strict_env = dict(base_env)
        strict_env[STRICT_ENV] = "1"
        r = subprocess.run(
            [sys.executable, os.path.abspath(__file__)],
            capture_output=True, text=True, timeout=240, env=strict_env,
        )
        out = r.stdout + r.stderr
        check(r.returncode != 0,
              "strict: mandatory skip -> rc != 0", f"rc={r.returncode}")
        check("SKIP(mandatory)" in out,
              "strict: skip помечен как mandatory", out[-300:])
        check("STRICT FAIL" in out,
              "strict: явное объяснение в summary", out[-300:])

        plain_env = dict(base_env)
        r2 = subprocess.run(
            [sys.executable, os.path.abspath(__file__)],
            capture_output=True, text=True, timeout=240, env=plain_env,
        )
        out2 = r2.stdout + r2.stderr
        check(r2.returncode == 0,
              "non-strict: те же skip'и -> rc 0", f"rc={r2.returncode}")
        check("skipped=" in out2 and "skipped=0" not in out2,
              "non-strict: summary честно печатает skipped>0", out2[-300:])
    finally:
        hold.close()


def test_serial_e2e(tmp):
    link = os.path.join(tmp, "rfcomm_fake0")
    if os.path.lexists(link):
        bad("serial e2e: scratch чист", link)
        return
    upload = os.path.join(tmp, "serial_upload.rbf")
    report = os.path.join(tmp, "serial_report.jsonl")
    logp = os.path.join(tmp, "serial_fake.log")
    src, wire = write_payload(tmp, size=1500)
    proc, log = start_fake(
        [
            sys.executable,
            FAKE_SERIAL,
            "--link",
            link,
            "--upload",
            upload,
            "--report",
            report,
        ],
        logp,
    )
    try:
        if not wait_line(logp, "->", timeout=10):
            bad("serial e2e: fake_ev3_serial стартовал", open(logp).read()[-400:])
            return
        r = run_bp(["flash", src, link], timeout=60)
        check(r.returncode == 0, "serial e2e: flash rc 0", (r.stdout + r.stderr)[-400:])
        # Дождаться, пока заглушка допишет файл и уберёт свой symlink
        # (pty-ответ может прийти клиенту чуть раньше завершения процесса).
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            pass
        got = open(upload, "rb").read() if os.path.exists(upload) else b""
        check(got == wire, "serial e2e: принятый файл побайтово равен исходному")
        check(not os.path.lexists(link), "serial e2e: свой symlink убран")
    finally:
        stop_proc(proc)
        log.close()


# --------------------------------------------------------------------------
# 3. fail-fast доступность моков
# --------------------------------------------------------------------------


def test_mocks_faithful(tmp):
    """Статическая проверка: моки содержат эхо команды в ответе (реальный
    формат), иначе e2e был бы зелёным на неверном протоколе."""
    for path in (FAKE_TCP, FAKE_SERIAL):
        with open(path, encoding="utf-8") as f:
            text = f.read()
        check(
            "sys_reply" in text and '"<HBBB"' in text,
            f"{os.path.basename(path)}: ответ ctr+type+эхо+статус",
        )
        check(
            "/tmp/fake_ev3_upload" not in text,
            f"{os.path.basename(path)}: без фиксированных /tmp-путей",
        )


def main():
    maybe_reexec_in_netns()
    if not os.path.exists(BP):
        print(f"FAIL: нет CLI {BP} (собери: uv run mojo build src/bp/main.mojo -o tools/bp)")
        return 2
    tmp = tempfile.mkdtemp(prefix="bp_cli_flash_")
    try:
        test_cli_exit_codes(tmp)
        test_mocks_faithful(tmp)
        test_tcp_e2e(tmp)
        test_tcp_failure_modes(tmp)
        test_create_dir_exists_ok(tmp)
        test_strict_skip_is_nonzero(tmp)
        test_serial_e2e(tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print()
    print(f"passed={passes} failed={len(failures)} skipped={skips} "
          f"strict={int(strict_mode())}")
    if failures:
        for f in failures:
            print("  -", f)
        if strict_mode() and skips:
            print(
                f"STRICT FAIL: {skips} mandatory проверок пропущено — "
                f"результат не считается зелёным (BP_CLI_FLASH_STRICT=1)"
            )
        return 1
    if strict_mode() and skips:
        print(f"STRICT FAIL: {skips} mandatory skip(s) в strict-режиме")
        return 1
    print("CLI_FLASH_TEST OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
