"""CLI компилятора Basic Plus.

Команды: lex | expand | compile | check | flash | lmsb | lsp (см. util.usage).
"""

from std.sys import argv
from bp.util import read_lines, usage, base_name, dir_name, strip_ext, write_text
from bp.diag import Diagnostics
from bp.lexer import build_line, Line, _sub_bytes
from bp.compiler3 import compile_source_lines
from bp.expand import cmd_expand
from bp.asm import assemble_lmsb


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
        print(String(" ").join(words))
    return 0


def cmd_lmsb(path: String) raises -> Int:
    """Стадия 3: развёрнутый ~Имя.bp → <Имя>.lmsb в том же каталоге.

    <Имя> = имя файла развёртки без ведущего '~' и без расширения
    (соответствие оракулам tests/golden/<rel>/~<Имя>/<Имя>.lmsb).
    """
    var lines = read_lines(path)
    var text: String = ""
    var failed = False
    try:
        text = compile_source_lines(lines)
    except e:
        failed = True
        print("bp lmsb: error:", e)
    if failed:
        return 1

    var name = strip_ext(base_name(path))
    if name.startswith("~"):
        name = String(_sub_bytes(name, 1, name.byte_length()))
    var d = dir_name(path)
    var outfile = name + ".lmsb"
    if d != "":
        outfile = d + "/" + outfile
    write_text(outfile, text)
    return 0


def cmd_rbf(path: String) raises -> Int:
    """Стадия 4: листинг <Имя>.lmsb -> бинарный байткод <Имя>.rbf в том же каталоге."""
    var errors = assemble_lmsb(path)
    if len(errors) > 0:
        for i in range(len(errors)):
            print(errors[i])
        return 1
    return 0


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
    if cmd == "lmsb":
        if len(a) < 3:
            print("нужен путь к файлу: bp lmsb <путь/к/~Имя/~Имя.bp>")
            return
        _ = cmd_lmsb(a[2])
        return
    if cmd == "rbf":
        if len(a) < 3:
            print("нужен путь к файлу: bp rbf <путь/к/<Имя>.lmsb>")
            return
        _ = cmd_rbf(a[2])
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
    if cmd == "compile" or cmd == "check" or cmd == "flash":
        _ = cmd_not_implemented(cmd)
        return
    if cmd == "lsp":
        _ = cmd_not_implemented(cmd)
        return
    print(usage())