"""Самопроверка лексера стадий 1-2 (Basic Plus).

Запуск:  cd /home/ssssq/Projects/clev3r_mojo && uv run mojo run src/bp/lexer_test.mojo

Ожидания выведены НЕ из головы, а из C#-оракула: те же строки прогнаны через
Interpreter.dll (LineBuilder.GetWords + Line..ctor + LineBuilder.GetType) и
зафиксированы здесь дословно. Поэтому при расхождении правится КОД, а не тест.

Покрытие: §3 (разбиение), §4 (классификация), §5 (тип строки), §11 (квирки).
"""

from bp.lexer import (
    build_line,
    get_words,
    classify_word,
    get_line_type,
    canonical_text,
    Line,
    Word,
    TOK_METHOD,
    TOK_STRING,
    TOK_VARIABLE,
    TOK_EQU,
    TOK_SUBNAME,
    TOK_NUMBER,
    TOK_KEYWORD,
    TOK_LABEL,
    TOK_LABELNAME,
    TOK_MATHOPERATOR,
    TOK_MODULEMETHOD,
    TOK_MODULEPROPERTY,
    TOK_DOUBLEMATH,
    TOK_EQUMATH,
    TOK_BOOLOPERATOR,
    TOK_BRACKETLEFT,
    TOK_BRACKETRIGHT,
    TOK_BRACKETLEFTARRAY,
    TOK_BRACKETRIGHTARRAY,
    TOK_DOUBLEBRACKET,
    TOK_DOUBLEBRACKETARRAY,
    TOK_COMMA,
    TOK_FUNCNAME,
    TOK_PREPROCESSOR,
    TOK_NON,
    LT_VARINIT,
    LT_VARDOUBLEMATH,
    LT_VAREQUMATH,
    LT_VARARRAYINIT,
    LT_SUBINIT,
    LT_SUBCALL,
    LT_FUNCINIT,
    LT_METHODCALL,
    LT_MODULEMETHODCALL,
    LT_MODULEPROPERTY,
    LT_ONEKEYWORD,
    LT_LABELINIT,
    LT_LABELCALL,
    LT_FORINIT,
    LT_IFINIT,
    LT_ELSEIFINIT,
    LT_WHILEINIT,
    LT_INCLUDE,
    LT_FOLDER,
    LT_IMPORT,
    LT_EMPTY,
    LT_NUMBERINIT,
    LT_NUMBERARRAYINIT,
    LT_STRINGINIT,
    LT_STRINGARRAYINIT,
    LT_NON,
)


comptime FAILS_LIMIT = 40


@fieldwise_init
struct Reporter(Copyable, Movable):
    """Сборщик расхождений (глобальные var в Mojo запрещены)."""

    var fails: List[String]

    def __init__(out self):
        self.fails = List[String]()

    def fail(mut self, what: String):
        self.fails.append(what)

    def count(self) -> Int:
        return len(self.fails)


def _join(xs: List[String]) -> String:
    return String("|").join(xs)


def _texts(words: List[String]) -> String:
    return _join(words)


def _tok_list(ln: Line) -> List[Int]:
    var out = List[Int]()
    for i in range(len(ln.words)):
        out.append(ln.words[i].token)
    return out^


def _word_texts(ln: Line) -> List[String]:
    var out = List[String]()
    for i in range(len(ln.words)):
        out.append(ln.words[i].text)
    return out^


# ---------------------------------------------------------------------------
# Проверки
# ---------------------------------------------------------------------------


def check_words(mut r: Reporter, raw: String, expected: String, label: String):
    """Сравнить список слов (после Trim, без ToUpper) с ожиданием 'a|b|c'."""
    var got = _texts(get_words(raw))
    if got != expected:
        r.fail(label + ": get_words(" + raw + ") = [" + got + "], ожидалось [" + expected + "]")


