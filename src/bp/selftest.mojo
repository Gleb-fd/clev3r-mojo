"""Самопроверка базовых модулей пакета (util, diag).

Запуск из корня репозитория:
  uv run mojo run src/bp/selftest.mojo

Тест герметичный: читает известный fixture из репозитория
(tools/tests/fixtures/selftest/Program1.bp) и пишет только в уникальный
scratch-каталог. Переопределения:
  BP_SELFTEST_FIXTURE — путь к fixture (по умолчанию repo-relative);
  BP_SELFTEST_SCRATCH — существующий scratch-каталог (иначе создаётся
                        уникальный /tmp/bp_selftest_<monotonic>).
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
from std.os import getenv, mkdir
from std.time import monotonic

def check(cond: Bool, what: String) raises:
    if not cond:
        raise Error("FAIL: " + what)


def fixture_path() -> String:
    return getenv("BP_SELFTEST_FIXTURE", "tools/tests/fixtures/selftest/Program1.bp")


def scratch_dir() raises -> String:
    """Возвращает существующий уникальный каталог для записи."""
    var env_scratch = getenv("BP_SELFTEST_SCRATCH", "")
    if env_scratch != "":
        return env_scratch
    var path = "/tmp/bp_selftest_" + String(monotonic())
    mkdir(path)
    return path


def test_util() raises:
    # Известный fixture репозитория (не пользовательский файл вне репо).
    var path = fixture_path()
    var lines = read_lines(path)
    check(len(lines) == 35, "Program1.bp: 35 строк, получено " + String(len(lines)))
    check(lines[0] == 'folder "prjs" "test123"', "первая строка")
    check(lines[10] == "Function map_data(in number n, out number data)", "строка 11")

    check(base_name("/a/b/c.bp") == "c.bp", "base_name")
    check(dir_name("/a/b/c.bp") == "/a/b", "dir_name")
    check(strip_ext("Program1.bp") == "Program1", "strip_ext")
    check(ext_name("Program1.bp") == ".bp", "ext_name")
    check(strip_ext("noext") == "noext", "strip_ext без расширения")

    check(lines_to_text(text_to_lines("a\nb\n")) == "a\nb\n", "roundtrip строк с завершающим \n")

    var out = scratch_dir() + "/util_roundtrip.txt"
    write_text(out, "hello")
    check(read_lines(out)[0] == "hello", "write/read в уникальном scratch")


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
