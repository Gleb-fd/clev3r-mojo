from bp.lexer import build_line, classify_word, get_words
def main() raises:
    var tests = List[String]()
    tests.append("Function map_data(in number n, out number data)")
    tests.append("Function Foo()")
    tests.append("Sub Move")
    tests.append("d1_min = 31")
    tests.append("goto end")
    tests.append("loop:")
    tests.append("LCD.Clear()")
    for ti in range(len(tests)):
        var t = tests[ti]
        var ws = get_words(t)
        print("LINE:", t)
        for i in range(len(ws)):
            var prev = String("")
            var foll = String("")
            if i > 0:
                prev = ws[i - 1]
            if i < len(ws) - 1:
                foll = ws[i + 1]
            var tok = classify_word(ws[i], prev, foll, t)
            print("   ", ws[i], "->", tok)
