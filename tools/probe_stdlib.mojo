# Пробник возможностей stdlib Mojo 1.1 (версия 2).
# Запуск: uv run mojo run tools/probe_stdlib.mojo
from std.collections import Dict


comptime KEYWORDS = " for endfor if then endif else elseif while endwhile and or sub endsub goto step to import include folder in out function endfunction number number[] string string[] private region endregion break continue return "


@fieldwise_init
struct Word(Copyable, Movable):
    var text: String
    var token: Int
    var number: Int


@fieldwise_init
struct Line(Copyable, Movable):
    var words: List[Word]
    var line_type: Int
    var line_number: Int


def is_keyword(w: String) -> Bool:
    return (" " + w.lower() + " ") in KEYWORDS


def probe_strings() raises:
    var s = String("  LCD.Text ( 1 , 0 , 0 , 2 , gv_d1 )  ")
    print("strip  :", s.strip())
    print("lower  :", s.lower())
    print("find(  :", s.find("("), "rfind:", s.rfind("("))
    print("startsw:", s.strip().startswith("LCD"))
    print("count  :", s.count(","))
    print("bytesl :", s[byte=2:5])
    print("bytech :", s[byte=2])
    print("bytelen:", s.byte_length())
    var parts = s.strip().split(" ")
    print("split  :", parts, len(parts))
    print("join   :", String(",").join(parts))
    print("replace:", String("a b c").replace(" ", ""))
    print("format :", String("{}-{}").format(1, "x"))
    print("num2s  :", String(42), String(3.5))
    print("kw     :", is_keyword("EndFor"), is_keyword("nope"))
    print("sq     :", String("it's").count("'"))


def probe_lists() raises:
    var xs = List[String]()
    xs.append("a")
    xs.append("b")
    xs.append("c")
    xs[1] = "B"
    xs.insert(0, "z")
    print("list   :", xs, len(xs), xs[1])
    _ = xs.pop()
    var words = List[Word]()
    words.append(Word("LCD", 0, 1))
    words.append(Word("Clear", 1, 2))
    print("structs:", words[0].text, words[1].token, len(words))
    var l = Line(words^, 8, 1)
    print("line   :", l.words[0].text, l.line_type)


def probe_dict() raises:
    var d = Dict[String, Int]()
    d["a"] = 1
    d["b"] = 2
    print("dict   :", d["a"], len(d), "b" in d)
    for k in d:
        print("  key  :", k, d[k])


def probe_files() raises:
    with open("/home/ssssq/Windows/Program1.bp", "r") as f:
        var content = f.read()
        var lines = content.split("\n")
        print("file   :", content.byte_length(), len(lines))
        print("line1  :", lines[0])
        print("line11 :", lines[10])
    with open("/tmp/probe_out.txt", "w") as f:
        _ = f.write("hello\n")


def probe_argv() raises:
    from std.sys import argv
    print("argv   :", argv())


def main() raises:
    probe_strings()
    probe_lists()
    probe_dict()
    probe_files()
    probe_argv()
    print("PROBE OK")