#!/usr/bin/env python3
"""OS fault-injection регрессия атомарной публикации .rbf.

Запуск:  python3 tools/tests/test_asm_write.py [--bp PATH]

BP_BINARY (env) или --bp, иначе <repo root>/tools/bp. Скрипт только запускает
CLI-процесс с ограничением RLIMIT_FSIZE в ДОЧЕРНЕМ процессе (preexec_fn) и
работает исключительно во временном каталоге: реальные outputs репозитория не
используются. SIGXFSZ в ребёнке БЛОКИРУЕТСЯ (pthread_sigmask), чтобы write()
вернул EFBIG как обычную ошибку записи. Важно: SIG_IGN здесь не годится —
рантайм Mojo при игнорируемом SIGXFSZ превращает EFBIG в LLVM abort
("IO failure on output stream") и процесс падает, не доходя до нашей ветки
обработки ошибки; блокировка сигнала оставляет errno=EFBIG и штатный код.

Проверяется контракт "output не перезаписывается при ошибке":
  * существующий .rbf + сбой записи -> побайтно прежний, временных файлов нет;
  * отсутствующий .rbf + сбой записи -> файл не создан;
  * валидный вход без лимита -> точные ожидаемые байты;
  * невалидный вход -> существующий .rbf не тронут (parse-ошибки).

Ограничение: проверяется безопасность при ошибке записи, НЕ долговечность при
отключении питания (fsync каталога не делается).
"""

import argparse
import os
import resource
import shutil
import signal
import subprocess
import sys
import tempfile

VALID_LMSB = "DATA32 G\nvmthread MAIN\n{\n    MOVE32_32 0 G\n}\n"
INVALID_LMSB = "vmthread MAIN\n{\nBOGUS_OPCODE 1\n}\n"
SENTINEL = b"SENTINEL: existing user rbf must survive\n"


def repo_root() -> str:
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def find_bp(explicit: str | None) -> str:
    cand = explicit or os.environ.get("BP_BINARY") or os.path.join(repo_root(), "tools", "bp")
    if not os.path.isfile(cand) or not os.access(cand, os.X_OK):
        sys.exit(
            f"нет CLI: {cand}\nсобери: uv run mojo build src/bp/main.mojo -o tools/bp\n"
            "или задай BP_BINARY/--bp"
        )
    return cand


def limit_child(fsize: int):
    def _pre() -> None:
        signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGXFSZ})
        resource.setrlimit(resource.RLIMIT_FSIZE, (fsize, fsize))

    return _pre


def run_bp(bp: str, lmsb: str, *, fsize: int | None = None) -> subprocess.CompletedProcess:
    kwargs = {}
    if fsize is not None:
        kwargs["preexec_fn"] = limit_child(fsize)
    return subprocess.run(
        [bp, "rbf", lmsb],
        capture_output=True,
        text=True,
        timeout=120,
        **kwargs,
    )


def temp_leftovers(directory: str, base: str) -> list[str]:
    prefix = f".{base}.tmp."
    return [n for n in os.listdir(directory) if n.startswith(prefix)]


class Checker:
    def __init__(self) -> None:
        self.fails: list[str] = []

    def check(self, cond: bool, what: str) -> None:
        if not cond:
            self.fails.append(what)

    def report(self) -> int:
        if self.fails:
            print(f"ASM WRITE FAILED: {len(self.fails)} ошибок")
            for f in self.fails:
                print("  - " + f)
            return 1
        print("ASM WRITE OK")
        return 0


def case_valid_exact_bytes(bp: str, ck: Checker) -> None:
    with tempfile.TemporaryDirectory(prefix="bp_write_valid_") as d:
        lmsb = os.path.join(d, "valid.lmsb")
        with open(lmsb, "w", encoding="utf-8") as f:
            f.write(VALID_LMSB)
        r = run_bp(bp, lmsb)
        ck.check(r.returncode == 0, f"valid: rc={r.returncode} stderr={r.stderr!r}")
        rbf = os.path.join(d, "valid.rbf")
        ck.check(os.path.isfile(rbf), "valid: .rbf не создан")
        if os.path.isfile(rbf):
            with open(rbf, "rb") as f:
                got = f.read()
            exp = bytes.fromhex(
                "4C 45 47 4F 20 00 00 00 68 00 01 00 04 00 00 00 "
                "1C 00 00 00 00 00 00 00 00 00 00 00 3A 00 60 0A"
            )
            ck.check(got == exp, f"valid: байты {got.hex()} != {exp.hex()}")
            ck.check(temp_leftovers(d, "valid.rbf") == [], "valid: остался временный файл")


