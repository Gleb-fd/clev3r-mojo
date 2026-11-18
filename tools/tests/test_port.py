#!/usr/bin/env python3
"""Негативные и позитивные тесты собственных ворот порта (stdlib unittest).

Запуск из корня репозитория:
    python3 tools/tests/test_port.py

Проверяется, что tools/difftest*.sh, tools/make_golden.sh и tools/port_verify.py
не дают ложного зелёного результата: падение компилятора, пустой/отсутствующий
корпус, пропавший или лишний эталон, stale-артефакты, отсутствие выхода при
rc=0, вакуумные контуры difftest_lmsb (нет .lmsb/.rbf-оракулов), оракул
make_golden с rc!=0 или частичным выводом, semantic FAIL в buildcmd_test с
rc=0, hard-coded empty-newline в port_verify, self-comparison baseline,
отсутствие обязательных fixtures/baseline/оракула (setup error, не PASS).
Фикстуры создаются только во временных каталогах; реальный корпус/golden и
fixtures репозитория не трогаются (buildcmd-регрессия работает на копии).
"""

import importlib.util
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent.parent
DIFFTEST = ROOT / "tools" / "difftest.sh"
DIFFTEST_LMSB = ROOT / "tools" / "difftest_lmsb.sh"
DIFFTEST_RBF = ROOT / "tools" / "difftest_rbf.sh"
MAKE_GOLDEN = ROOT / "tools" / "make_golden.sh"
PORT_VERIFY = ROOT / "tools" / "port_verify.py"

_spec = importlib.util.spec_from_file_location("port_verify_gate", PORT_VERIFY)
PORT_VERIFY_MODULE = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(PORT_VERIFY_MODULE)

FAKE_BP = textwrap.dedent(
    """\
    #!/usr/bin/env python3
    import os, pathlib, shutil, sys

    mode = os.environ.get("FAKE_MODE", "ok")
    canned = pathlib.Path(__file__).resolve().parent / "canned"
    args = sys.argv[1:]

    if mode == "exit1":
        sys.exit(1)
    if mode == "nooutput":
        sys.exit(0)
    if not args:
        sys.exit(2)

    cmd = args[0]
    if cmd == "expand":
        src = pathlib.Path(args[1])
        out = pathlib.Path(args[2])
        plain = src.stem.lstrip("~")
        d = out / ("~" + plain)
        d.mkdir(parents=True, exist_ok=True)
        shutil.copy(canned / (plain + ".expanded"), d / ("~" + plain + ".bp"))
        if mode == "expand_rc1":
            sys.exit(1)
        sys.exit(0)
    if cmd == "lmsb":
        src = pathlib.Path(args[1])
        plain = src.stem.lstrip("~")
        if mode == "lmsb_exit1":
            sys.exit(1)
        shutil.copy(canned / (plain + ".lmsb"), src.parent / (plain + ".lmsb"))
        sys.exit(0)
    if cmd == "rbf":
        src = pathlib.Path(args[1])
        plain = src.stem.lstrip("~")
        if mode == "rbf_exit1":
            sys.exit(1)
        shutil.copy(canned / (plain + ".rbf"), src.parent / (plain + ".rbf"))
        sys.exit(0)
    sys.exit(2)
    """
)


