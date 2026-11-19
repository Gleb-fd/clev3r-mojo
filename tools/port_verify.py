#!/usr/bin/env python3
"""verify_port: живой оракул C#, точечные регрессии и benchmark без зависимостей.

Запускается из tools/verify_port.sh (утверждённая команда):
    bash tools/verify_port.sh /path/to/Clev3r-1

Свойства:
  * оракул — только существующий InterpreterConsole.dll (SDK не требуется);
  * входы и выходы изолированы по каталогам, вывод оракула не перезаписывается;
  * каждый запуск — в свежем scratch, выходы удаляются перед каждым прогоном;
  * ошибки сравниваются по стадии/коду ошибки, а не по локализованному тексту
    (в порте отсутствует ErrorsCodeList, тексты принципиально другие);
  * намеренные отличия зафиксированы явно: exact-empty источник (актуальный
    порт и оракул дают b"", старый baseline — документированный b"\n") и
    '..' в include; любой другой mismatch empty — FAIL, а не запись в отчёт;
  * self-comparison запрещён: baseline обязан быть отдельным путём от current
    (совпадение sha при разных путях — законная копия, помечается явно);
  * benchmark: warmup>=3, measure>=9, perf_counter вокруг subprocess.run,
    median/min/max + сырые samples, сравнение выходов вне timed-секции;
    инструменты замеряются interleaved с ротацией порядка по итерациям, а
    решение о регрессии считается по медиане ПАРНЫХ отношений c_i/b_i
    (дрейф-устойчиво); медианы отдельных выборок всё равно пишутся в отчёт;
    шесть случаев: small, brickbench, generated3000 (3052 строки — тот же
    fixture, что и в сохранённом baseline t10), include, module, empty;
  * baseline для сравнительного режима обязателен: BP_BASELINE_BINARY или
    известный сохранённый артефакт с проверкой sha256. Отсутствие baseline —
    явный ненулевой код (это не skip).
Отчёт: <work>/report.json (scratch в tests/.verify_port_work, gitignored).
"""

import argparse
import datetime
import hashlib
import json
import os
import pathlib
import re
import shutil
import statistics
import subprocess
import sys
import time

KNOWN_ORACLE_DLL_SHA = "39d03dfaf2ff6306316cd7b635041d3f11c3cd067c6cf1840b4104d8431b5771"
KNOWN_BASELINE_SHA = "b37d4dfca521efdae469d422b7b3094ff5ada4dd616f9b918efd4487946a1004"
KNOWN_RUN_BASELINE = (
    pathlib.Path.home()
    / "Projects"
    / "clev3r_mojo"
    / "tests"
    / ".oracle_work"
    / "t10_20261118T100051"
    / "baseline"
    / "bp"
)

# Полный список входов корпуса (без сгенерированных каталогов '~*').
# Изменение корпуса обязано обновлять этот список явно.
CORPUS_INPUTS = [
    "BreakAndContinue/BreakAndContinueTest.bp",
    "Functions/RGB_Test.bp",
    "Functions/Test1.bp",
    "Functions/Test2.bp",
    "HiTechnic Sensors/Compass.bp",
    "HiTechnic Sensors/Seeker.bp",
    "Include/Main.bp",
    "New_Path_Examples/Program1.bp",
    "Other/ActionLoop.bp",
    "Other/Battery.bp",
    "Other/BlockingOperations.bp",
    "Other/BrickBench.bp",
    "Other/ButtonsAndMotors.bp",
    "Other/Byte.bp",
    "Other/ClickTest.bp",
    "Other/DaisyChain.bp",
    "Other/File.bp",
    "Other/GraphicsAndSounds.bp",
    "Other/HelloWorld.bp",
    "Other/I2CRegisters.bp",
    "Other/MailboxReceive.bp",
    "Other/MailboxSend.bp",
    "Other/Media_PRJS_folder.bp",
    "Other/Media_SD_folder.bp",
    "Other/Melody.bp",
    "Other/MotorCount.bp",
    "Other/MotorInvert.bp",
    "Other/MotorSteer.bp",
    "Other/MotorSynchronize.bp",
    "Other/MovingCircle.bp",
    "Other/SensorInfo.bp",
    "Other/SensorReading.bp",
    "Other/Threads.bp",
    "Other/TimeMeasurement.bp",
    "Other/TouchSensorTest.bp",
    "Other/TowersOfHanoi.bp",
    "Other/TwoMotorMovement.bp",
    "Other/VectorDemo.bp",
    "Row/Row.bp",
    "Sensor1-4/Sensor1.bp",
    "Time/Time.bp",
]

# Намеренное отличие: Mojo разрешает '..' в include/import, C# теряет ведущий
# '/' и сообщает 2001. Это осознанное исправление порта, не регрессия.
INTENTIONAL_DOTDOT = {"New_Path_Examples/Program1.bp"}