def case_existing_preserved_on_write_failure(bp: str, ck: Checker) -> None:
    with tempfile.TemporaryDirectory(prefix="bp_write_existing_") as d:
        lmsb = os.path.join(d, "keep.lmsb")
        with open(lmsb, "w", encoding="utf-8") as f:
            f.write(VALID_LMSB)
        rbf = os.path.join(d, "keep.rbf")
        with open(rbf, "wb") as f:
            f.write(SENTINEL)
        before = os.stat(rbf)

        r = run_bp(bp, lmsb, fsize=1)  # 1 байт: образ (32 Б) не влезает
        after = os.stat(rbf)
        with open(rbf, "rb") as f:
            data = f.read()
        ck.check(data == SENTINEL, "existing: старый .rbf изменён/усечён при сбое записи")
        ck.check(after.st_size == before.st_size, "existing: размер .rbf изменился")
        ck.check(
            len(r.stdout) + len(r.stderr) > 0,
            "existing: сбой записи не отражён в выводе (пустой errorList)",
        )
        ck.check(
            temp_leftovers(d, "keep.rbf") == [],
            f"existing: временные файлы не убраны: {temp_leftovers(d, 'keep.rbf')}",
        )


def case_fresh_no_output_on_write_failure(bp: str, ck: Checker) -> None:
    with tempfile.TemporaryDirectory(prefix="bp_write_fresh_") as d:
        lmsb = os.path.join(d, "new.lmsb")
        with open(lmsb, "w", encoding="utf-8") as f:
            f.write(VALID_LMSB)
        rbf = os.path.join(d, "new.rbf")

        r = run_bp(bp, lmsb, fsize=1)
        ck.check(not os.path.exists(rbf), "fresh: .rbf создан при сбое записи")
        ck.check(
            len(r.stdout) + len(r.stderr) > 0,
            "fresh: сбой записи не отражён в выводе (пустой errorList)",
        )
        ck.check(
            temp_leftovers(d, "new.rbf") == [],
            f"fresh: временные файлы не убраны: {temp_leftovers(d, 'new.rbf')}",
        )


def case_invalid_preserves_existing(bp: str, ck: Checker) -> None:
    with tempfile.TemporaryDirectory(prefix="bp_write_invalid_") as d:
        lmsb = os.path.join(d, "bad.lmsb")
        with open(lmsb, "w", encoding="utf-8") as f:
            f.write(INVALID_LMSB)
        rbf = os.path.join(d, "bad.rbf")
        with open(rbf, "wb") as f:
            f.write(SENTINEL)

        r = run_bp(bp, lmsb)
        with open(rbf, "rb") as f:
            data = f.read()
        out = r.stdout + r.stderr
        ck.check("BOGUS_OPCODE" in out, "invalid: нет текста ошибки в выводе")
        ck.check(data == SENTINEL, "invalid: существующий .rbf перезаписан при parse-ошибке")
        ck.check(temp_leftovers(d, "bad.rbf") == [], "invalid: остался временный файл")


def case_no_target_in_readonly_dir(bp: str, ck: Checker) -> None:
    """Каталог без права записи: mkstemp не удаётся, цель не должна появиться."""
    with tempfile.TemporaryDirectory(prefix="bp_write_ro_") as d:
        lmsb = os.path.join(d, "ro.lmsb")
        with open(lmsb, "w", encoding="utf-8") as f:
            f.write(VALID_LMSB)
        rbf = os.path.join(d, "ro.rbf")
        with open(rbf, "wb") as f:
            f.write(SENTINEL)

        os.chmod(d, 0o500)
        try:
            r = run_bp(bp, lmsb)
            with open(rbf, "rb") as f:
                data = f.read()
        finally:
            os.chmod(d, 0o700)
        ck.check(data == SENTINEL, "ro-dir: существующий .rbf изменён при сбое mkstemp")
        ck.check(
            len(r.stdout) + len(r.stderr) > 0,
            "ro-dir: сбой не отражён в выводе",
        )
        ck.check(temp_leftovers(d, "ro.rbf") == [], "ro-dir: остался временный файл")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--bp", default=None, help="путь к CLI (по умолчанию tools/bp)")
    args = ap.parse_args()
    bp = find_bp(args.bp)

    ck = Checker()
    case_valid_exact_bytes(bp, ck)
    case_existing_preserved_on_write_failure(bp, ck)
    case_fresh_no_output_on_write_failure(bp, ck)
    case_invalid_preserves_existing(bp, ck)
    case_no_target_in_readonly_dir(bp, ck)
    return ck.report()


if __name__ == "__main__":
    sys.exit(main())
