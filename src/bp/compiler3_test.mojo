"""Тест стадии 3: UTF-16-лимит строк и длинные десятичные литералы.

Границы взяты из C#-оракула (Compiler.cs:1457-1475):
  string.Length — UTF-16 code units: BMP=1, supplementary=2.
  251/252 ASCII; 125/126 emoji (250/252 units); 126 кириллицы (126 units).
  double.TryParse принимает 400-значную дробь (D9), а целое переполнение
  даёт Infinity и падение ассемблера C# — у нас осознанная ясная ошибка.

Запуск из корня репо:
  uv run mojo run src/bp/compiler3_test.mojo
Печатает COMPILER3_TEST OK при успехе.
"""

from std.sys import size_of

from bp.compiler3 import (
    compile_source_lines,
    fmt_number_literal,
    strtod_endptr_bytes,
    strtod_full,
    try_parse_float,
    utf16_length,
)


def check(cond: Bool, what: String) raises:
    if not cond:
        raise Error("FAIL: " + what)


def repeat(part: String, n: Int) -> String:
    var out = String("")
    for _ in range(n):
        out += part
    return out^


def lcd_lines(value: String) -> List[String]:
    var lines = List[String]()
    lines.append("LCD.Text ( 1 , 0 , 0 , 1 , \"" + value + "\" )")
    return lines^


def expect_text_ok(value: String, what: String) raises:
    var out = compile_source_lines(lcd_lines(value))
    check(out.byte_length() > 0, what + ": компилируется")
    check("CALL LCD.TEXT" in out, what + ": вызов LCD.Text в листинге")


def expect_text_error(value: String, what: String) raises:
    var raised = False
    var msg = String("")
    try:
        _ = compile_source_lines(lcd_lines(value))
    except e:
        raised = True
        msg = String(e)
    check(raised, what + ": отвергается")
    check("Text is longer than 251 letters" in msg, what + ": диагностика длины: " + msg)


def expect_number_out_of_range(value: String, what: String) raises:
    var lines = List[String]()
    lines.append("gv_x = " + value)
    var raised = False
    var msg = String("")
    try:
        _ = compile_source_lines(lines)
    except e:
        raised = True
        msg = String(e)
    check(raised, what + ": отвергается")
    check("Number is out of range for Float64" in msg, what + ": ясная ошибка: " + msg)
    check(
        "String is not convertible to float" not in msg,
        what + ": нет внутренней ошибки парсера Mojo",
    )


def test_utf16_length() raises:
    check(utf16_length("") == 0, "utf16: пустая строка")
    check(utf16_length("abc") == 3, "utf16: ASCII")
    check(utf16_length("жжж") == 3, "utf16: BMP-кириллица по 1 unit")
    check(utf16_length("😀") == 2, "utf16: supplementary = 2 units")
    check(utf16_length("a😀ж") == 4, "utf16: смешанная строка")


def test_string_length_limits() raises:
    var ascii251 = repeat("a", 251)
    var ascii252 = repeat("a", 252)
    expect_text_ok(ascii251, "251 ASCII (251 unit)")
    expect_text_error(ascii252, "252 ASCII")

    var cyr126 = repeat("ж", 126)
    expect_text_ok(cyr126, "126 кириллицы (252 байта, 126 units, fixture B1)")
    expect_text_error(repeat("ж", 252), "252 кириллицы")

    var emoji125 = repeat("😀", 125)
    var emoji126 = repeat("😀", 126)
    expect_text_ok(emoji125, "125 emoji (250 units, fixture B5)")
    expect_text_error(emoji126, "126 emoji (252 units, fixture B6)")

    var mixed251 = "😀" + repeat("a", 249)
    var mixed252 = "😀" + repeat("a", 250)
    check(utf16_length(mixed251) == 251, "mixed: ровно 251 unit")
    expect_text_ok(mixed251, "смешанная строка на 251 unit")
    expect_text_error(mixed252, "смешанная строка на 252 unit")

    # escape_string_lit не должен влиять на считаемую длину.
    var escaped251 = repeat("\\", 251)
    expect_text_ok(escaped251, "251 обратный слэш")


def test_long_decimal_literals() raises:
    var digits400 = repeat("1", 400)

    var frac = try_parse_float("0." + digits400)
    check(frac.has, "D9: 400-значная дробь разобрана")
    check(
        fmt_number_literal(frac.value) == "0.1111111111111111",
        "D9: round-trip как C#/oracle: " + fmt_number_literal(frac.value),
    )

    var frac_lines = List[String]()
    frac_lines.append("gv_x = 0")
    frac_lines.append("gv_x = 0." + digits400)
    frac_lines.append("LCD.Text ( 1 , 0 , 0 , 1 , gv_x )")
    var lmsb = compile_source_lines(frac_lines)
    check(
        "MOVEF_F 0.1111111111111111 VGV_X" in lmsb,
        "D9: листинг совпадает с oracle (MOVEF_F 0.1111111111111111)",
    )

    # C# .NET 6 принимает целое как Infinity и затем падает на INFINITY.0;
    # здесь осознанно возвращаем ясную ошибку (safety difference).
    expect_number_out_of_range(digits400, "D8: 400-значное целое")

    var just_over_float_parser_limit = try_parse_float(repeat("9", 30))
    check(just_over_float_parser_limit.has, "30 цифр: длиннее лимита Float64(String)")
    check(
        fmt_number_literal(just_over_float_parser_limit.value) == "1E+30.0",
        "30 цифр: корректное округление (1E+30.0)",
    )


