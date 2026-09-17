"""CLI компилятора Basic Plus.

Команды: lex | expand | compile | check | flash | lsp (см. util.usage).
"""

from std.sys import argv
from bp.util import read_lines, usage, base_name, strip_ext
from bp.diag import Diagnostics
from bp.lexer import build_line, canonical_text


def cmd_lex(path: String) raises -> Int:
    """Стадии 1-2: печатает канонический текст каждой строки."""
    var lines = read_lines(path)
    for i in range(len(lines)):
        var line = build_line(lines[i], i + 1)
        if len(line.words) == 0:
            print("")
            continue
        var words = List[String]()
        for j in range(len(line.words)):
            words.append(line.words[j].text)
        print(canonical_text(words))


def cmd_not_implemented(name: String) -> Int:
    print("bp " + name + ": ещё не реализовано (см. README.md, раздел «Статус»)")
    return 1


def main() raises:
    var a = argv()
    if len(a) < 2:
        print(usage())
        return

    var cmd = a[1]
    if cmd == "lex":
        if len(a) < 3:
            print("нужен путь к файлу: bp lex <file.bp>")
            return
        _ = cmd_lex(a[2])
        return
    if cmd == "expand" or cmd == "compile" or cmd == "check" or cmd == "flash":
        _ = cmd_not_implemented(cmd)
        return
    if cmd == "lsp":
        _ = cmd_not_implemented(cmd)
        return
    print(usage())