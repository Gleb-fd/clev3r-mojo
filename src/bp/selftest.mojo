"""Самопроверка базовых модулей пакета (util, diag).

Запуск: uv run mojo run src/bp/selftest.mojo
Печатает SELFTEST OK при успехе.
"""

from bp.util import (
    read_lines,
    text_to_lines,
    lines_to_text,
    base_name,
    dir_name,
    strip_ext,
    ext_name,
    write_text,
)
from bp.diag import Diagnostics


def check(cond: Bool, what: String) raises:
    if not cond:
        raise Error("FAIL: " + what)


def test_util() raises:
    var lines = read_lines("/home/ssssq/Windows/Program1.bp")
    check(len(lines) == 35, "Program1.bp: 35 строк, получено " + String(len(lines)))
    check(lines[0] == 'folder "prjs" "test123"', "первая строка")
    check(lines[10] == "Function map_data(in number n, out number data)", "строка 11")

    check(base_name("/a/b/c.bp") == "c.bp", "base_name")
    check(dir_name("/a/b/c.bp") == "/a/b", "dir_name")
    check(strip_ext("Program1.bp") == "Program1", "strip_ext")
    check(ext_name("Program1.bp") == ".bp", "ext_name")
    check(strip_ext("noext") == "noext", "strip_ext без расширения")

    check(lines_to_text(text_to_lines("a\nb\n")) == "a\nb\n", "roundtrip строк с завершающим \n")

    write_text("/tmp/bp_selftest.txt", "hello")
    check(read_lines("/tmp/bp_selftest.txt")[0] == "hello", "write/read")


def test_diag() raises:
    var d = Diagnostics()
    d.add("/a/b.bp", 3, 1032, "test msg")
    check(d.count() == 1, "одна диагностика")
    check(d.has_errors(), "has_errors")
    var m = d.bp_message(0)
    check(
        m == "file: /a/b.bp line: 3 | code: 1032 ===> test msg",
        "формат сообщения: " + m,
    )
    check(d.render().count("\n") == 0, "render одной строки")


def main() raises:
    test_util()
    test_diag()
    print("SELFTEST OK")