class GateTest(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp(prefix="bp_gate_test."))
        self.canned = self.tmp / "canned"
        self.canned.mkdir()
        self.fake = self.tmp / "fake_bp"
        self.fake.write_text(FAKE_BP)
        self.fake.chmod(0o755)
        self.corpus = self.tmp / "corpus"
        self.gold = self.tmp / "golden"
        self.corpus.mkdir()
        self.gold.mkdir()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    # ---------- helpers ----------
    def add_program(self, rel, name=None):
        name = name or pathlib.Path(rel).stem
        p = self.corpus / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text("x = 1\n")
        return name

    def add_expected(self, name, rel=None):
        rel = rel or (name + ".bp")
        parent = pathlib.Path(rel).parent
        d = self.gold / parent / ("~" + name)
        d.mkdir(parents=True, exist_ok=True)
        (d / ("~" + name + ".bp")).write_text("EXP:" + name + "\n")
        (d / (name + ".lmsb")).write_text("LMSB:" + name + "\n")
        (d / (name + ".rbf")).write_text("RBF:" + name + "\n")
        (self.canned / (name + ".expanded")).write_text("EXP:" + name + "\n")
        (self.canned / (name + ".lmsb")).write_text("LMSB:" + name + "\n")
        (self.canned / (name + ".rbf")).write_text("RBF:" + name + "\n")
        return name

    def run_gate(self, script, stage=None, mode="ok", corpus=None, gold=None):
        env = dict(os.environ)
        env["DIFFTEST_BP"] = str(self.fake)
        env["DIFFTEST_CORPUS"] = str(corpus if corpus is not None else self.corpus)
        env["DIFFTEST_GOLD"] = str(gold if gold is not None else self.gold)
        env["FAKE_MODE"] = mode
        cmd = ["bash", str(script)]
        if stage:
            cmd.append(stage)
        return subprocess.run(
            cmd, cwd=str(self.tmp), capture_output=True, text=True, env=env
        )

    def assert_fails(self, cp, fragment):
        self.assertNotEqual(cp.returncode, 0, cp.stdout + cp.stderr)
        self.assertIn(fragment, cp.stdout + cp.stderr)

    # ---------- положительный контроль ----------
    def test_positive_fixture_all_stages_pass(self):
        self.add_program("Prog.bp")
        self.add_expected("Prog")
        for stage in ("expand", "lmsb", "rbf"):
            cp = self.run_gate(DIFFTEST, stage)
            self.assertEqual(cp.returncode, 0, cp.stdout + cp.stderr)
            self.assertIn("pass=1 fail=0 skip=0", cp.stdout)

    # ---------- компилятор врёт ----------
    def test_fake_compiler_exit1_produces_nothing_fails(self):
        self.add_program("Prog.bp")
        self.add_expected("Prog")
        cp = self.run_gate(DIFFTEST, "expand", mode="exit1")
        self.assert_fails(cp, "FAIL(expand rc)")

    def test_fake_compiler_rc0_without_output_fails(self):
        self.add_program("Prog.bp")
        self.add_expected("Prog")
        cp = self.run_gate(DIFFTEST, "expand", mode="nooutput")
        self.assert_fails(cp, "FAIL(expand: нет выхода)")

    def test_fake_compiler_rc1_after_writing_output_fails(self):
        self.add_program("Prog.bp")
        self.add_expected("Prog")
        cp = self.run_gate(DIFFTEST, "expand", mode="expand_rc1")
        self.assert_fails(cp, "FAIL(expand rc)")

    def test_lmsb_rc_checked_even_if_expand_ok(self):
        self.add_program("Prog.bp")
        self.add_expected("Prog")
        cp = self.run_gate(DIFFTEST, "lmsb", mode="lmsb_exit1")
        self.assert_fails(cp, "FAIL(lmsb rc)")

    def test_rbf_rc_checked_even_if_lmsb_ok(self):
        self.add_program("Prog.bp")
        self.add_expected("Prog")
        cp = self.run_gate(DIFFTEST, "rbf", mode="rbf_exit1")
        self.assert_fails(cp, "FAIL(rbf rc)")

    # ---------- корпус ----------
    def test_empty_corpus_fails(self):
        cp = self.run_gate(DIFFTEST, "expand")
        self.assert_fails(cp, "пустой корпус")

    def test_missing_corpus_fails(self):
        cp = self.run_gate(DIFFTEST, "expand", corpus=self.tmp / "no_such_corpus")
        self.assert_fails(cp, "нет каталога корпуса")

    def test_unexpected_missing_golden_fails(self):
        self.add_program("Prog.bp")
        cp = self.run_gate(DIFFTEST, "expand")
        self.assert_fails(cp, "FAIL(нет эталона) Prog.bp")

    def test_extra_golden_without_input_fails(self):
        self.add_program("Prog.bp")
        self.add_expected("Prog")
        self.add_expected("Ghost", rel="Ghost.bp")
        cp = self.run_gate(DIFFTEST, "expand")
        self.assert_fails(cp, "FAIL(эталон без входа)")

    # ---------- stale-артефакты ----------
    def test_stale_generated_artifacts_cannot_false_green(self):
        self.add_program("Prog.bp")
        self.add_expected("Prog")
        stale = self.corpus / "~Prog"
        stale.mkdir()
        (stale / "~Prog.bp").write_text("EXP:Prog\n")
        (stale / "Prog.lmsb").write_text("LMSB:Prog\n")
        (stale / "Prog.rbf").write_text("RBF:Prog\n")
        # Компилятор ничего не делает; старые файлы в корпусе не должны спасти.
        cp = self.run_gate(DIFFTEST, "expand", mode="exit1")
        self.assert_fails(cp, "FAIL(expand rc)")

    def test_only_allowlisted_input_is_not_green(self):
        p = self.corpus / "New_Path_Examples" / "Program1.bp"
        p.parent.mkdir(parents=True)
        p.write_text('include "../Modules/Module1"\n')
        cp = self.run_gate(DIFFTEST, "expand")
        self.assert_fails(cp, "нет ни одного сверенного входа")

    def test_known_allowlist_skips_but_normal_input_still_verified(self):
        self.add_program("Prog.bp")
        self.add_expected("Prog")
        p = self.corpus / "New_Path_Examples" / "Program1.bp"
        p.parent.mkdir(parents=True)
        p.write_text('include "../Modules/Module1"\n')
        cp = self.run_gate(DIFFTEST, "expand")
        self.assertEqual(cp.returncode, 0, cp.stdout + cp.stderr)
        self.assertIn("SKIP(известный случай без эталона) New_Path_Examples/Program1.bp", cp.stdout)
        self.assertIn("pass=1 fail=0 skip=1", cp.stdout)

    # ---------- отдельные скрипты стадий ----------
    def test_difftest_rbf_without_any_rbf_oracle_is_not_green(self):
        self.add_program("Prog.bp")
        name = self.add_expected("Prog")
        # остаётся только .lmsb-эталон, .rbf отсутствует
        (self.gold / ("~" + name) / (name + ".rbf")).unlink()
        cp = self.run_gate(DIFFTEST_RBF)
        self.assert_fails(cp, "нет ни одного сверенного .rbf")

    def test_difftest_rbf_fake_compiler_exit1_fails(self):
        self.add_program("Prog.bp")
        self.add_expected("Prog")
        cp = self.run_gate(DIFFTEST_RBF, mode="exit1")
        self.assert_fails(cp, "ошибка ассемблера")

    def test_difftest_lmsb_fake_compiler_exit1_fails(self):
        self.add_program("Prog.bp")
        self.add_expected("Prog")
        cp = self.run_gate(DIFFTEST_LMSB, mode="exit1")
        self.assert_fails(cp, "КОМАНДА УПАЛА")

    # ---------- difftest_lmsb: оба контура обязательны (D1) ----------
    def test_difftest_lmsb_positive_both_contours(self):
        self.add_program("Prog.bp")
        self.add_expected("Prog")
        cp = self.run_gate(DIFFTEST_LMSB)
        self.assertEqual(cp.returncode, 0, cp.stdout + cp.stderr)
        self.assertIn("pass=1 fail=0 skip=0", cp.stdout)
        self.assertIn("контур rbf: pass=1 fail=0", cp.stdout)

    def test_difftest_lmsb_missing_lmsb_oracle_is_not_green(self):
        # review/adv_lmsb_vacuous.sh case A: только развёртка, без .lmsb-оракула.
        d = self.gold / "Other" / "~Prog"
        d.mkdir(parents=True)
        (d / "~Prog.bp").write_text("EXP:Prog\n")
        cp = self.run_gate(DIFFTEST_LMSB)
        self.assert_fails(cp, "нет оракула .lmsb")
        self.assertIn("нет ни одного сверенного .lmsb", cp.stdout + cp.stderr)

    def test_difftest_lmsb_missing_rbf_oracle_is_fail_not_skip(self):
        # review/adv_lmsb_rbf_skip.sh: .lmsb есть, .rbf нет -> не skip, а FAIL.
        self.add_program("Prog.bp")
        name = self.add_expected("Prog")
        (self.gold / ("~" + name) / (name + ".rbf")).unlink()
        (self.canned / (name + ".rbf")).unlink()
        cp = self.run_gate(DIFFTEST_LMSB)
        self.assert_fails(cp, "нет оракула .rbf")
        self.assertIn("не skip", cp.stdout + cp.stderr)

    def test_difftest_lmsb_rbf_only_contour_not_enough(self):
        # Оба контура не сверены (нет .lmsb, .rbf-оракул лежит сам по себе).
        d = self.gold / "Other" / "~Prog"
        d.mkdir(parents=True)
        (d / "~Prog.bp").write_text("EXP:Prog\n")
        (d / "Prog.rbf").write_text("RBF:Prog\n")
        cp = self.run_gate(DIFFTEST_LMSB)
        self.assert_fails(cp, "нет оракула .lmsb")

    # ---------- verify_port: отсутствие оракула/baseline — не skip ----------
    def test_port_verify_missing_oracle_is_setup_error(self):
        bp = self.tmp / "bp"
        bp.write_text("#!/bin/sh\nexit 0\n")
        bp.chmod(0o755)
        cp = subprocess.run(
            [
                sys.executable,
                str(PORT_VERIFY),
                "--root", str(ROOT),
                "--bp", str(bp),
                "--oracle-dll", str(self.tmp / "no_such_oracle.dll"),
                "--work", str(self.tmp / "pv_work"),
            ],
            capture_output=True,
            text=True,
        )
        self.assertEqual(cp.returncode, 2, cp.stdout + cp.stderr)
        self.assertIn("нет оракула", cp.stderr)

    def test_port_verify_missing_baseline_is_setup_error(self):
        bp = self.tmp / "bp"
        bp.write_text("#!/bin/sh\nexit 0\n")
        bp.chmod(0o755)
        dll = self.tmp / "fake_oracle.dll"
        dll.write_bytes(b"not a real dll")
        env = dict(os.environ)
        env["BP_BASELINE_BINARY"] = str(self.tmp / "no_such_baseline")
        cp = subprocess.run(
            [
                sys.executable,
                str(PORT_VERIFY),
                "--root", str(ROOT),
                "--bp", str(bp),
                "--oracle-dll", str(dll),
                "--work", str(self.tmp / "pv_work"),
            ],
            capture_output=True,
            text=True,
            env=env,
        )
        self.assertEqual(cp.returncode, 2, cp.stdout + cp.stderr)
        self.assertIn("BP_BASELINE_BINARY", cp.stderr)

    # ---------- verify_port: self-comparison и setup-ошибки (D7/D8) ----------
    def _fake_cli_and_dll(self):
        bp = self.tmp / "bp"
        bp.write_text("#!/bin/sh\nexit 0\n")
        bp.chmod(0o755)
        dll = self.tmp / "fake_oracle.dll"
        dll.write_bytes(b"not a real dll")
        return bp, dll

    def test_port_verify_same_path_as_baseline_is_setup_error(self):
        bp, dll = self._fake_cli_and_dll()
        env = dict(os.environ)
        env["BP_BASELINE_BINARY"] = str(bp)
        cp = subprocess.run(
            [
                sys.executable,
                str(PORT_VERIFY),
                "--root", str(ROOT),
                "--bp", str(bp),
                "--oracle-dll", str(dll),
                "--work", str(self.tmp / "pv_work"),
            ],
            capture_output=True,
            text=True,
            env=env,
        )
        self.assertEqual(cp.returncode, 2, cp.stdout + cp.stderr)
        self.assertIn("совпадает с текущим", cp.stderr)
        self.assertNotIn("Traceback", cp.stderr)

    def test_port_verify_identical_baseline_copy_is_not_rejected_as_alias(self):
        # Копия current с тем же sha, но другим путём — законный baseline:
        # запрещён только self-comparison по resolved path, а не равный хеш.
        bp, dll = self._fake_cli_and_dll()
        baseline = self.tmp / "baseline_copy"
        shutil.copy2(bp, baseline)
        env = dict(os.environ)
        env["BP_BASELINE_BINARY"] = str(baseline)
        cp = subprocess.run(
            [
                sys.executable,
                str(PORT_VERIFY),
                "--root", str(ROOT),
                "--bp", str(bp),
                "--oracle-dll", str(dll),
                "--work", str(self.tmp / "pv_work"),
            ],
            capture_output=True,
            text=True,
            env=env,
        )
        self.assertEqual(cp.returncode, 2, cp.stdout + cp.stderr)
        # Дошли до проверки sha оракула, т.е. alias-проверка не сработала.
        self.assertIn("sha256 оракула", cp.stderr)
        self.assertNotIn("совпадает с текущим", cp.stderr)

    def test_port_verify_missing_fixtures_is_setup_error(self):
        bp, dll = self._fake_cli_and_dll()
        root = self.tmp / "root_without_fixtures"
        (root / "tests" / "corpus").mkdir(parents=True)
        cp = subprocess.run(
            [
                sys.executable,
                str(PORT_VERIFY),
                "--root", str(root),
                "--bp", str(bp),
                "--oracle-dll", str(dll),
                "--work", str(self.tmp / "pv_work"),
            ],
            capture_output=True,
            text=True,
        )
        self.assertEqual(cp.returncode, 2, cp.stdout + cp.stderr)
        self.assertIn("нет fixtures", cp.stderr)
        self.assertNotIn("Traceback", cp.stderr)

    def test_port_verify_missing_corpus_is_setup_error(self):
        bp, dll = self._fake_cli_and_dll()
        root = self.tmp / "root_without_corpus"
        (root / "tools" / "tests" / "fixtures").mkdir(parents=True)
        cp = subprocess.run(
            [
                sys.executable,
                str(PORT_VERIFY),
                "--root", str(root),
                "--bp", str(bp),
                "--oracle-dll", str(dll),
                "--work", str(self.tmp / "pv_work"),
            ],
            capture_output=True,
            text=True,
        )
        self.assertEqual(cp.returncode, 2, cp.stdout + cp.stderr)
        self.assertIn("нет каталога корпуса", cp.stderr)
        self.assertNotIn("Traceback", cp.stderr)


