#!/usr/bin/env python3
"""Негативные и позитивные тесты собственных ворот порта (stdlib unittest).

Запуск из корня репозитория:
    python3 tools/tests/test_port.py

Проверяется, что tools/difftest*.sh и tools/port_verify.py не дают ложного
зелёного результата: падение компилятора, пустой/отсутствующий корпус,
пропавший или лишний эталон, stale-артефакты, отсутствие выхода при rc=0,
отсутствие baseline/оракула. Фикстуры создаются только во временных
каталогах; реальный корпус/golden не трогаются.
"""

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
PORT_VERIFY = ROOT / "tools" / "port_verify.py"

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


if __name__ == "__main__":
    unittest.main(verbosity=2)
