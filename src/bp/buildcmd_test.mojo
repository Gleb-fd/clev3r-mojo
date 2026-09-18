"""Дымовой тест сквозных команд bp compile / bp check.

Запуск:  cd /home/ssssq/Projects/clev3r_mojo && uv run mojo run src/bp/buildcmd_test.mojo

Предварительно разложить копии корпуса в /tmp (чтобы не пачкать репозиторий):
  cp -r tests/corpus/New_Path_Examples /tmp/bp_work/NPE
  cp -r tests/corpus/Include           /tmp/bp_work/Include
  (сломанный файл /tmp/bp_work/Broken/Unbalanced.bp — создать отдельно)

Побайтовое сравнение .rbf с tests/golden — снаружи через `cmp` (см. ниже).
"""

from bp.buildcmd import cmd_compile, cmd_check


def main() raises:
    var bad = 0

    var r1 = cmd_compile("/tmp/bp_work/NPE/Program1.bp", "")
    print("compile Program1 -> " + String(r1))
    if r1 != 0:
        bad += 1

    var r2 = cmd_compile("/tmp/bp_work/Include/Main.bp", "")
    print("compile Include/Main -> " + String(r2))
    if r2 != 0:
        bad += 1

    var r3 = cmd_check("/tmp/bp_work/Include/Main.bp")
    print("check valid -> " + String(r3))
    if r3 != 0:
        bad += 1

    var r4 = cmd_check("/tmp/bp_work/Broken/Unbalanced.bp")
    print("check broken -> " + String(r4))
    if r4 != 1:
        bad += 1

    if bad != 0:
        print("BUILDCMD SELFTEST FAIL: " + String(bad))
    else:
        print("BUILDCMD SELFTEST OK")