# Внимание: содержимое намеренно без отступа, чтобы shebang был первой строкой
# (иначе ядро не распознаёт скрипт и bash исполняет Python как shell).
FAKE_DOTNET = """\
#!/usr/bin/env python3
import os, pathlib, sys

mode = os.environ.get("FAKE_ORACLE_MODE", "ok")
if mode == "nothing":
    sys.exit(9)
# dotnet <dll> <src> <outdir>
args = sys.argv[1:]
src = pathlib.Path(args[1])
out = pathlib.Path(args[2])
n = src.stem
d = out / ("~" + n)
d.mkdir(parents=True, exist_ok=True)
if mode != "partial":
    (d / ("~" + n + ".bp")).write_text("EXP\\n")
(d / (n + ".lmsb")).write_text("L\\n")
(d / (n + ".rbf")).write_text("R\\n")
sys.exit(1 if mode == "rc1_complete" else 0)
"""


class MakeGoldenGateTest(unittest.TestCase):
    """D2: оракул rc!=0 или частичный вывод не может заменить tests/golden.

    Работает только в собственном временном repo-copy: реальный tests/golden
    и tests/corpus не трогаются.
    """

    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp(prefix="bp_golden_gate."))
        self.repo = self.tmp / "repo"
        (self.repo / "tools").mkdir(parents=True)
        shutil.copy2(MAKE_GOLDEN, self.repo / "tools" / "make_golden.sh")
        corpus = self.repo / "tests" / "corpus"
        corpus.mkdir(parents=True)
        (corpus / "Prog.bp").write_text("x = 1\n")
        self.gold = self.repo / "tests" / "golden"
        sentinel = self.gold / "Old" / "~Stale" / "~Stale.bp"
        sentinel.parent.mkdir(parents=True)
        sentinel.write_text("OLD-SENTINEL\n")
        self.bindir = self.tmp / "bin"
        self.bindir.mkdir()
        dotnet = self.bindir / "dotnet"
        dotnet.write_text(FAKE_DOTNET)
        dotnet.chmod(0o755)
        self.dll = self.tmp / "fake.dll"
        self.dll.write_bytes(b"dummy")
        self.env = dict(os.environ)
        self.env["PATH"] = str(self.bindir) + os.pathsep + self.env.get("PATH", "")
        self.env["BP_ORACLE_DLL"] = str(self.dll)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def snapshot(self):
        return {
            str(p.relative_to(self.gold)): p.read_bytes()
            for p in sorted(self.gold.rglob("*"))
            if p.is_file()
        }

    def run_make(self, mode, *args):
        self.env["FAKE_ORACLE_MODE"] = mode
        return subprocess.run(
            [
                "bash",
                str(self.repo / "tools" / "make_golden.sh"),
                "--oracle-root", str(self.tmp),
                *args,
            ],
            capture_output=True,
            text=True,
            env=self.env,
        )

    def test_dry_run_default_does_not_touch_golden(self):
        before = self.snapshot()
        cp = self.run_make("ok")
        self.assertEqual(cp.returncode, 0, cp.stdout + cp.stderr)
        self.assertIn("DRY-RUN", cp.stdout)
        self.assertEqual(self.snapshot(), before)

    def test_oracle_rc1_with_matching_outputs_cannot_apply(self):
        # review/adv_make_golden_rc.sh: rc=1 + полный вывод не должен
        # считаться успехом и не должен публиковать staging.
        before = self.snapshot()
        cp = self.run_make("rc1_complete", "--apply")
        self.assertNotEqual(cp.returncode, 0, cp.stdout + cp.stderr)
        self.assertIn("oracle rc=1", cp.stdout + cp.stderr)
        self.assertIn("FAIL(make_golden)", cp.stderr)
        self.assertNotIn("APPLIED", cp.stdout)
        self.assertEqual(self.snapshot(), before)

    def test_partial_outputs_with_rc0_cannot_apply(self):
        before = self.snapshot()
        cp = self.run_make("partial", "--apply")
        self.assertNotEqual(cp.returncode, 0, cp.stdout + cp.stderr)
        self.assertIn("нет выходов", cp.stdout + cp.stderr)
        self.assertNotIn("APPLIED", cp.stdout)
        self.assertEqual(self.snapshot(), before)

    def test_oracle_fatal_without_outputs_cannot_apply(self):
        before = self.snapshot()
        cp = self.run_make("nothing", "--apply")
        self.assertNotEqual(cp.returncode, 0, cp.stdout + cp.stderr)
        self.assertIn("oracle rc=9", cp.stdout + cp.stderr)
        self.assertEqual(self.snapshot(), before)

    def test_apply_on_success_replaces_golden(self):
        cp = self.run_make("ok", "--apply")
        self.assertEqual(cp.returncode, 0, cp.stdout + cp.stderr)
        self.assertIn("APPLIED", cp.stdout)
        self.assertFalse((self.gold / "Old" / "~Stale" / "~Stale.bp").exists())
        self.assertTrue((self.gold / "~Prog" / "Prog.lmsb").is_file())


