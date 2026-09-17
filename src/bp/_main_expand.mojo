"""ВРЕМЕННАЯ точка входа для отладки `expand`, пока compiler3.mojo в разработке.

Даёт тот же CLI (tools/bp) с командами lex/expand, но без импорта compiler3
(файл в работе у параллельной задачи и не компилируется). Перед слиянием
удаляется: main.mojo уже содержит команду expand.
"""

from std.sys import argv
from bp.util import read_lines, usage
from bp.lexer import build_line
from bp.expand import cmd_expand


def cmd_lex(path: String) raises -> Int:
    var lines = read_lines(path)
    for i in range(len(lines)):
        var line = build_line(lines[i], i + 1)
        if len(line.words) == 0:
            print("")
            continue
        var words = List[String]()
        for j in range(len(line.words)):
            words.append(line.words[j].text)
        print(String(" ").join(words))
    return 0


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
    if cmd == "expand":
        if len(a) < 3:
            print("нужен путь к файлу: bp expand <file.bp> <outdir>")
            return
        var outdir = ""
        if len(a) > 3:
            outdir = a[3]
        _ = cmd_expand(a[2], outdir)
        return
    print(usage())