def check_line(
    mut r: Reporter,
    raw: String,
    exp_words: String,
    exp_tokens: String,
    exp_type: Int,
    label: String,
):
    """Полная проверка строки: слова (UPPER), токены, тип, канонический текст."""
    var ln = build_line(raw, 1)
    var words = _word_texts(ln)
    var toks = List[String]()
    for i in range(len(ln.words)):
        toks.append(String(ln.words[i].token))

    var got_words = _join(words)
    if got_words != exp_words:
        r.fail(label + ": слова [" + got_words + "] != [" + exp_words + "] (in: " + raw + ")")

    var got_toks = _join(toks)
    if exp_tokens != "" and got_toks != exp_tokens:
        r.fail(label + ": токены [" + got_toks + "] != [" + exp_tokens + "] (in: " + raw + ")")

    if ln.line_type != exp_type:
        r.fail(
            label
            + ": тип "
            + String(ln.line_type)
            + " != "
            + String(exp_type)
            + " (in: "
            + raw
            + ")"
        )

    # Word.Number — 1-based и сквозной.
    for i in range(len(ln.words)):
        if ln.words[i].number != i + 1:
            r.fail(label + ": Word.Number[" + String(i) + "] = " + String(ln.words[i].number))
    if ln.line_number != 1:
        r.fail(label + ": line_number = " + String(ln.line_number))


def check_canon(mut r: Reporter, raw: String, expected: String, label: String):
    var ln = build_line(raw, 1)
    var got = canonical_text(_word_texts(ln))
    if got != expected:
        r.fail(label + ": canonical_text = [" + got + "] != [" + expected + "]")


def check_token(mut r: Reporter, raw: String, index: Int, expected: Int, label: String):
    var ln = build_line(raw, 1)
    if index >= len(ln.words):
        r.fail(label + ": нет слова #" + String(index) + " в " + raw)
        return
    if ln.words[index].token != expected:
        r.fail(
            label
            + ": токен слова #"
            + String(index)
            + " = "
            + String(ln.words[index].token)
            + " != "
            + String(expected)
            + " (in: "
            + raw
            + ")"
        )


def check_origin(mut r: Reporter, raw: String, index: Int, expected: String, label: String):
    """OriginText хранит исходное написание, Text — каноническое (UPPER для имён)."""
    var ln = build_line(raw, 1)
    if index >= len(ln.words):
        r.fail(label + ": нет слова #" + String(index))
        return
    if ln.words[index].origin_text != expected:
        r.fail(
            label
            + ": origin_text = ["
            + ln.words[index].origin_text
            + "] != ["
            + expected
            + "]"
        )


# ---------------------------------------------------------------------------
# §3. Разбиение строки: склейка, регистр, номера слов
# ---------------------------------------------------------------------------


def test_split_basic(mut r: Reporter) raises:
    check_line(r, "x<=y", "X|<=|Y", "2|14|2", LT_NON, "x<=y")
    check_line(r, "x>=y", "X|>=|Y", "2|14|2", LT_NON, "x>=y")
    check_line(r, "x<>y", "X|<>|Y", "2|14|2", LT_NON, "x<>y")
    # x=-1 -> минус отделяется как MATHOPERATOR (унарный минус)
    check_line(r, "x=-1", "X|=|-|1", "2|3|9|5", LT_VARINIT, "x=-1")
    check_line(r, "i=0", "I|=|0", "2|3|5", LT_VARINIT, "i=0")
    check_line(r, "a[1]", "A|[|1|]", "2|17|5|18", LT_VARARRAYINIT, "a[1]")
    check_line(r, 
        "For i=0 to 3",
        "For|I|=|0|to|3",
        "6|2|3|5|6|5",
        LT_FORINIT,
        "For i=0 to 3",
    )
    check_line(r, "Endfor", "Endfor", "6", LT_ONEKEYWORD, "Endfor")
    check_line(r, "elseIf", "elseIf", "6", LT_ELSEIFINIT, "elseIf")
    # Вызов метода: 'LCD.Clear()' -> 'LCD.Clear' + '()'.
    check_line(r, "LCD.Clear()", "LCD.Clear|()", "0|19", LT_METHODCALL, "LCD.Clear()")
    # Только имена капсятся; For/to/Endfor/elseIf остаются как в исходнике.
    check_origin(r, "For i=0 to 3", 0, "For", "регистр зарезервированного слова")
    check_origin(r, "For i=0 to 3", 1, "i", "OriginText имени")
    check_origin(r, "x<=y", 0, "x", "OriginText переменной")