class BuildcmdExitCodeTest(unittest.TestCase):
    """D4: semantic FAIL в buildcmd_test.mojo обязан давать ненулевой rc."""

    def test_semantic_failure_exits_nonzero_with_fail_text(self):
        source = ROOT / "src" / "bp" / "buildcmd_test.mojo"
        self.assertTrue(source.is_file(), source)
        self.assertTrue(shutil.which("uv"), "uv нужен для запуска Mojo-теста")
        tmp = pathlib.Path(tempfile.mkdtemp(prefix="bp_buildcmd_neg."))
        try:
            fixtures = tmp / "fixtures"
            shutil.copytree(ROOT / "tools" / "tests" / "fixtures", fixtures)
            # Копируем fixture и ломаем include/Main.bp (unterminated If);
            # реальные fixtures репозитория не меняются.
            (fixtures / "include" / "Main.bp").write_text(
                'include "SensorRGB"\ninclude "MotorMove"\nif True Then\n'
            )
            scratch = tmp / "scratch"
            scratch.mkdir()
            env = dict(os.environ)
            env["BP_BUILDCMD_FIXTURES"] = str(fixtures)
            env["BP_BUILDCMD_SCRATCH"] = str(scratch)
            cp = subprocess.run(
                ["uv", "run", "mojo", "run", "src/bp/buildcmd_test.mojo"],
                cwd=str(ROOT),
                env=env,
                capture_output=True,
                text=True,
                timeout=900,
            )
            out = cp.stdout + cp.stderr
            self.assertNotEqual(cp.returncode, 0, out)
            self.assertIn("BUILDCMD SELFTEST FAIL", out)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


