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
  * сбой setup транспорта: CLI не виснет и падает.

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

failures = []
passes = 0
skips = 0


def ok(what):
    global passes
    passes += 1
    print(f"ok: {what}")


def skip(what, detail=""):
    """Graceful skip: окружение не позволяет выполнить проверку безопасно."""
    global skips
    skips += 1
    print(f"skip: {what}" + (f" ({detail})" if detail else ""))


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
    rc = subprocess.call(cmd, env=env)
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
        ("drop-begin-reply", "нет ответа на BEGIN -> fail-safe, без дублей"),
        ("bad-echo", "чужое эхо команды -> ошибка протокола"),
        ("truncated-begin", "обрезанный ответ -> ошибка протокола"),
        ("bad-ctr", "чужой счётчик/таймаут -> ошибка"),
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
            begins = [e for e in events if e.get("event") == "begin"]
            conts = [e for e in events if e.get("event") == "continue"]
            check(len(begins) == 1,
                  f"tcp {mode}: BEGIN отправлен ровно один раз (нет автоповтора)",
                  str(len(begins)))
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
        test_serial_e2e(tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print()
    print(f"passed={passes} failed={len(failures)} skipped={skips}")
    if failures:
        for f in failures:
            print("  -", f)
        return 1
    print("CLI_FLASH_TEST OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
