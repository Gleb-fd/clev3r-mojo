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

Матрица RLIMIT_FSIZE на реальной валидной программе (golden ButtonsAndMotors,
образ 1957 Б):
  * limit 0/1/512/1024 -> сбой записи: rc процесса НЕНУЛЕВОЙ, существующий .rbf
    побайтно прежний (sentinel 2057 Б), свежий .rbf не создаётся, временных
    файлов не остаётся;
  * limit 2000/4096 -> успех: rc=0, опубликованный .rbf побайтно равен
    golden-эталону.

rc-контракт (CLI 9da6d30: ошибки использования/сбои != 0) проверяется во ВСЕХ
негативных сценариях: сбой записи, parse-ошибка, отказ mkstemp, read-only цель.
Текст ошибки проверяется дополнительно, но не вместо rc.

Граница гарантии: уборка временного файла выполняется в ОБРАБОТАННОЙ ветке
ошибки. Если процесс убит сигналом (SIGXFSZ с дефолтным действием, SIGKILL,
отключение питания), временный файл .<имя>.tmp.XXXXXX может остаться — это
честная граница, а не обещание «всегда чисто»; старый .rbf и в этом случае
цел, потому что rename не выполнялся.

Локальные ABI-ошибки, которые ловятся здесь же:
  * mkstemp(3) возвращает C int; при ошибке код отрицательный. Если читать его
    как 64-битный Int, -1 превращается в 4294967295 и проверка `fd < 0` мертва —
    вместо внятного "cannot create temporary file" появляется общий "write
    failed"; тест требует именно текст mkstemp-ошибки;
  * существующая цель без права записи (0444) не должна молча заменяться
    rename-ом: прежний open(path, "w") давал EACCES, поэтому ожидается отказ
    с текстом "not writable" (проверка через access(2) W_OK, не по битам).

Права: сценарии EACCES (read-only каталог, файл 0444) выполняются только при
ненулевом euid. Под root они честно пропускаются (SKIP), а не выдаются за
проверенные: root обходит биты режима, и access(W_OK)/open ведут себя иначе.

