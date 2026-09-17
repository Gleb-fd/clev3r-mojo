"""Временная точка входа CLI только для стадии 4 (rbf).

Используется, пока src/bp/compiler3.mojo/expand.mojo других агентов не собираются
вместе с main.mojo: здесь импортируются только util/lexer/asm.
Финальная команда — `bp rbf` в src/bp/main.mojo.
"""

from std.sys import argv
from bp.asm import assemble_lmsb


def cmd_rbf(path: String) raises -> Int:
    """Стадия 4: листинг <Имя>.lmsb -> бинарный байткод <Имя>.rbf в том же каталоге."""
    var errors = assemble_lmsb(path)
    if len(errors) > 0:
        for i in range(len(errors)):
            print(errors[i])
        return 1
    return 0


def main() raises:
    var a = argv()
    if len(a) < 3:
        print("использование: bp_rbf <путь/к/<Имя>.lmsb>")
        return
    _ = cmd_rbf(a[2])