def test_comments(mut r: Reporter) raises:
    # Комментарий режется ДО разбора кавычек (LineBuilder.cs:17-31).
    check_line(r, "x = 1 'коммент", "X|=|1", "2|3|5", LT_VARINIT, "комментарий")
    check_words(r, "x = 1 'коммент", "x|=|1", "комментарий: get_words")
    check_line(r, "'comment only", "", "", LT_EMPTY, "строка-комментарий")
    check_words(r, "'comment only", "", "строка-комментарий: get_words")
    # КВИРК §11.1: апостроф внутри строкового литерала обрезает строку.
    check_line(r, "x = \"it's\"", "X|=|\"it", "2|3|24", LT_VARINIT, "апостроф в строке")
    check_words(r, "x = \"it's\"", "x|=|\"it", "апостроф в строке: get_words")
    # Нормальная строка с не-ASCII не должна падать (UTF-8 по байтам).
    check_line(r, "x = \"текст\"", "X|=|\"текст\"", "2|3|1", LT_VARINIT, "кириллица в строке")


def test_glue_and_specials(mut r: Reporter) raises:
    # @ + слово склеиваются.
    check_line(r, "@d1_min", "@D1_MIN", "2", LT_NON, "@d1_min")
    check_origin(r, "@d1_min", 0, "@d1_min", "@-глобал OriginText")
    # number[] / string[] — '[' и ']' не режутся; bool[] НЕ поддержан (§3).
    check_line(r, "number[]", "number[]", "6", LT_NUMBERARRAYINIT, "number[]")
    check_line(r, "string[]", "string[]", "6", LT_STRINGARRAYINIT, "string[]")
    check_line(r, "bool[]", "BOOL|[]", "2|20", LT_NON, "bool[] (не поддержан)")
    # x++ / -- / += / -= и т.д.
    check_line(r, "x++", "X|++", "2|12", LT_VARDOUBLEMATH, "x++")
    check_line(r, "x--", "X|--", "2|12", LT_VARDOUBLEMATH, "x--")
    check_line(r, "x += 2", "X|+=|2", "2|13|5", LT_VAREQUMATH, "x += 2")
    check_line(r, "x -= 2", "X|-=|2", "2|13|5", LT_VAREQUMATH, "x -= 2")
    check_line(r, "x *= 2", "X|*=|2", "2|13|5", LT_VAREQUMATH, "x *= 2")
    check_line(r, "x /= 2", "X|/=|2", "2|13|5", LT_VAREQUMATH, "x /= 2")
    # Метка и goto.
    check_line(r, "name:", "NAME:", "7", LT_LABELINIT, "name:")
    check_line(r, "goto name", "goto|NAME", "6|8", LT_LABELCALL, "goto name")
    check_line(r, "goto End", "goto|END", "6|8", LT_LABELCALL, "goto End")
    # КВИРК: '-' + '-' склеиваются ТОЛЬКО если пара — последние слова строки.
    check_line(r, "- -1", "-|-|1", "9|9|5", LT_NON, "- -1")
    check_line(r, "x = y - -1", "X|=|Y|-|-|1", "2|3|2|9|9|5", LT_VARINIT, "x = y - -1")
    check_line(r, "x - -1 y", "X|-|-|1|Y", "2|9|9|5|2", LT_NON, "x - -1 y (не хвост)")
    # КВИРК: '+' + '+' склеивается ВСЕГДА (в отличие от '--').
    check_line(r, "x = 1 + +2", "X|=|1|++|2", "2|3|5|12|5", LT_VARINIT, "1 + +2 -> ++")


