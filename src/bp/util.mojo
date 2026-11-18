"""Утилиты ввода-вывода и работы с путями для компилятора Basic Plus."""

from std.sys import argv


def _byte_at(s: String, i: Int) -> UInt8:
    return s.unsafe_ptr().unsafe_offset(i)[]


def _strip_leading_bom(s: String) -> String:
    """Снимает UTF-8 BOM только в начале потока (как StreamReader/ReadAllLines)."""
    if s.byte_length() < 3:
        return s
    if (
        Int(_byte_at(s, 0)) == 0xEF
        and Int(_byte_at(s, 1)) == 0xBB
        and Int(_byte_at(s, 2)) == 0xBF
    ):
        return String(s[byte=3 : s.byte_length()])
    return s


def read_text(path: String) raises -> String:
    """Читает файл целиком, снимая ведущий UTF-8 BOM (C# StreamReader)."""
    with open(path, "r") as f:
        return _strip_leading_bom(f.read())


def read_lines(path: String) raises -> List[String]:
    """Читает файл и разбивает на строки (без символов перевода строки).

    Соответствует C# File.ReadAllLines / StreamReader.ReadLine: снимает
    ведущий UTF-8 BOM, разделители \\r\\n, \\n и \\r, завершающий перевод
    строки не создаёт пустую строку в конце.
    """
    return text_to_lines(read_text(path))


def write_text(path: String, content: String) raises:
    """Пишет текст в файл (перезаписывает)."""
    with open(path, "w") as f:
        _ = f.write(content)


def text_to_lines(content: String) -> List[String]:
    """Разбивает текст на строки так же, как read_lines.

    Разделители \\r\\n, \\n и \\r (File.ReadAllLines); ведущий UTF-8 BOM
    снимается, embedded U+FEFF остаётся содержимым строки.
    """
    var text = _strip_leading_bom(content)
    var n = text.byte_length()
    var out = List[String]()
    var start = 0
    var i = 0
    while i < n:
        var b = Int(_byte_at(text, i))
        if b == 10 or b == 13:
            out.append(String(text[byte=start:i]))
            if b == 13 and i + 1 < n and Int(_byte_at(text, i + 1)) == 10:
                i += 1
            start = i + 1
        i += 1
    if start < n:
        out.append(String(text[byte=start:n]))
    return out^


def lines_to_text(lines: List[String]) -> String:
    """Склеивает строки как C# File.WriteAllLines: \n после каждой, включая последнюю."""
    return String("\n").join(lines) + "\n"


def dir_name(path: String) -> String:
    """Каталог файла (как Path.GetDirectoryName)."""
    var i = path.rfind("/")
    if i == -1:
        return String("")
    return String(path[byte=0:i])


def base_name(path: String) -> String:
    """Имя файла без каталога."""
    var i = path.rfind("/")
    if i == -1:
        return path
    return String(path[byte=i + 1 :])


def strip_ext(name: String) -> String:
    """Имя без последнего расширения."""
    var i = name.rfind(".")
    if i == -1:
        return name
    return String(name[byte=0:i])


def ext_name(name: String) -> String:
    """Расширение файла вместе с точкой (как Path.GetExtension)."""
    var i = name.rfind(".")
    if i == -1:
        return String("")
    return String(name[byte=i:])


def usage() -> String:
    return String(
        """bp — компилятор Basic Plus (Clev3r) для LEGO EV3

Использование:
  bp lex <file.bp>              стадии 1-2: канонические строки
  bp expand <file.bp> <outdir>  препроцессор + линковка -> ~<Имя>.bp
  bp compile <file.bp> [outdir] полный цикл -> ~Имя.bp + .lmsb + .rbf
  bp check <file.bp>            диагностики
  bp flash <file.bp|file.rbf> [target]
                              компиляция (для .bp) + заливка на кирпич
                              target: "" (usb-автовыбор) | usb[:dev] |
                              bt:AA:BB:CC:DD:EE:FF | wifi:A.B.C.D |
                              /dev/rfcommN | dry
  bp lsp                        LSP-сервер (stdio)
"""
    )