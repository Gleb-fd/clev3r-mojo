"""Тест util: чтение текста, UTF-8 BOM и разделение строк.

Ожидания соответствуют C# File.ReadAllLines / StreamReader.ReadLine:
ведущий UTF-8 BOM снимается, разделители CRLF, LF и CR равноправны,
embedded U+FEFF остаётся содержимым.

Запуск из корня репо:
  uv run mojo run src/bp/util_test.mojo
Печатает UTIL_TEST OK при успехе.
"""

from std.ffi import external_call

from bp.util import read_lines, read_text, text_to_lines, write_text


def check(cond: Bool, what: String) raises:
    if not cond:
        raise Error("FAIL: " + what)


def check_text(got: String, want: String, what: String) raises:
    if got != want:
        raise Error("FAIL: " + what + ": получено [" + got + "], ожидалось [" + want + "]")


def check_lines(got: List[String], want: List[String], what: String) raises:
    if len(got) != len(want):
        raise Error(
            "FAIL: "
            + what
            + ": строк "
            + String(len(got))
            + ", ожидалось "
            + String(len(want))
        )
    for i in range(len(want)):
        if got[i] != want[i]:
            raise Error(
                "FAIL: "
                + what
                + ": строка "
                + String(i)
                + " ["
                + got[i]
                + "], ожидалось ["
                + want[i]
                + "]"
            )


def test_text_to_lines() raises:
    check(len(text_to_lines("")) == 0, "empty source: нуль строк")

    var ab: List[String] = ["a", "b"]
    check_lines(text_to_lines("a\nb"), ab, "LF без хвостового")
    check_lines(text_to_lines("a\nb\n"), ab, "LF с хвостовым")
    check_lines(text_to_lines("a\r\nb"), ab, "CRLF без хвостового")
    check_lines(text_to_lines("a\r\nb\r\n"), ab, "CRLF с хвостовым")
    check_lines(text_to_lines("a\rb"), ab, "CR без хвостового")
    check_lines(text_to_lines("a\rb\r"), ab, "CR с хвостовым")
    var abcd: List[String] = ["a", "b", "c", "d"]
    check_lines(text_to_lines("a\r\nb\rc\nd"), abcd, "mixed CRLF/CR/LF")

    var a_blank: List[String] = ["a", ""]
    check_lines(text_to_lines("a\n\n"), a_blank, "LF: пустая строка перед хвостовым")
    check_lines(text_to_lines("a\r\r"), a_blank, "CR: пустая строка перед хвостовым")
    var blank: List[String] = [""]
    check_lines(text_to_lines("\n"), blank, "только LF: одна пустая строка")
    check_lines(text_to_lines("\r"), blank, "только CR: одна пустая строка")
    var a_blank_b: List[String] = ["a", "", "b"]
    check_lines(text_to_lines("a\r\r\nb"), a_blank_b, "CR + CRLF: пустая строка")

    check_lines(text_to_lines("\uFEFFa\nb\n"), ab, "BOM в начале потока снят")
    check_lines(
        text_to_lines("\uFEFFx = 1\ry = 2\r"),
        ["x = 1", "y = 2"],
        "BOM + CR-only (fixture C2)",
    )
    check(len(text_to_lines("\uFEFF")) == 0, "только BOM: нуль строк")

    var embedded: List[String] = ["a\uFEFFb", "\uFEFFc"]
    check_lines(
        text_to_lines("a\uFEFFb\n\uFEFFc"),
        embedded,
        "embedded U+FEFF не удаляется (в т.ч. в начале 2-й строки)",
    )
    check_text(
        text_to_lines("a\uFEFFb")[0],
        "a\uFEFFb",
        "embedded U+FEFF сохранён",
    )


def test_read_text_and_read_lines(tmp: String) raises:
    write_text(tmp, "")
    check_text(read_text(tmp), "", "read_text: empty")
    check(len(read_lines(tmp)) == 0, "read_lines: empty source")

    write_text(tmp, "a\nb\n")
    check_text(read_text(tmp), "a\nb\n", "read_text сохраняет LF")
    check_lines(read_lines(tmp), ["a", "b"], "read_lines: LF")

    write_text(tmp, "a\r\nb\r\n")
    check_text(read_text(tmp), "a\r\nb\r\n", "read_text сохраняет CRLF")
    check_lines(read_lines(tmp), ["a", "b"], "read_lines: CRLF")

    write_text(tmp, "a\rb\r")
    check_text(read_text(tmp), "a\rb\r", "read_text сохраняет CR")
    check_lines(read_lines(tmp), ["a", "b"], "read_lines: CR-only")

    write_text(tmp, "a\r\nb\rc\nd")
    check_lines(
        read_lines(tmp), ["a", "b", "c", "d"], "read_lines: mixed CRLF/CR/LF"
    )

    write_text(tmp, "\uFEFFa\nb\n")
    check_text(read_text(tmp), "a\nb\n", "read_text: ведущий BOM снят")
    check_lines(read_lines(tmp), ["a", "b"], "read_lines: ведущий BOM снят")

    write_text(tmp, "\uFEFFx = 1\rLCD.Text ( 1 , 0 , 0 , 1 , x )\r")
    check_lines(
        read_lines(tmp),
        ["x = 1", "LCD.Text ( 1 , 0 , 0 , 1 , x )"],
        "read_lines: BOM + CR-only (fixture C2)",
    )

    write_text(tmp, "\uFEFF")
    check_text(read_text(tmp), "", "read_text: только BOM")
    check(len(read_lines(tmp)) == 0, "read_lines: только BOM")

    write_text(tmp, "a\uFEFFb\nc")
    check_text(read_text(tmp), "a\uFEFFb\nc", "read_text: embedded BOM сохранён")
    check_lines(
        read_lines(tmp),
        ["a\uFEFFb", "c"],
        "read_lines: embedded U+FEFF не удаляется",
    )

    write_text(tmp, "a\n\n")
    check_lines(read_lines(tmp), ["a", ""], "read_lines: хвостовая пустая строка")


def main() raises:
    var pid = Int(external_call["getpid", Int]())
    var tmp = "/tmp/bp_util_test_" + String(pid) + ".txt"

    test_text_to_lines()
    test_read_text_and_read_lines(tmp)

    _ = external_call["unlink", Int](tmp.unsafe_ptr())
    print("UTIL_TEST OK")