def test_quirk_vs_docstring(mut r: Reporter) raises:
    """Квирки, заявленные в докстринге lexer.mojo, проверены против C#-оракула."""
    # 1) `1 + +2` -> `++` (DOUBLEMATH), т.к. склейка '+' '+' безусловна.
    check_token(r, "x = 1 + +2", 3, TOK_DOUBLEMATH, "квирк ++ безусловный")
    # 2) `--` только в хвосте: в середине остаются два MATHOPERATOR.
    check_token(r, "x = y - -1 z", 3, TOK_MATHOPERATOR, "квирк -- не в хвосте")
    # 3) `number[5` + `]`: '[' не режется, но парный ']' склеивается в ']'? Нет:
    #    ']' тоже остаётся частью слова только если tmp == 'number['.
    check_words(r, "number[5]", "number[5|]", "квирк number[")
    check_line(r, "x = number[1]", "X|=|number[1|]", "2|3|24|18", LT_VARINIT, "number[1]")
    # 4) '@' + слово склеиваются.
    check_words(r, "@ d1", "@d1", "квирк @-склейка")
    # 5) `==` склеивается, но TokenBuilder такого слова не знает -> NON (квирк §11.4).
    check_token(r, "x==1", 1, TOK_NON, "квирк == -> NON")
    check_line(r, "x==1", "X|==|1", "2|24|5", LT_NON, "x==1")
    # 6) `!=`, `&&`, `||`, `%`, `^`, `;`, `{}` — тоже NON.
    check_token(r, "x != y", 1, TOK_NON, "!= -> NON")
    check_token(r, "x && y", 1, TOK_NON, "&& -> NON")
    check_token(r, "x || y", 1, TOK_NON, "|| -> NON")
    check_token(r, "a%b", 1, TOK_NON, "% -> NON")
    check_token(r, "a^b", 1, TOK_NON, "^ -> NON")
    check_token(r, "{ }", 0, TOK_NON, "{} -> NON")
    # 7) Канонический текст переставляет пробелы (§11.9).
    check_canon(r, "LCD.Clear()", "LCD.Clear ()", "canonical LCD.Clear()")
    check_canon(r, "For i=0 to 3", "For I = 0 to 3", "canonical For")
    check_canon(r, "", "", "canonical пустой")


# ---------------------------------------------------------------------------
# §4. Классификация слов
# ---------------------------------------------------------------------------


def test_classify_tokens(mut r: Reporter) raises:
    # METHOD для встроенного класса.
    check_token(r, "lcd.text", 0, TOK_METHOD, "METHOD lcd.text")
    check_token(r, "LCD.Clear()", 0, TOK_METHOD, "METHOD LCD.Clear")
    check_token(r, "ev3.brickname", 0, TOK_METHOD, "METHOD ev3.brickname")
    # MODULEMETHOD / MODULEPROPERTY для пользовательского модуля.
    check_token(r, "mymod.foo(1)", 0, TOK_MODULEMETHOD, "MODULEMETHOD mymod.foo(")
    check_token(r, "mymod.bar", 0, TOK_MODULEPROPERTY, "MODULEPROPERTY mymod.bar")
    # KEYWORD (регистр не важен).
    check_token(r, "EndFor", 0, TOK_KEYWORD, "KEYWORD EndFor")
    check_token(r, "endfor", 0, TOK_KEYWORD, "KEYWORD endfor")
    check_token(r, "If x Then", 0, TOK_KEYWORD, "KEYWORD If")
    # LABEL / NUMBER / STRING.
    check_token(r, "loop:", 0, TOK_LABEL, "LABEL loop:")
    check_token(r, "2.5", 0, TOK_NUMBER, "NUMBER 2.5")
    check_token(r, "x = \"текст\"", 2, TOK_STRING, "STRING \"текст\"")
    check_token(r, "x = \"\"", 2, TOK_STRING, "STRING пустая строка")
    # NON для невалидного оператора.
    check_token(r, "x != y", 1, TOK_NON, "NON !=")
    # SUBNAME / FUNCNAME.
    check_token(r, "Sub Foo", 1, TOK_SUBNAME, "SUBNAME Sub Foo")
    check_token(r, "MySub()", 0, TOK_SUBNAME, "SUBNAME вызов")
    check_token(r, "Function map_data(in number n, out number data)", 1, TOK_FUNCNAME, "FUNCNAME")
    # Ключевые слова типов — KEYWORD, а не VARIABLE.
    check_token(r, "number[]", 0, TOK_KEYWORD, "KEYWORD number[]")
    check_token(r, "#main x", 0, TOK_PREPROCESSOR, "PREPROCESSOR #")
    # BRACKET* / COMMA.
    check_token(r, "mymod.foo(1)", 1, TOK_BRACKETLEFT, "BRACKETLEFT")
    check_token(r, "LCD.Text(1, 0)", 2, TOK_NUMBER, "NUMBER в аргументах")
    check_token(r, "LCD.Text(1, 0)", 3, TOK_COMMA, "COMMA")