def test_strtod_abi_and_full_consumption() raises:
    # C ABI strtod: второй параметр — char** (pointer-sized out-параметр).
    # Раньше под него давали Array[UInt8, 1], т.е. libc писала 8 байт в
    # 1-байтовый буфер (LLVM IR: alloca [1 x i8]) — UB. Типовая проверка:
    # ширина слота равна ширине указателя/Int.
    check(
        strtod_endptr_bytes() == size_of[Int](),
        "strtod endptr: pointer-sized out-параметр",
    )
    check(strtod_endptr_bytes() == 8, "strtod endptr: 8 байт на x86_64/aarch64")

    # Полный разбор строки: без NUL-терминатора или без проверки endptr
    # длинная строка даёт None / мусор. Строка собрана конкатенацией —
    # у String в Mojo нет гарантированного NUL, strtod_full копирует в свой буфер.
    var digits400 = repeat("1", 400)
    var full = strtod_full("0." + digits400)
    check(Bool(full), "strtod: 400-значная дробь разобрана целиком")
    check(
        full.value() == 0.1111111111111111,
        "strtod: корректное округление D9",
    )
    check(
        Bool(strtod_full(repeat("1", 402) + ".0")),
        "strtod: 402-значное целое разобрано (буфер с NUL)",
    )

    # Частичный разбор отвергается явно (endptr не дошёл до конца).
    check(not Bool(strtod_full("1.25x")), "strtod: хвост 'x' — отказ")
    check(not Bool(strtod_full("1,25")), "strtod: запятая — отказ (не C locale)")
    check(not Bool(strtod_full("1.25 ")), "strtod: пробел в конце — отказ")
    check(strtod_full("1.25").value() == 1.25, "strtod: '1.25' целиком")

    # Через try_parse_float частичный разбор даёт обычную диагностику
    # (не молчаливое другое число). Грамматика сканера (цифры/точка) сюда
    # не пропускает такие строки, поэтому проверяем helper напрямую.
    check(not try_parse_float("1,25").has, "try_parse_float: '1,25' не число")
    check(try_parse_float("1.25").has, "try_parse_float: '1.25' число")


def test_dotnet_number_format_boundaries() raises:
    # C# NumberExpression.PreparedValue(): double.ToString(InvariantCulture)
    # (.NET Core 3.0+, shortest round-trip) + ".0", если нет '.'.
    # Проверено на оракуле InterpreterConsole.dll: fixed для exp -4..16,
    # scientific для exp >= 17 и exp <= -5.
    check(
        fmt_number_literal(9007199254740992.0) == "9007199254740992.0",
        "2^53: C# fixed, не 9.007199254740992E+15: "
        + fmt_number_literal(9007199254740992.0),
    )
    check(
        fmt_number_literal(100000000000000.0) == "100000000000000.0",
        "1e14: fixed",
    )
    check(
        fmt_number_literal(1000000000000000.0) == "1000000000000000.0",
        "1e15: fixed",
    )
    check(
        fmt_number_literal(10000000000000000.0) == "10000000000000000.0",
        "1e16: fixed (граница снизу от scientific)",
    )
    check(
        fmt_number_literal(100000000000000000.0) == "1E+17.0",
        "1e17: scientific",
    )
    check(
        fmt_number_literal(123456789012345678.0) == "1.2345678901234568E+17",
        "17 значащих цифр, exp 17: scientific",
    )
    check(
        fmt_number_literal(1234567890123456.0) == "1234567890123456.0",
        "16 значащих цифр, exp 15: fixed",
    )
    check(fmt_number_literal(0.0001) == "0.0001", "exp -4: fixed")
    check(fmt_number_literal(0.00001) == "1E-05.0", "exp -5: scientific")

    # Negative counterparts (C#: -value через ToString).
    check(
        fmt_number_literal(-9007199254740992.0) == "-9007199254740992.0",
        "-2^53: fixed с минусом",
    )
    check(
        fmt_number_literal(-1000000000000000.0) == "-1000000000000000.0",
        "-1e15: fixed",
    )
    check(
        fmt_number_literal(-10000000000000000.0) == "-10000000000000000.0",
        "-1e16: fixed",
    )
    check(
        fmt_number_literal(-100000000000000000.0) == "-1E+17.0",
        "-1e17: scientific",
    )

    # Round-trip: fixed-формы разбираются обратно в то же Float64.
    var fixed_vals: List[Float64] = [
        100000000000000.0,
        1000000000000000.0,
        10000000000000000.0,
        9007199254740992.0,
        1234567890123456.0,
        -10000000000000000.0,
    ]
    for i in range(len(fixed_vals)):
        var v = fixed_vals[i]
        var s = fmt_number_literal(v)
        check(
            Float64(s) == v,
            "round-trip: " + s + " == исходное Float64",
        )


def main() raises:
    test_utf16_length()
    test_string_length_limits()
    test_long_decimal_literals()
    test_strtod_abi_and_full_consumption()
    test_dotnet_number_format_boundaries()
    print("COMPILER3_TEST OK")