Ограничение: проверяется безопасность при ошибке записи, НЕ долговечность при
отключении питания (fsync каталога не делается).
"""

import argparse
import os
import resource
import signal
import subprocess
import sys
import tempfile

VALID_LMSB = "DATA32 G\nvmthread MAIN\n{\n    MOVE32_32 0 G\n}\n"
INVALID_LMSB = "vmthread MAIN\n{\nBOGUS_OPCODE 1\n}\n"

# Golden-программы для точечной (spot) проверки точных байтов: скрипт копирует
# .lmsb в свой временный каталог и сверяет полученный .rbf с эталоном.
GOLDEN_PROGRAMS = (
    (("Other", "~ButtonsAndMotors"), "ButtonsAndMotors", 1957),
    (("Other", "~HelloWorld"), "HelloWorld", None),
    (("Time", "~Time"), "Time", None),
)

# Sentinel существующей цели: ровно 2057 Б, детерминированно.
SENTINEL_LEN = 2057
SENTINEL_MARK = b"SENTINEL: existing user rbf must survive\n"
SENTINEL = (SENTINEL_MARK * (SENTINEL_LEN // len(SENTINEL_MARK) + 1))[:SENTINEL_LEN]

FAIL_LIMITS = (0, 1, 512, 1024)
PASS_LIMITS = (2000, 4096)


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


def golden(name) -> tuple[str, bytes]:
    """Путь golden .lmsb и байты эталонного .rbf (эталон не изменяется)."""
    stem = os.path.join(repo_root(), "tests", "golden", *name[0], name[1])
    with open(stem + ".rbf", "rb") as f:
        expected = f.read()
    return stem + ".lmsb", expected


def copy_golden(directory: str, name) -> tuple[str, bytes]:
    lmsb_src, expected = golden(name)
    lmsb = os.path.join(directory, os.path.basename(lmsb_src))
    with open(lmsb_src, "rb") as f:
        data = f.read()
    with open(lmsb, "wb") as f:
        f.write(data)
    return lmsb, expected


def is_root() -> bool:
    return os.geteuid() == 0


class Checker:
    def __init__(self) -> None:
        self.fails: list[str] = []
        self.skips: list[str] = []

    def check(self, cond: bool, what: str) -> None:
        if not cond:
            self.fails.append(what)

    def skip(self, what: str) -> None:
        self.skips.append(what)
        print(f"  SKIP: {what}")

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


def case_goldens_exact_bytes(bp: str, ck: Checker) -> None:
    """3 golden-программы: точные байты образа, свежая цель, rc=0."""
    for name in GOLDEN_PROGRAMS:
        tag = name[1]
        want_size = name[2]
        with tempfile.TemporaryDirectory(prefix=f"bp_write_golden_{tag}_") as d:
            lmsb, exp = copy_golden(d, name)
            if want_size is not None:
                ck.check(
                    len(exp) == want_size,
                    f"golden {tag}: эталон {len(exp)} Б != {want_size} Б",
                )
            r = run_bp(bp, lmsb)
            ck.check(r.returncode == 0, f"golden {tag}: rc={r.returncode} err={r.stderr!r}")
            rbf = os.path.join(d, tag + ".rbf")
            ck.check(os.path.isfile(rbf), f"golden {tag}: .rbf не создан")
            if os.path.isfile(rbf):
                with open(rbf, "rb") as f:
                    got = f.read()
                ck.check(
                    got == exp,
                    f"golden {tag}: байты расходятся с эталоном ({len(got)} Б != {len(exp)} Б)",
                )
                base = tag + ".rbf"
                ck.check(temp_leftovers(d, base) == [], f"golden {tag}: остался временный файл")


def case_limit_matrix_existing(bp: str, ck: Checker) -> None:
    """Матрица пределов: сбой (0/1/512/1024) и успех (2000/4096) на 1957 Б."""
    name = GOLDEN_PROGRAMS[0]
    tag = name[1]
    for limit in FAIL_LIMITS + PASS_LIMITS:
        with tempfile.TemporaryDirectory(prefix=f"bp_write_lim_{limit}_") as d:
            lmsb, exp = copy_golden(d, name)
            rbf = os.path.join(d, tag + ".rbf")
            with open(rbf, "wb") as f:
                f.write(SENTINEL)
            r = run_bp(bp, lmsb, fsize=limit)
            with open(rbf, "rb") as f:
                got = f.read()
            out = r.stdout + r.stderr
            base = tag + ".rbf"
            if limit in FAIL_LIMITS:
                # Образ (1957 Б) не влезает: rc != 0 и старый файл выживает целиком.
                ck.check(
                    r.returncode != 0,
                    f"limit={limit}: rc=0 при сбое записи: {out!r}",
                )
                ck.check(
                    got == SENTINEL,
                    f"limit={limit}: существующий .rbf изменён при сбое записи "
                    f"({len(got)} Б вместо {len(SENTINEL)} Б)",
                )
                ck.check(
                    os.path.getsize(rbf) == SENTINEL_LEN,
                    f"limit={limit}: размер .rbf изменился",
                )
                ck.check(
                    "write failed" in out or "short write" in out,
                    f"limit={limit}: сбой записи не отражён в выводе: {out!r}",
                )
                ck.check(
                    temp_leftovers(d, base) == [],
                    f"limit={limit}: временные файлы не убраны: {temp_leftovers(d, base)}",
                )
            else:
                ck.check(
                    r.returncode == 0,
                    f"limit={limit}: rc={r.returncode}, ожидался успех: {out!r}",
                )
                ck.check(
                    got == exp,
                    f"limit={limit}: образ {len(got)} Б расходится с эталоном {len(exp)} Б",
                )
                ck.check(
                    temp_leftovers(d, base) == [],
                    f"limit={limit}: остался временный файл",
                )


def case_limit_matrix_fresh(bp: str, ck: Checker) -> None:
    """Те же пределы при отсутствующей цели: при сбое .rbf не появляется вовсе."""
    name = GOLDEN_PROGRAMS[0]
    tag = name[1]
    for limit in FAIL_LIMITS:
        with tempfile.TemporaryDirectory(prefix=f"bp_write_newlim_{limit}_") as d:
            lmsb, _ = copy_golden(d, name)
            rbf = os.path.join(d, tag + ".rbf")
            r = run_bp(bp, lmsb, fsize=limit)
            out = r.stdout + r.stderr
            ck.check(
                r.returncode != 0,
                f"fresh limit={limit}: rc=0 при сбое записи: {out!r}",
            )
            ck.check(not os.path.exists(rbf), f"fresh limit={limit}: .rbf создан при сбое записи")
            ck.check(
                "write failed" in out or "short write" in out,
                f"fresh limit={limit}: сбой записи не отражён в выводе: {out!r}",
            )
            leftovers = temp_leftovers(d, tag + ".rbf")
            ck.check(leftovers == [], f"fresh limit={limit}: временные файлы не убраны: {leftovers}")


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
        ck.check(r.returncode != 0, f"invalid: rc=0 при parse-ошибке: {out!r}")
        ck.check("BOGUS_OPCODE" in out, "invalid: нет текста ошибки в выводе")
        ck.check(data == SENTINEL, "invalid: существующий .rbf перезаписан при parse-ошибке")
        ck.check(temp_leftovers(d, "bad.rbf") == [], "invalid: остался временный файл")


def case_mkstemp_failure_message(bp: str, ck: Checker) -> None:
    """Каталог без права записи: внятная ошибка mkstemp, цель не тронута.

    Отдельно проверяется текст: при неверном ABI (mkstemp как 64-битный Int)
    отрицательный код -1 становится 4294967295, проверка `fd < 0` мёртва и
    вместо "cannot create temporary file" печатается общий "write failed".
    """
    if is_root():
        ck.skip("mkstemp-в-readonly-каталоге (root обходит права каталога)")
        return
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
        out = r.stdout + r.stderr
        ck.check(r.returncode != 0, f"ro-dir: rc=0 при сбое mkstemp: {out!r}")
        ck.check(data == SENTINEL, "ro-dir: существующий .rbf изменён при сбое mkstemp")
        ck.check(
            "cannot create temporary file" in out,
            f"ro-dir: нет внятной ошибки mkstemp (ABI C int), вывод: {out!r}",
        )
        ck.check(temp_leftovers(d, "ro.rbf") == [], "ro-dir: остался временный файл")


def case_readonly_target_0444(bp: str, ck: Checker) -> None:
    """Файл 0444 в записываемом каталоге: отказ, как у прежнего open(path, "w")."""
    if is_root():
        ck.skip("цель 0444 (root пишет в файл 0444, как и open)")
        return
    with tempfile.TemporaryDirectory(prefix="bp_write_0444_") as d:
        lmsb = os.path.join(d, "rot.lmsb")
        with open(lmsb, "w", encoding="utf-8") as f:
            f.write(VALID_LMSB)
        rbf = os.path.join(d, "rot.rbf")
        with open(rbf, "wb") as f:
            f.write(SENTINEL)
        os.chmod(rbf, 0o444)
        try:
            r = run_bp(bp, lmsb)
            with open(rbf, "rb") as f:
                data = f.read()
            mode = os.stat(rbf).st_mode & 0o7777
        finally:
            os.chmod(rbf, 0o644)
        out = r.stdout + r.stderr
        ck.check(r.returncode != 0, f"0444: rc=0 при read-only цели: {out!r}")
        ck.check(
            "not writable" in out,
            f"0444: read-only цель обработана без отказа access(W_OK): {out!r}",
        )
        ck.check(data == SENTINEL, "0444: read-only цель заменена атомарным rename")
        ck.check(mode == 0o444, f"0444: права цели изменены: {oct(mode)}")
        ck.check(temp_leftovers(d, "rot.rbf") == [], "0444: остался временный файл")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--bp", default=None, help="путь к CLI (по умолчанию tools/bp)")
    args = ap.parse_args()
    bp = find_bp(args.bp)

    ck = Checker()
    case_valid_exact_bytes(bp, ck)
    case_goldens_exact_bytes(bp, ck)
    case_limit_matrix_existing(bp, ck)
    case_limit_matrix_fresh(bp, ck)
    case_invalid_preserves_existing(bp, ck)
    case_mkstemp_failure_message(bp, ck)
    case_readonly_target_0444(bp, ck)
    return ck.report()


if __name__ == "__main__":
    sys.exit(main())