# Ожидаемые коды ошибок C#/Mojo для error-fixtures (текст не сравнивается:
# ErrorsCodeList в порте отсутствует, локализованные сообщения разные).
ERROR_CASES = {
    "Unterm.bp": 1401,
    "MissingInc.bp": 1101,
}

WARMUP = 3
MEASURED = 9
# Повторный (эскалационный) замер: больше выборок, чтобы отличить реальные 10%
# от шума на 15–20-мс кейсах (разброс одного прогона там 12–24 мс).
REPEAT_MEASURED = 31
REGRESSION_MEDIAN = 0.10
REGRESSION_ABS_MS = 1.0


class SetupError(RuntimeError):
    pass


def sha256(path):
    p = pathlib.Path(path)
    return hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else None


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def copy_corpus_sources(src, dst):
    src = pathlib.Path(src)
    dst = pathlib.Path(dst)
    for p in sorted(src.rglob("*")):
        rel = p.relative_to(src)
        if any(part.startswith("~") for part in rel.parts[:-1]):
            continue
        if p.is_dir():
            continue
        out = dst / rel
        out.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(p, out)


def safe_rmtree(path, work):
    p = pathlib.Path(path).resolve()
    w = pathlib.Path(work).resolve()
    if w not in p.parents and p != w:
        raise RuntimeError(f"refuse to remove outside work: {p}")
    if p.is_dir():
        shutil.rmtree(p)


def outputs(case_dir, stem):
    od = pathlib.Path(case_dir) / ("~" + stem)
    if not od.is_dir():
        return {}
    return {
        str(p.relative_to(od)): sha256(p)
        for p in sorted(od.rglob("*"))
        if p.is_file()
    }


def outputs_bytes(case_dir, stem):
    od = pathlib.Path(case_dir) / ("~" + stem)
    if not od.is_dir():
        return {}
    return {
        str(p.relative_to(od)): p.read_bytes()
        for p in sorted(od.rglob("*"))
        if p.is_file()
    }


def invoke(tool, src, case_dir, bp, dll, env):
    src = pathlib.Path(src)
    if tool == "current" or tool == "baseline":
        cmd = [str(bp), "compile", str(src), str(case_dir)]
    elif tool == "oracle":
        cmd = ["dotnet", str(dll), str(src), str(case_dir)]
    else:
        raise ValueError(tool)
    cp = subprocess.run(
        cmd,
        cwd=str(case_dir),
        capture_output=True,
        text=True,
        errors="backslashreplace",
        env=env,
    )
    return cmd, cp, outputs(case_dir, src.stem)


def code_of(text):
    m = re.search(r"\bcode:\s*(\d+)", text)
    return int(m.group(1)) if m else None


def combined(cp):
    return (cp.stdout or "") + (cp.stderr or "")


def now_iso():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def run_version(cmd, cwd=None):
    try:
        cp = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=120)
        lines = (cp.stdout or "").strip().splitlines()
        if not lines:
            lines = (cp.stderr or "").strip().splitlines()
        return lines[0] if lines else ""
    except Exception as e:  # noqa: BLE001 - версия не должна валить тест
        return f"unavailable: {e}"


def resolve_baseline(root):
    envp = os.environ.get("BP_BASELINE_BINARY", "").strip()
    if envp:
        p = pathlib.Path(envp).expanduser()
        if not p.is_file():
            raise SetupError(f"BP_BASELINE_BINARY не найден: {p}")
        digest = sha256(p)
        expected = os.environ.get("BP_BASELINE_SHA256", "").strip()
        if expected and digest != expected:
            raise SetupError(
                f"BP_BASELINE_SHA256 не совпадает: {digest} != {expected}"
            )
        return p, digest, "env:BP_BASELINE_BINARY"

    for cand in (KNOWN_RUN_BASELINE, root / "tests/.oracle_work/t10_20261118T100051/baseline/bp"):
        if cand.is_file() and sha256(cand) == KNOWN_BASELINE_SHA:
            return cand, KNOWN_BASELINE_SHA, "knownrun:t10_20261118T100051"
    raise SetupError(
        "нет сохранённого baseline для сравнительного режима: задайте "
        f"BP_BASELINE_BINARY (ожидаемый sha256 {KNOWN_BASELINE_SHA}) или "
        f"восстановите {KNOWN_RUN_BASELINE}"
    )