class EmptyParityClassificationTest(unittest.TestCase):
    """D6: exact-empty current==oracle; newline допускается только baseline."""

    LMSB = "l" * 64
    RBF = "r" * 64
    H0 = "hash-empty"
    HN = "hash-newline"

    def outs(self, bp_hash, lmsb=None, rbf=None):
        return {
            "~empty.bp": bp_hash,
            "empty.lmsb": lmsb or self.LMSB,
            "empty.rbf": rbf or self.RBF,
        }

    def classify(self, cur, orc, base, cur_out=None, orc_out=None, base_out=None):
        return PORT_VERIFY_MODULE.classify_empty_parity(
            cur, orc, base,
            cur_out if cur_out is not None else self.outs(self.H0),
            orc_out if orc_out is not None else self.outs(self.H0),
            base_out if base_out is not None else self.outs(self.HN),
        )

    def test_exact_empty_and_known_baseline_newline(self):
        res = self.classify(b"", b"", b"\n")
        self.assertEqual(res["current_vs_oracle"]["verdict"], "equal")
        self.assertEqual(
            res["baseline_vs_current"]["verdict"],
            "known-prefix-newline-only-baseline",
        )
        self.assertEqual(
            res["baseline_vs_current"]["classification"],
            "documented-pre-fix-baseline-newline",
        )
        self.assertEqual(res["raw_sha256"]["current_bp"], res["raw_sha256"]["oracle_bp"])
        self.assertNotEqual(res["raw_sha256"]["baseline_bp"], res["raw_sha256"]["current_bp"])

    def test_current_newline_instead_of_empty_is_mismatch(self):
        res = self.classify(
            b"\n", b"", b"\n",
            cur_out=self.outs(self.HN),
        )
        self.assertEqual(res["current_vs_oracle"]["verdict"], "mismatch")

    def test_oracle_nonempty_is_mismatch(self):
        res = self.classify(
            b"", b"\n", b"\n",
            orc_out=self.outs(self.HN),
        )
        self.assertEqual(res["current_vs_oracle"]["verdict"], "mismatch")

    def test_missing_current_output_is_mismatch(self):
        res = self.classify(b"", b"", b"\n", cur_out={})
        self.assertEqual(res["current_vs_oracle"]["verdict"], "mismatch")

    def test_stage_mismatch_on_empty_is_mismatch(self):
        res = self.classify(
            b"", b"", b"\n",
            orc_out=self.outs(self.H0, rbf="other-rbf"),
        )
        self.assertEqual(res["current_vs_oracle"]["verdict"], "mismatch")

    def test_baseline_identical_bytes_is_equal(self):
        res = self.classify(b"", b"", b"", base_out=self.outs(self.H0))
        self.assertEqual(res["baseline_vs_current"]["verdict"], "equal")

    def test_baseline_other_byte_difference_is_mismatch(self):
        res = self.classify(b"", b"", b"\nX", base_out=self.outs("hash-newline-x"))
        self.assertEqual(res["baseline_vs_current"]["verdict"], "mismatch")
        self.assertEqual(
            res["baseline_vs_current"]["classification"],
            "unexpected-baseline-current-mismatch",
        )

    def test_baseline_newline_but_stage_differs_is_mismatch(self):
        res = self.classify(
            b"", b"", b"\n",
            base_out=self.outs(self.HN, lmsb="other-lmsb"),
        )
        self.assertEqual(res["baseline_vs_current"]["verdict"], "mismatch")


if __name__ == "__main__":
    unittest.main(verbosity=2)