def test_thread_run_quirk(mut r: Reporter) raises:
    """§11.10: SUBNAME только при i1 < i2 < i3 (позиции в исходной строке)."""
    # i1 < i2 < i3 -> слово после '=' получает SUBNAME.
    check_token(r, "thread.run = mySub", 2, TOK_SUBNAME, "thread.run SUBNAME")
    check_token(r, "thread.run = mySub", 0, TOK_METHOD, "thread.run -> METHOD")
    check_token(r, "thread.run=Sub1", 2, TOK_SUBNAME, "thread.run без пробелов")
    # Строка содержит thread.run, но эвристика не срабатывает: C# уходит в NON
    # (ветка thread.run — `else if`, она НЕ проваливается в goto/VARIABLE).
    check_token(r, "a  thread.run", 0, TOK_NON, "thread.run: слово до -> NON")


# ---------------------------------------------------------------------------
# §5. Тип строки
# ---------------------------------------------------------------------------


def test_line_types(mut r: Reporter) raises:
    check_line(r, "x = 1", "X|=|1", "2|3|5", LT_VARINIT, "VARINIT")
    check_line(r, "x++", "X|++", "2|12", LT_VARDOUBLEMATH, "VARDOUBLEMATH")
    check_line(r, "x--", "X|--", "2|12", LT_VARDOUBLEMATH, "VARDOUBLEMATH --")
    check_line(r, "x += 2", "X|+=|2", "2|13|5", LT_VAREQUMATH, "VAREQUMATH")
    check_line(r, "a[1] = 2", "A|[|1|]|=|2", "2|17|5|18|3|5", LT_VARARRAYINIT, "VARARRAYINIT")
    check_line(r, "Sub Foo", "Sub|FOO", "6|4", LT_SUBINIT, "SUBINIT")
    check_line(r, "Foo()", "FOO|()", "4|19", LT_SUBCALL, "SUBCALL")
    check_line(r, "If x > 1 Then", "If|X|>|1|Then", "6|2|14|5|6", LT_IFINIT, "IFINIT")
    check_line(r, "While \"True\"", "While|\"True\"", "6|1", LT_WHILEINIT, "WHILEINIT")
    check_line(r, "For i=0 to 3", "For|I|=|0|to|3", "6|2|3|5|6|5", LT_FORINIT, "FORINIT")
    check_line(r, "goto end", "goto|END", "6|8", LT_LABELCALL, "LABELCALL")
    check_line(r, "loop:", "LOOP:", "7", LT_LABELINIT, "LABELINIT")
    check_line(r, "folder \"prjs\" \"test123\"", "folder|\"prjs\"|\"test123\"", "6|1|1", LT_FOLDER, "FOLDER")
    check_line(r, "include \"x\"", "include|\"x\"", "6|1", LT_INCLUDE, "INCLUDE")
    check_line(r, "import \"x\"", "import|\"x\"", "6|1", LT_IMPORT, "IMPORT")
    check_line(r, "", "", "", LT_EMPTY, "EMPTY")
    check_line(r, "   ", "", "", LT_EMPTY, "EMPTY пробелы")
    check_line(r, "lcd.clear()", "lcd.clear|()", "0|19", LT_METHODCALL, "METHODCALL")
    check_line(r, "echo foo", "ECHO|FOO", "2|2", LT_NON, "NON")
    # Прочие типы из §5.
    check_line(r, "Function Foo", "Function|FOO", "6|22", LT_FUNCINIT, "FUNCINIT")
    check_line(r, "ElseIf x Then", "ElseIf|X|Then", "6|2|6", LT_ELSEIFINIT, "ELSEIFINIT")
    check_line(r, "EndIf", "EndIf", "6", LT_ONEKEYWORD, "ONEKEYWORD")
    check_line(r, "Break", "Break", "6", LT_ONEKEYWORD, "ONEKEYWORD break")
    check_line(r, "Return", "Return", "6", LT_ONEKEYWORD, "ONEKEYWORD return")
    check_line(r, "number x", "number|X", "6|2", LT_NUMBERINIT, "NUMBERINIT")
    check_line(r, "string s", "string|S", "6|2", LT_STRINGINIT, "STRINGINIT")
    check_line(r, "mymod.foo(1)", "mymod.foo|(|1|)", "10|15|5|16", LT_MODULEMETHODCALL, "MODULEMETHODCALL")
    check_line(r, "mymod.bar", "mymod.bar", "11", LT_MODULEPROPERTY, "MODULEPROPERTY")
    # '#' -> EMPTY (препроцессорные директивы игнорируются на стадиях 1-2).
    check_line(r, "#main ../Program1", "#|MAIN|..|/|PROGRAM1", "23|2|5|9|2", LT_EMPTY, "# -> EMPTY")
    # VARIABLE + что-то кроме = / += / ++ / [ -> NON (§5, квирк §11.5).
    check_line(r, "x [0] += 1", "X|[|0|]|+=|1", "2|17|5|18|13|5", LT_VARARRAYINIT, "x [0] += 1")
    check_line(r, "x[1]++", "X|[|1|]|++", "2|17|5|18|12", LT_VARARRAYINIT, "x[1]++")


