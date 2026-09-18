"""Точка входа для ручного/тестового запуска LSP-сервера Basic Plus.

НЕ часть src/bp/main.mojo (он запрещён к изменению): этот файл даёт
отдельный бинарь для тестов:

  uv run mojo build src/bp/lsp_test.mojo -o /tmp/bp_lsp_test
  uv run mojo run src/bp/lsp_test.mojo

Штатная врезка в main.mojo (когда будет разрешена) описана в конце
src/bp/lsp.mojo: `from bp.lsp import cmd_lsp` + `if cmd == "lsp": return cmd_lsp()`.
"""

from bp.lsp import cmd_lsp


def main() raises:
    var rc = cmd_lsp()
    if rc != 0:
        raise Error("lsp: выход с кодом " + String(rc))
