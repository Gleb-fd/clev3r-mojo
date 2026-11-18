"""Точка входа для ручного/тестового запуска LSP-сервера Basic Plus.

НЕ часть src/bp/main.mojo (он запрещён к изменению): этот файл даёт
отдельный бинарь для тестов:

  uv run mojo build src/bp/lsp_test.mojo -o /tmp/bp_lsp_test
  uv run mojo run src/bp/lsp_test.mojo

Штатная врезка в main.mojo — `from bp.lsp import cmd_lsp` +
`if cmd == "lsp": return cmd_lsp()`; код выхода пробрасывается как есть
(кадрирование/старт tmp -> ненулевой код, а не исключение Mojo).
"""

from std.sys import exit
from bp.lsp import cmd_lsp


def main() raises:
    var rc = cmd_lsp()
    if rc != 0:
        exit(rc)