# ---------------------------------------------------------------------------
# Прочее: OriginText, Number, канонизация, идемпотентность
# ---------------------------------------------------------------------------


def test_metadata(mut r: Reporter) raises:
    # Word.Number 1-based; OriginText сохраняет регистр, Text — канонический.
    var ln = build_line("WriteToScreen(1, 0)", 7)
    if ln.line_number != 7:
        r.fail("line_number сохраняется")
    if len(ln.words) != 6:
        r.fail("WriteToScreen: ожидалось 6 слов, получено " + String(len(ln.words)))
    check_origin(r, "WriteToScreen(1, 0)", 0, "WriteToScreen", "OriginText SUBNAME")
    var txt = _word_texts(ln)
    if txt[0] != "WRITETOSCREEN":
        r.fail("Text SUBNAME должен быть в UPPER: " + txt[0])

    # canonical_text == string.Join(" ", тексты слов)
    check_canon(r, "Program.Delay(5000)", "Program.Delay ( 5000 )", "canonical Delay")
    check_canon(r, "x = 1 'c", "X = 1", "canonical с комментарием")


def test_corpus_smoke(mut r: Reporter) raises:
    """Несколько реальных строк из tests/corpus (сверены с C#-оракулом)."""
    check_line(r, 
        "Function WriteToScreen (in number fontColor, in number X, in number Y)",
        "Function|WRITETOSCREEN|(|in|number|FONTCOLOR|,|in|number|X|,|in|number|Y|)",
        "6|22|15|6|6|2|21|6|6|2|21|6|6|2|16",
        LT_FUNCINIT,
        "corpus Function",
    )
    check_line(r, 
        "LCD.Text(1, 0, 0, 2, \"HELLO\")",
        "LCD.Text|(|1|,|0|,|0|,|2|,|\"HELLO\"|)",
        "0|15|5|21|5|21|5|21|5|21|1|16",
        LT_METHODCALL,
        "corpus LCD.Text",
    )
    check_line(r, 
        "For i = 0 To 10 Step 1",
        "For|I|=|0|To|10|Step|1",
        "6|2|3|5|6|5|6|5",
        LT_FORINIT,
        "corpus For",
    )
    check_line(r, "EndFunction", "EndFunction", "6", LT_ONEKEYWORD, "corpus EndFunction")


def main() raises:
    var r = Reporter()

    test_split_basic(r)
    test_comments(r)
    test_glue_and_specials(r)
    test_quirk_vs_docstring(r)
    test_classify_tokens(r)
    test_thread_run_quirk(r)
    test_line_types(r)
    test_metadata(r)
    test_corpus_smoke(r)

    if r.count() > 0:
        print("LEXER TESTS FAILED: " + String(r.count()) + " ошибок")
        var n = r.count()
        if n > FAILS_LIMIT:
            n = FAILS_LIMIT
        for i in range(n):
            print("  - " + r.fails[i])
        if r.count() > FAILS_LIMIT:
            print("  ... и ещё " + String(r.count() - FAILS_LIMIT))
        raise Error("LEXER TESTS FAILED")

    print("LEXER TESTS OK")