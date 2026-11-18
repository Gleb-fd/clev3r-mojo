"""Дымовой тест сквозных команд bp compile / bp check (герметичный).

Запуск из корня репозитория:
  uv run mojo run src/bp/buildcmd_test.mojo

Тест не зависит от /tmp/bp_work и не пишет рядом с реальным корпусом:
известные fixture-файлы репозитория копируются в уникальный scratch-каталог,
там же создаются артефакты компиляции. Переопределения:
  BP_BUILDCMD_FIXTURES — каталог fixtures (по умолчанию tools/tests/fixtures)
  BP_BUILDCMD_SCRATCH  — существующий scratch-каталог
                         (иначе уникальный /tmp/bp_buildcmd_<monotonic>)
Печатает BUILDCMD SELFTEST OK при успехе.
"""

from bp.buildcmd import cmd_compile, cmd_check
from bp.util import read_text, write_text
from std.os import getenv, mkdir
from std.time import monotonic


def _copy(src: String, dst: String) raises:
    write_text(dst, read_text(src))


def _mkdir_quiet(path: String):
    try:
        mkdir(path)
    except:
        pass


def main() raises:
    var fixtures = getenv("BP_BUILDCMD_FIXTURES", "tools/tests/fixtures")
    var scratch = getenv("BP_BUILDCMD_SCRATCH", "")
    if scratch == "":
        scratch = "/tmp/bp_buildcmd_" + String(monotonic())
        _mkdir_quiet(scratch)

    _mkdir_quiet(scratch + "/include")
    _mkdir_quiet(scratch + "/module")
    _mkdir_quiet(scratch + "/broken")

    _copy(fixtures + "/include/Main.bp", scratch + "/include/Main.bp")
    _copy(fixtures + "/include/MotorMove.bpi", scratch + "/include/MotorMove.bpi")
    _copy(fixtures + "/include/SensorRGB.bpi", scratch + "/include/SensorRGB.bpi")
    _copy(fixtures + "/module/Main.bp", scratch + "/module/Main.bp")
    _copy(fixtures + "/module/Module1.bpm", scratch + "/module/Module1.bpm")
    _copy(fixtures + "/broken/Unbalanced.bp", scratch + "/broken/Unbalanced.bp")

    var bad = 0

    var npe = scratch + "/include/Main.bp"
    var r1 = cmd_compile(npe, "")
    print("compile include/Main -> " + String(r1))
    if r1 != 0:
        bad += 1

    var mod = scratch + "/module/Main.bp"
    var r2 = cmd_compile(mod, "")
    print("compile module/Main -> " + String(r2))
    if r2 != 0:
        bad += 1

    var r3 = cmd_check(npe)
    print("check valid -> " + String(r3))
    if r3 != 0:
        bad += 1

    var r4 = cmd_check(scratch + "/broken/Unbalanced.bp")
    print("check broken -> " + String(r4))
    if r4 != 1:
        bad += 1

    if bad != 0:
        # Печатаем FAIL и завершаемся ненулевым кодом (как lexer_test/selftest),
        # иначе verify_all, судящий только по rc, видит ложный зелёный.
        print("BUILDCMD SELFTEST FAIL: " + String(bad))
        raise Error("BUILDCMD SELFTEST FAIL: " + String(bad))
    print("BUILDCMD SELFTEST OK")