def classify_empty_parity(current_bp, oracle_bp, baseline_bp, current_out, oracle_out, baseline_out):
    """Классифицирует empty-source: current обязан совпасть с оракулом побайтово.

    current_bp/oracle_bp/baseline_bp — содержимое ~empty.bp (bytes|None).
    current_out/oracle_out/baseline_out — словари относительный путь -> sha256
    артефактов стадии (включая ~empty.bp).

    Политика (узкая, без широкого allowlist):
      * current vs oracle: verdict "equal" только если оба источника ровно b""
        И lmsb/rbf совпадают И выходы непустые; иначе "mismatch" (FAIL);
      * baseline vs current: "equal" — выходы идентичны;
        "known-prefix-newline-only-baseline" — ТОЛЬКО документированное
        PRE-fix отличие baseline (~empty.bp == b"\\n") при current b"" и
        равных lmsb/rbf; любой другой mismatch — "mismatch" (FAIL).

    Возвращает dict с verdict'ами, сырыми sha256 по стадиям и классификацией.
    """
    def digest(data):
        return None if data is None else sha256_bytes(data)

    lmsb_equal = (
        current_out.get("empty.lmsb") is not None
        and current_out.get("empty.lmsb") == oracle_out.get("empty.lmsb")
    )
    rbf_equal = (
        current_out.get("empty.rbf") is not None
        and current_out.get("empty.rbf") == oracle_out.get("empty.rbf")
    )
    current_ok = (
        current_bp == b""
        and oracle_bp == b""
        and lmsb_equal
        and rbf_equal
        and bool(current_out)
        and bool(oracle_out)
    )

    baseline_same_outputs = bool(baseline_out) and baseline_out == current_out
    baseline_known_newline = (
        baseline_bp == b"\n"
        and current_bp == b""
        and current_out.get("empty.lmsb") is not None
        and current_out.get("empty.lmsb") == baseline_out.get("empty.lmsb")
        and current_out.get("empty.rbf") is not None
        and current_out.get("empty.rbf") == baseline_out.get("empty.rbf")
    )
    if baseline_same_outputs:
        baseline_verdict = "equal"
        baseline_class = "identical-outputs"
    elif baseline_known_newline:
        baseline_verdict = "known-prefix-newline-only-baseline"
        baseline_class = "documented-pre-fix-baseline-newline"
    else:
        baseline_verdict = "mismatch"
        baseline_class = "unexpected-baseline-current-mismatch"

    return {
        "current_vs_oracle": {
            "verdict": "equal" if current_ok else "mismatch",
            "current_bp": repr(current_bp),
            "oracle_bp": repr(oracle_bp),
            "lmsb_equal": lmsb_equal,
            "rbf_equal": rbf_equal,
        },
        "baseline_vs_current": {
            "verdict": baseline_verdict,
            "classification": baseline_class,
            "baseline_bp": repr(baseline_bp),
            "current_bp": repr(current_bp),
        },
        "raw_sha256": {
            "current_bp": digest(current_bp),
            "oracle_bp": digest(oracle_bp),
            "baseline_bp": digest(baseline_bp),
            "current_outputs": dict(current_out),
            "oracle_outputs": dict(oracle_out),
            "baseline_outputs": dict(baseline_out),
        },
    }


def compare_exact(a, b):
    keys = sorted(set(a) | set(b))
    diffs = []
    for k in keys:
        if a.get(k) != b.get(k):
            diffs.append(k)
    return diffs


