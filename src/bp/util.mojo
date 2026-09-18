"""Утилиты ввода-вывода и работы с путями для компилятора Basic Plus."""

from std.sys import argv


def read_text(path: String) raises -> String:
    """Читает файл целиком."""
    with open(path, "r") as f:
        return f.read()


def read_lines(path: String) raises -> List[String]:
    """Читает файл и разбивает на строки (без символов перевода строки).

    Соответствует C# File.ReadAllLines / StreamReader.ReadLine: разделители
    \\n и \\r\\n, завершающий перевод строки не создаёт пустую строку в конце.
    """
    var content = read_text(path)
    var raw = content.split("\n")
    var out = List[String]()
    for i in range(len(raw)):
        var s = String(raw[i])
        if s.endswith("\r"):
            var t = String(s[byte=0 : s.byte_length() - 1])
            s = t
        out.append(s^)
    # если файл заканчивается переводом строки, split даёт лишний пустой элемент
    if len(out) > 0 and raw[len(raw) - 1].byte_length() == 0:
        _ = out.pop()
    return out^


def write_text(path: String, content: String) raises:
    """Пишет текст в файл (перезаписывает)."""
    with open(path, "w") as f:
        _ = f.write(content)


def text_to_lines(content: String) -> List[String]:
    """Разбивает текст на строки так же, как read_lines."""
    var raw = content.split("\n")
    var out = List[String]()
    for i in range(len(raw)):
        var s = String(raw[i])
        if s.endswith("\r"):
            var t = String(s[byte=0 : s.byte_length() - 1])
            s = t
        out.append(s^)
    if len(out) > 0 and raw[len(raw) - 1].byte_length() == 0:
        _ = out.pop()
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
  bp flash <file.bp|file.rbf> [device]
                              компиляция (для .bp) + заливка на кирпич
                              device: /dev/hidrawN | hidrawN | dry | "" (автовыбор)
  bp lsp                        LSP-сервер (stdio)
"""
    )