def main(argv=None):
    ap = argparse.ArgumentParser(description="live oracle parity + benchmark")
    ap.add_argument("--root", required=True)
    ap.add_argument("--bp", required=True, help="свежесобранный текущий CLI")
    ap.add_argument("--oracle-dll", required=True)
    ap.add_argument("--work", required=True)
    ap.add_argument("--json", default="")
    args = ap.parse_args(argv)

    root = pathlib.Path(args.root).resolve()
    bp = pathlib.Path(args.bp).resolve()
    dll = pathlib.Path(args.oracle_dll).resolve()
    work = pathlib.Path(args.work).resolve()
    fixtures = root / "tools" / "tests" / "fixtures"

    report = {
        "started": now_iso(),
        "command": [sys.argv[0]] + (argv if argv is not None else sys.argv[1:]),
        "root": str(root),
        "failures": [],
        "setup": {},
    }
    failures = report["failures"]

    def fail(where, detail):
        failures.append({"where": where, "detail": detail})
        print(f"FAIL {where}: {detail}", flush=True)

    def ok(where, detail=""):
        print(f"PASS {where}{': ' + detail if detail else ''}", flush=True)

    try:
        if not bp.is_file() or not os.access(bp, os.X_OK):
            raise SetupError(f"нет текущего CLI: {bp}")
        if not dll.is_file():
            raise SetupError(f"нет оракула: {dll}")
        # Обязательные входы ворот: без них нельзя молча деградировать до PASS.
        if not (root / "tests" / "corpus").is_dir():
            raise SetupError(f"нет каталога корпуса: {root / 'tests' / 'corpus'}")
        if not fixtures.is_dir():
            raise SetupError(
                f"нет fixtures для точечных тестов: {fixtures} "
                "(нужен tools/tests/fixtures из репозитория)"
            )
        baseline, baseline_sha, baseline_src = resolve_baseline(root)
        # Self-comparison — не независимый baseline, а mutable alias: запрещён.
        if pathlib.Path(baseline).resolve() == bp.resolve():
            raise SetupError(
                f"BP_BASELINE_BINARY совпадает с текущим CLI ({bp}); "
                "сравнение baseline/current с самим собой запрещено — укажите "
                "сохранённый PRE-fix baseline"
            )
        current_sha = sha256(bp)
        same_content = current_sha == baseline_sha
        dll_sha = sha256(dll)
        if dll_sha != KNOWN_ORACLE_DLL_SHA and os.environ.get("BP_ALLOW_ORACLE_SHA_MISMATCH") != "1":
            raise SetupError(
                "sha256 оракула не совпадает с известным: "
                f"{dll_sha} != {KNOWN_ORACLE_DLL_SHA}; сравнение остановлено "
                "(для намеренно пересобранного оракула задайте "
                "BP_ALLOW_ORACLE_SHA_MISMATCH=1)"
            )
        env = dict(
            os.environ,
            DOTNET_ROLL_FORWARD="LatestMajor",
            DOTNET_CLI_TELEMETRY_OPTOUT="1",
            DOTNET_NOLOGO="1",
        )
        report["setup"] = {
            "current_bp": {"path": str(bp), "sha256": current_sha},
            "baseline_bp": {
                "path": str(baseline),
                "sha256": baseline_sha,
                "source": baseline_src,
                # Разные пути с одинаковым sha — законная копия, но это НЕ
                # независимый источник: помечаем явно, хеш не требуем разным.
                "identity": (
                    "identical-content-copy" if same_content else "distinct-content"
                ),
                "independent_source_claimed": not same_content,
            },
            "oracle_dll": {"path": str(dll), "sha256": dll_sha},
            "versions": {
                "python": sys.version.split()[0],
                "mojo": run_version(["uv", "run", "mojo", "--version"], cwd=root),
                "dotnet_runtimes": run_version(["dotnet", "--list-runtimes"]),
            },
            "warmup": WARMUP,
            "measured": MEASURED,
        }
    except SetupError as e:
        print(f"SETUP FAIL: {e}", file=sys.stderr)
        report["setup_error"] = str(e)
        report["finished"] = now_iso()
        report["ok"] = False
        if args.json:
            pathlib.Path(args.json).write_text(json.dumps(report, indent=2, ensure_ascii=False))
        return 2

    work.mkdir(parents=True, exist_ok=True)

    # ---------------- 1. Корпус: 40 parity + 1 намеренное отличие ----------------
    corpus_src = root / "tests" / "corpus"
    corpus_dirs = {}
    for tool in ("current", "oracle"):
        d = work / "corpus" / tool
        d.mkdir(parents=True, exist_ok=True)
        copy_corpus_sources(corpus_src, d)
        corpus_dirs[tool] = d

    discovered = sorted(
        str(p.relative_to(corpus_dirs["current"]))
        for p in corpus_dirs["current"].rglob("*.bp")
    )
    expected = sorted(CORPUS_INPUTS)
    missing = sorted(set(expected) - set(discovered))
    extra = sorted(set(discovered) - set(expected))
    corpus_result = {"inputs": len(discovered), "pass": [], "intentional": [], "fail": []}
    if missing or extra:
        fail(
            "corpus/manifest",
            f"набор входов не совпал с манифестом: missing={missing} extra={extra}",
        )
    else:
        ok("corpus/manifest", f"{len(discovered)} входов")

    for rel in discovered:
        if rel in missing:
            continue
        src_name = pathlib.Path(rel).name
        stem = pathlib.Path(rel).stem
        case = {"rel": rel}
        _, cur_cp, cur_out = invoke(
            "current", corpus_dirs["current"] / rel, corpus_dirs["current"] / pathlib.Path(rel).parent,
            bp, dll, env,
        )
        _, orc_cp, orc_out = invoke(
            "oracle", corpus_dirs["oracle"] / rel, corpus_dirs["oracle"] / pathlib.Path(rel).parent,
            bp, dll, env,
        )
        case["current_rc"] = cur_cp.returncode
        case["oracle_rc"] = orc_cp.returncode
        if rel in INTENTIONAL_DOTDOT:
            ok_intentional = (
                cur_cp.returncode == 0
                and {"~" + stem + ".bp", stem + ".lmsb", stem + ".rbf"} <= set(cur_out)
                and not orc_out
                and code_of(combined(orc_cp)) == 2001
            )
            if ok_intentional:
                corpus_result["intentional"].append(rel)
                ok(f"corpus/{rel}", "намеренно: Mojo разрешает '..', C# = 2001, вывода нет")
            else:
                corpus_result["fail"].append(rel)
                fail(
                    f"corpus/{rel}",
                    "ожидалось намеренное отличие (Mojo rc=0 + артефакты; C# 2001 без вывода), "
                    f"получено current_rc={cur_cp.returncode} current_out={sorted(cur_out)} "
                    f"oracle_out={sorted(orc_out)} oracle_code={code_of(combined(orc_cp))}",
                )
            continue
        diffs = compare_exact(cur_out, orc_out)
        if cur_cp.returncode != 0:
            corpus_result["fail"].append(rel)
            fail(f"corpus/{rel}", f"текущий CLI rc={cur_cp.returncode}: {combined(cur_cp)[:300]}")
        elif orc_cp.returncode != 0:
            corpus_result["fail"].append(rel)
            fail(f"corpus/{rel}", f"оракул rc={orc_cp.returncode}: {combined(orc_cp)[:300]}")
        elif not cur_out:
            corpus_result["fail"].append(rel)
            fail(f"corpus/{rel}", "нет выходных артефактов")
        elif diffs:
            corpus_result["fail"].append(rel)
            fail(f"corpus/{rel}", f"выходы отличаются: {diffs}")
        else:
            corpus_result["pass"].append(rel)
    ok(
        "corpus/parity",
        f"pass={len(corpus_result['pass'])} intentional={len(corpus_result['intentional'])} "
        f"fail={len(corpus_result['fail'])}",
    )
    report["corpus"] = corpus_result

    # ---------------- 2. Точечные fixtures ----------------
    targeted = {}

    def prepare_fixture(label, src_dir, tool):
        d = work / "targeted" / label / tool
        d.mkdir(parents=True, exist_ok=True)
        shutil.copytree(src_dir, d, dirs_exist_ok=True)
        return d

    def run_fixture(label, src_dir, entry, tools=("current", "oracle")):
        dirs = {t: prepare_fixture(label, src_dir, t) for t in tools}
        res = {}
        for t in tools:
            cmd, cp, out = invoke(t, dirs[t] / entry, dirs[t], bp if t != "oracle" else baseline, dll, env)
            res[t] = {
                "cmd": cmd,
                "rc": cp.returncode,
                "stdout": cp.stdout[-1000:],
                "stderr": cp.stderr[-1000:],
                "code": code_of(combined(cp)),
                "outputs": out,
                "dir": dirs[t],
            }
        return res

    # small/include/module: полный побайтовый parity
    for label, sub, entry in (
        ("small", "small", "Test1.bp"),
        ("include", "include", "Main.bp"),
        ("module", "module", "Main.bp"),
    ):
        res = run_fixture(label, fixtures / sub, entry)
        cur, orc = res["current"], res["oracle"]
        diffs = compare_exact(cur["outputs"], orc["outputs"])
        ok_case = (
            cur["rc"] == 0
            and orc["rc"] == 0
            and bool(cur["outputs"])
            and not diffs
        )
        if ok_case:
            ok(f"targeted/{label}", f"parity, файлов={len(cur['outputs'])}")
        else:
            fail(
                f"targeted/{label}",
                f"current_rc={cur['rc']} oracle_rc={orc['rc']} "
                f"outputs={sorted(cur['outputs'])} diffs={diffs}",
            )
        targeted[label] = {
            "rc": {"current": cur["rc"], "oracle": orc["rc"]},
            "outputs_equal": not diffs,
        }

    # errors: коды/стадия совпадают; локализованный текст не сравнивается
    for entry, expected_code in ERROR_CASES.items():
        res = run_fixture("error_" + pathlib.Path(entry).stem, fixtures / "errors", entry)
        cur, orc = res["current"], res["oracle"]
        ok_case = (
            cur["rc"] != 0
            and cur["code"] == expected_code
            and orc["code"] == expected_code
            and not cur["outputs"]
            and not orc["outputs"]
        )
        if ok_case:
            ok(f"targeted/error/{entry}", f"code={expected_code}, артефактов нет")
        else:
            fail(
                f"targeted/error/{entry}",
                f"ожидался code={expected_code} без артефактов: current_rc={cur['rc']} "
                f"current_code={cur['code']} current_out={sorted(cur['outputs'])} "
                f"oracle_code={orc['code']} oracle_out={sorted(orc['outputs'])}",
            )
        targeted["error_" + pathlib.Path(entry).stem] = {
            "expected_code": expected_code,
            "current": {"rc": cur["rc"], "code": cur["code"]},
            "oracle": {"rc": orc["rc"], "code": orc["code"]},
        }

    report["targeted"] = targeted

    # ---------------- 3. Benchmark (сравнение выходов вне timed-секции) ----------------
    # Фикстуры-файлы (а не генерация в коде): те же входы, что в сохранённом
    # baseline t10 (large/BrickBench.bp = 274 строки, large/Generated3000.bp =
    # 3052 строки), поэтому baseline/current/oracle считаются на одном workload.
    bench_specs = [
        ("small", "small", "Test1.bp", None),
        ("brickbench", "large", "BrickBench.bp", None),
        ("generated3000", "large", "Generated3000.bp", None),
        ("include", "include", "Main.bp", None),
        ("module", "module", "Main.bp", None),
        ("empty", "empty", "empty.bp", None),
    ]

    def prepare_bench(label, sub, entry, text):
        dirs = {}
        for tool in ("baseline", "current", "oracle"):
            d = work / "bench" / label / tool
            d.mkdir(parents=True, exist_ok=True)
            if text is not None:
                (d / entry).write_text(text, encoding="utf-8", newline="")
            else:
                shutil.copytree(fixtures / sub, d, dirs_exist_ok=True)
            dirs[tool] = d
        return dirs

    def measure_one(tool, d, entry, binary):
        """Один замер; -> (ms, None) или (None, error)."""
        stem = pathlib.Path(entry).stem
        outdir = d / ("~" + stem)
        safe_rmtree(outdir, work)
        t0 = time.perf_counter()
        cmd = (
            [str(binary), "compile", str(d / entry), str(d)]
            if tool in ("baseline", "current")
            else ["dotnet", str(dll), str(d / entry), str(d)]
        )
        cp = subprocess.run(
            cmd, cwd=str(d), capture_output=True, text=True,
            errors="backslashreplace", env=env,
        )
        dt_ms = (time.perf_counter() - t0) * 1000.0
        if cp.returncode != 0 or not (outdir / (stem + ".rbf")).is_file():
            return None, {
                "rc": cp.returncode,
                "stdout": cp.stdout[-500:],
                "stderr": cp.stderr[-500:],
            }
        return dt_ms, None

    def measure_group(specs, measured=MEASURED):
        """Round-robin (interleaved) замер нескольких инструментов.

        specs: [(tool, dir, entry, binary), ...]. Каждая итерация прогоняет ВСЕ
        инструменты по очереди, поэтому дрейф частоты CPU/планировщика влияет
        на всех одинаково, а не смещает тот инструмент, чей блок шёл первым.
        Дополнительно порядок КРУТИТСЯ по итерациям (rotation), так что каждый
        инструмент оказывается первым/последним одинаковое число раз. ВАЖНО:
        длинный dotnet-прогон поднимает частоту CPU; если oracle крутится в том
        же роунд-робине, соседство baseline/current с ним становится
        несимметричным и даёт систематические 15–25% на 15-мс кейсах, поэтому
        на уровне вызова baseline и current замеряются вместе, а oracle —
        отдельно.
        Бюджет прежний: warmup 3, затем 9 замеров на инструмент; пороги регрессии
        (REGRESSION_MEDIAN / REGRESSION_ABS_MS) не менялись.

        Решение о регрессии/baseline принимается по ПАРНЫМ отношениям: для каждой
        итерации, где измерены baseline и current, считается c_i/b_i, и берётся
        медиана этих отношений (paired). Это устойчиво к медленному дрейфу:
        если вся машина в данной итерации медленнее, страдают оба инструмента и
        отношение остаётся около 1. Медиана же отдельных выборок на 15–20-мс
        кейсах с разбросом 12–24 мс может уехать на 20–40% от фазовых эффектов
        (ложный RED, который воспроизводился и повтором).
        """
        samples = {tool: [] for tool, _, _, _ in specs}
        errors = {}
        paired_ratio = []
        paired_delta = []
        n = len(specs)
        for i in range(WARMUP + measured):
            order = specs[i % n:] + specs[: i % n]
            iteration = {}
            for tool, d, entry, binary in order:
                if tool in errors:
                    continue
                dt_ms, err = measure_one(tool, d, entry, binary)
                if err is not None:
                    err["iteration"] = i
                    errors[tool] = err
                    continue
                iteration[tool] = dt_ms
                if i >= WARMUP:
                    samples[tool].append(dt_ms)
            if (
                i >= WARMUP
                and "baseline" in iteration
                and "current" in iteration
                and iteration["baseline"] > 0
            ):
                paired_ratio.append(
                    iteration["current"] / iteration["baseline"]
                )
                paired_delta.append(iteration["current"] - iteration["baseline"])
        pairs = {
            "n": len(paired_ratio),
            "ratios": paired_ratio,
            "deltas_ms": paired_delta,
            "median_ratio": (
                statistics.median(paired_ratio) if paired_ratio else None
            ),
            "median_delta_ms": (
                statistics.median(paired_delta) if paired_delta else None
            ),
        }
        out = {}
        for tool in samples:
            if tool in errors:
                out[tool] = {"error": errors[tool]}
                continue
            v = samples[tool]
            out[tool] = {
                "n": len(v),
                "samples_ms": v,
                "median_ms": statistics.median(v),
                "min_ms": min(v),
                "max_ms": max(v),
                "mean_ms": statistics.mean(v),
                "paired": pairs,
            }
        return out

    bench_report = {}
    for label, sub, entry, text in bench_specs:
        dirs = prepare_bench(label, sub, entry, text)
        stem = pathlib.Path(entry).stem
        rec = {}
        parity = {}

        # выходы (вне timed-секции): current vs oracle и baseline vs current
        runs = {}
        for tool, binary in (("baseline", baseline), ("current", bp), ("oracle", None)):
            safe_rmtree(dirs[tool] / ("~" + stem), work)
            cmd, cp, out = invoke(
                tool, dirs[tool] / entry, dirs[tool], binary if binary else bp, dll, env
            )
            runs[tool] = {"cmd": cmd, "rc": cp.returncode, "outputs": out}

        if label == "empty":
            # Актуальный контракт: exact-empty source — current И оракул отдают
            # ровно b"" (t3). Старый baseline с b"\n" — отдельный documented
            # PRE-fix case; он допускается ТОЛЬКО для baseline, не для current.
            def read_empty_bp(tool):
                p = dirs[tool] / "~empty" / "~empty.bp"
                return p.read_bytes() if p.is_file() else None

            mb = read_empty_bp("current")
            ob = read_empty_bp("oracle")
            bb = read_empty_bp("baseline")
            empty_cls = classify_empty_parity(
                mb, ob, bb,
                runs["current"]["outputs"],
                runs["oracle"]["outputs"],
                runs["baseline"]["outputs"],
            )
            parity["current_vs_oracle"] = empty_cls["current_vs_oracle"]
            parity["baseline_vs_current"] = empty_cls["baseline_vs_current"]
            parity["raw_sha256"] = empty_cls["raw_sha256"]
            if empty_cls["current_vs_oracle"]["verdict"] == "equal":
                ok(
                    f"bench/{label}/parity",
                    "exact empty: current == oracle == b''; lmsb/rbf равны",
                )
            else:
                fail(
                    f"bench/{label}/parity",
                    "current не совпал с оракулом на exact-empty (ожидалось "
                    "b''/b'' + равные lmsb/rbf): "
                    + json.dumps(empty_cls["current_vs_oracle"], ensure_ascii=False),
                )
            baseline_verdict = empty_cls["baseline_vs_current"]["verdict"]
            if baseline_verdict == "equal":
                ok(f"bench/{label}/baseline-parity", "baseline == current")
            elif baseline_verdict == "known-prefix-newline-only-baseline":
                ok(
                    f"bench/{label}/baseline-parity",
                    "documented PRE-fix baseline: ~empty.bp=b'\\n' vs current b''; "
                    "lmsb/rbf равны (разрешено только baseline)",
                )
            else:
                fail(
                    f"bench/{label}/baseline-parity",
                    "недокументированное расхождение baseline/current на empty: "
                    + json.dumps(empty_cls["baseline_vs_current"], ensure_ascii=False),
                )
        else:
            d_co = compare_exact(runs["current"]["outputs"], runs["oracle"]["outputs"])
            d_bc = compare_exact(runs["baseline"]["outputs"], runs["current"]["outputs"])
            if d_co:
                fail(f"bench/{label}/parity", f"current vs oracle: {d_co}")
            elif not runs["current"]["outputs"]:
                fail(f"bench/{label}/parity", "нет выходов current")
            else:
                ok(f"bench/{label}/parity", "current == oracle")
            if d_bc:
                fail(f"bench/{label}/baseline-parity", f"baseline vs current: {d_bc}")
            parity["current_vs_oracle"] = {"verdict": "equal" if not d_co else "mismatch"}
            parity["baseline_vs_current"] = {"verdict": "equal" if not d_bc else "mismatch"}

        # baseline и current замеряются ТОЛЬКО вместе, с чередованием порядка:
        # длинный dotnet-прогон (~130–250 мс) поднимает частоту CPU, и если
        # ставить oracle между ними, соседство становится несимметричным
        # (один инструмент чаще оказывается сразу после oracle и получает
        # фору 15–25% — систематический ложный RED на 15-мс кейсах).
        # Oracle меряется отдельно: его медиана нужна только для отчёта.
        timings = measure_group(
            [
                ("baseline", dirs["baseline"], entry, baseline),
                ("current", dirs["current"], entry, bp),
            ]
        )
        timings.update(
            measure_group([("oracle", dirs["oracle"], entry, None)])
        )
        for tool in ("baseline", "current", "oracle"):
            if "error" in timings[tool]:
                fail(f"bench/{label}/{tool}", f"прогон не удался: {timings[tool]['error']}")
                continue
            t = timings[tool]
            print(
                f"  {label}/{tool}: median={t['median_ms']:.3f}ms "
                f"min={t['min_ms']:.3f} max={t['max_ms']:.3f} n={t['n']}",
                flush=True,
            )

        rec["commands"] = {tool: runs[tool]["cmd"] for tool in runs}
        rec["parity"] = parity
        rec["timings"] = timings

        def regression_metric(t):
            """(ratio, delta_ms, metric_name) для решения о регрессии.

            Предпочтение — медиана ПАРНЫХ отношений c_i/b_i (дрейф-устойчиво);
            медианы отдельных выборок — только fallback, если пар нет.
            """
            pair = t.get("current", {}).get("paired") or {}
            if pair.get("median_ratio") is not None:
                return (
                    pair["median_ratio"],
                    pair["median_delta_ms"],
                    "paired-median",
                )
            if (
                "median_ms" in t.get("baseline", {})
                and "median_ms" in t.get("current", {})
            ):
                b = t["baseline"]["median_ms"]
                c = t["current"]["median_ms"]
                return c / b, c - b, "block-median"
            return None

        metric = regression_metric(timings)
        if metric is not None:
            ratio, delta, ratio_metric = metric
            rec["current_over_baseline"] = ratio
            rec["current_minus_baseline_ms"] = delta
            rec["ratio_metric"] = ratio_metric
            status = "ok"
            if ratio > 1.0 + REGRESSION_MEDIAN and delta > REGRESSION_ABS_MS:
                print(
                    f"  {label}: возможная регрессия ({ratio_metric}) "
                    f"current/baseline={ratio:.3f} (+{delta:.2f}ms), повторяю замер",
                    flush=True,
                )
                # Эскалация: больше выборок, тот же порог. На 15–20-мс кейсах
                # 9 пар дают медиану с ошибкой ~±0.1 — этого мало, чтобы
                # отличить 10% от шума; 31 пара сужает её примерно втрое.
                rep = measure_group(
                    [
                        ("baseline", dirs["baseline"], entry, baseline),
                        ("current", dirs["current"], entry, bp),
                    ],
                    measured=REPEAT_MEASURED,
                )
                metric2 = regression_metric(rep)
                if any("error" in v for v in rep.values()) or metric2 is None:
                    fail(f"bench/{label}/repeat", f"повторный замер упал: {rep}")
                else:
                    ratio2, delta2, ratio_metric2 = metric2
                    rec["repeat"] = rep
                    rec["repeat_current_over_baseline"] = ratio2
                    rec["repeat_ratio_metric"] = ratio_metric2
                    # Решение — по ОБЪЕДИНЁННЫМ парам (первый блок + повтор):
                    # больше выборок — уже доверительный интервал медианы, меньше
                    # шансов, что настоящие 3–7% перевалят порог 10% на хвосте.
                    # Реальная регрессия видна в обоих блоках и останется видна.
                    pooled = list(
                        (timings.get("current", {}).get("paired") or {}).get(
                            "ratios", []
                        )
                    ) + list(
                        (rep.get("current", {}).get("paired") or {}).get(
                            "ratios", []
                        )
                    )
                    pooled_delta = list(
                        (timings.get("current", {}).get("paired") or {}).get(
                            "deltas_ms", []
                        )
                    ) + list(
                        (rep.get("current", {}).get("paired") or {}).get(
                            "deltas_ms", []
                        )
                    )
                    if pooled:
                        ratio2 = statistics.median(pooled)
                        delta2 = statistics.median(pooled_delta)
                        ratio_metric2 = "pooled-paired-median"
                        rec["pooled_n"] = len(pooled)
                        rec["pooled_current_over_baseline"] = ratio2
                        rec["pooled_ratio_metric"] = ratio_metric2
                    if ratio2 > 1.0 + REGRESSION_MEDIAN and delta2 > REGRESSION_ABS_MS:
                        status = "confirmed-regression"
                        fail(
                            f"bench/{label}/regression",
                            f"регрессия подтверждена повтором ({ratio_metric2}): "
                            f"{ratio2:.3f} (+{delta2:.2f}ms)",
                        )
                    else:
                        status = "noise-refuted-by-repeat"
                        ok(
                            f"bench/{label}/regression",
                            f"первый замер {ratio:.3f} ({ratio_metric}), "
                            f"повтор {ratio2:.3f} ({ratio_metric2}) — шум",
                        )
            rec["regression"] = status
        if "median_ms" in timings.get("oracle", {}) and "median_ms" in timings.get("current", {}):
            rec["oracle_over_current"] = (
                timings["oracle"]["median_ms"] / timings["current"]["median_ms"]
            )
            print(
                f"  {label}: oracle/current = {rec['oracle_over_current']:.2f}x",
                flush=True,
            )
        bench_report[label] = rec
        # свежие каталоги не переиспользуем между workload'ами
        for tool in dirs:
            safe_rmtree(dirs[tool], work)

    report["benchmark"] = bench_report
    report["finished"] = now_iso()
    report["ok"] = not failures
    report["verdict"] = (
        "PASS" if not failures else f"FAIL ({len(failures)} нарушений)"
    )
    if args.json:
        pathlib.Path(args.json).write_text(
            json.dumps(report, indent=2, ensure_ascii=False)
        )
    print(f"\nVERIFY_PORT {report['verdict']}")
    print(f"report: {args.json or '(not written)'}")
    return 0 if not failures else 1


def cli(argv=None):
    """Точка входа: setup-ошибки — понятная диагностика и код 2, не traceback."""
    try:
        return main(argv)
    except SetupError as e:
        print(f"SETUP FAIL: {e}", file=sys.stderr)
        return 2
    except (FileNotFoundError, NotADirectoryError, PermissionError) as e:
        print(
            f"SETUP FAIL: {type(e).__name__}: {e} "
            "(нужны tests/corpus и tools/tests/fixtures в --root)",
            file=sys.stderr,
        )
        return 2


if __name__ == "__main__":
    sys.exit(cli())
