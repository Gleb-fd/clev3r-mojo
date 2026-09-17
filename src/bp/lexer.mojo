"""Лексер стадий 1-2 языка Basic Plus (порт компилятора Clev3r с C# на Mojo).

Источники (не менять):
  Interpreter/Utils/LineBuilder.cs  — GetWords (11-292), GetType (295-424)
  Interpreter/Utils/TokenBuilder.cs — GetToken (17-265), SetClassName (267-300)
  Interpreter/Enums/Tokens.cs, Interpreter/Enums/LineType.cs
  Interpreter/DataTemplates/Word.cs, Interpreter/DataTemplates/Line.cs

Поведение воспроизводится ПОСТРОЧНО, включая квирки (docs/01-lexer-and-grammar.md §3-§5, §11):
  * комментарий ('...') режется ДО разбора строковых литералов -> `"it's"` обрезается;
  * разделитель слов — ровно один пробел; таб НЕ разделитель (остаётся внутри слова),
    но Trim() по краям слова таб всё же убирает;
  * слово, содержащее кавычку, не режется по спецсимволам вовсе;
  * в словах `number[`/`string[` символ `[` и парный `]` не режутся (bool[ НЕ поддержан);
  * `--` склеивается только когда пара минусов — последние слова строки;
  * `+ +` склеивается всегда, поэтому `1 + +2` даёт `++` (DOUBLEMATH);
  * `@` склеивается со следующим словом (`@ d1` -> `@d1`);
  * имена (VARIABLE/SUBNAME/FUNCNAME/LABELNAME/LABEL) в Word.Text -> ВЕРХНИЙ регистр;
    Word.OriginText хранит исходное написание;
  * Word.Number — 1-based номер слова в строке.
"""

from std.collections import Dict


# ============================================================================
# Tokens — Interpreter/Enums/Tokens.cs:3-29 (значение = порядковый индекс)
# ============================================================================

comptime TOK_METHOD = 0
comptime TOK_STRING = 1
comptime TOK_VARIABLE = 2
comptime TOK_EQU = 3
comptime TOK_SUBNAME = 4
comptime TOK_NUMBER = 5
comptime TOK_KEYWORD = 6
comptime TOK_LABEL = 7
comptime TOK_LABELNAME = 8
comptime TOK_MATHOPERATOR = 9
comptime TOK_MODULEMETHOD = 10
comptime TOK_MODULEPROPERTY = 11
comptime TOK_DOUBLEMATH = 12
comptime TOK_EQUMATH = 13
comptime TOK_BOOLOPERATOR = 14
comptime TOK_BRACKETLEFT = 15
comptime TOK_BRACKETRIGHT = 16
comptime TOK_BRACKETLEFTARRAY = 17
comptime TOK_BRACKETRIGHTARRAY = 18
comptime TOK_DOUBLEBRACKET = 19
comptime TOK_DOUBLEBRACKETARRAY = 20
comptime TOK_COMMA = 21
comptime TOK_FUNCNAME = 22
comptime TOK_PREPROCESSOR = 23
comptime TOK_NON = 24


# ============================================================================
# LineType — Interpreter/Enums/LineType.cs:7-38
# ============================================================================

comptime LT_VARINIT = 0
comptime LT_VARDOUBLEMATH = 1
comptime LT_VAREQUMATH = 2
comptime LT_VARARRAYINIT = 3
comptime LT_SUBINIT = 4
comptime LT_SUBCALL = 5
comptime LT_FUNCINIT = 6
comptime LT_FUNCCALL = 7
comptime LT_METHODCALL = 8
comptime LT_MODULEMETHODCALL = 9
comptime LT_MODULEPROPERTY = 10
comptime LT_ONEKEYWORD = 11
comptime LT_LABELINIT = 12
comptime LT_LABELCALL = 13
comptime LT_FORINIT = 14
comptime LT_IFINIT = 15
comptime LT_ELSEIFINIT = 16
comptime LT_WHILEINIT = 17
comptime LT_INCLUDE = 18
comptime LT_FOLDER = 19
comptime LT_IMPORT = 20
comptime LT_EMPTY = 21
comptime LT_NUMBERINIT = 22
comptime LT_NUMBERARRAYINIT = 23
comptime LT_STRINGINIT = 24
comptime LT_STRINGARRAYINIT = 25
comptime LT_OLDFUNC = 26
comptime LT_PREPROCESSOR = 27
comptime LT_NON = 28


# ============================================================================
# Структуры данных — Interpreter/DataTemplates/Word.cs, Line.cs
# ============================================================================

@fieldwise_init
struct Word(Copyable, Movable):
    """Слово строки.

    text        — канонический текст (имена — в ВЕРХНЕМ регистре)
    origin_text — исходный текст слова
    token       — TOK_*
    number      — 1-based номер слова в строке
    """

    var text: String
    var origin_text: String
    var token: Int
    var number: Int


@fieldwise_init
struct Line(Copyable, Movable):
    """Разобранная строка.

    words       — слова с проставленными 1-based номерами
    line_type   — LT_*
    line_number — 1-based номер строки в исходном файле
    """

    var words: List[Word]
    var line_type: Int
    var line_number: Int


# ============================================================================
# Таблицы — TokenBuilder.cs:51 (32 ключевых слова), :267-300 (31 класс)
# ============================================================================

comptime KEYWORDS = (
    " for endfor if then endif else elseif while endwhile and or sub endsub goto step to "
    "import include folder in out function endfunction number number[] string string[] "
    "private region endregion break continue return "
)

comptime CLASS_NAMES = (
    " assert buttons byte ev3 ev3file lcd mailbox math motor motora motorab motorac motorad "
    "motorb motorbc motorbd motorc motorcd motord program row sensor sensor1 sensor2 sensor3 "
    "sensor4 speaker text thread time vector "
)


# ============================================================================
# Посимвольные предикаты (эмуляция Regex из TokenBuilder.cs)
# ============================================================================


def _byte_at(s: String, i: Int) -> UInt8:
    """Байт строки по индексу (UTF-8), без проверки границ кодпоинтов.

    C# индексирует строку по UTF-16-символам; для ASCII-синтаксиса Basic Plus
    побайтовый доступ эквивалентен. Mojo `s[byte=i]` возвращает StringSlice и
    падает на середине многобайтового кодпоинта (например, внутри "текст"),
    поэтому читаем сырые байты.
    """
    return s.unsafe_ptr().unsafe_offset(i)[]


def _byte_to_string(b: UInt8) -> String:
    """Один байт как строка (ASCII); байты >= 0x80 собираются в буфер."""
    if Int(b) < 128:
        return String(chr(Int(b)))
    var raw: List[UInt8] = [b]
    return _bytes_to_string(raw^)


def _bytes_to_string(raw: List[UInt8]) -> String:
    """Собрать строку из сырых UTF-8 байтов (корректно для многобайтовых)."""
    if len(raw) == 0:
        return String("")
    var span = Span(unsafe_ptr=raw.unsafe_ptr(), length=len(raw))
    return String(StringSlice(unsafe_from_utf8=span))


def _sub_bytes(s: String, start: Int, end: Int) -> String:
    """C# s.Substring(start, end-start) — срез ПО БАЙТАМ.

    Mojo-срез String работает по кодпоинтам и падает на середине UTF-8,
    поэтому собираем результат из отдельных байтов.
    """
    var raw = List[UInt8]()
    for i in range(start, end):
        raw.append(_byte_at(s, i))
    return _bytes_to_string(raw^)


def _is_lower(c: UInt8) -> Bool:
    return 97 <= Int(c) <= 122


def _is_upper(c: UInt8) -> Bool:
    return 65 <= Int(c) <= 90


def _is_digit(c: UInt8) -> Bool:
    return 48 <= Int(c) <= 57


def _is_alnum_us(c: UInt8) -> Bool:
    """Класс [0-9a-zA-Z_] — Regex в TokenBuilder.cs:74/105/144/235."""
    return _is_lower(c) or _is_upper(c) or _is_digit(c) or Int(c) == 95


def _is_alnum(c: UInt8) -> Bool:
    """Класс [0-9a-zA-Z] (без подчёркивания)."""
    return _is_lower(c) or _is_upper(c) or _is_digit(c)


def _is_digit_or_dot(c: UInt8) -> Bool:
    """Класс [0-9.] — Regex в TokenBuilder.cs:29."""
    return _is_digit(c) or Int(c) == 46


def _is_special(c: UInt8) -> Bool:
    """LineBuilder.cs:108 — множество символов-разделителей."""
    return (
        Int(c) == 43  # +
        or Int(c) == 45  # -
        or Int(c) == 47  # /
        or Int(c) == 42  # *
        or Int(c) == 40  # (
        or Int(c) == 41  # )
        or Int(c) == 123  # {
        or Int(c) == 125  # }
        or Int(c) == 44  # ,
        or Int(c) == 61  # =
        or Int(c) == 60  # <
        or Int(c) == 62  # >
        or Int(c) == 33  # !
        or Int(c) == 124  # |
        or Int(c) == 38  # &
        or Int(c) == 91  # [
        or Int(c) == 93  # ]
        or Int(c) == 35  # #
        or Int(c) == 59  # ;
        or Int(c) == 37  # %
        or Int(c) == 94  # ^
        or Int(c) == 64  # @
    )


def _all_match(w: String, kind: Int) -> Bool:
    """Regex.Matches(word, K).Count == word.Length.

    kind: 0 = [0-9a-zA-Z_], 1 = [0-9a-zA-Z], 2 = [0-9.], 3 = [0-9].

    Важно: для ПУСТОГО слова Regex даёт 0 совпадений и Length == 0, то есть
    условие ИСТИННО. Пустое слово реально возникает после Trim() слова из
    табов (строка "%\\t>=" даёт слова ["%", "", ">="]).
    """
    var n = w.byte_length()
    for i in range(n):
        var c = _byte_at(w, i)
        if kind == 0:
            if not _is_alnum_us(c):
                return False
        elif kind == 1:
            if not _is_alnum(c):
                return False
        elif kind == 2:
            if not _is_digit_or_dot(c):
                return False
        else:
            if not _is_digit(c):
                return False
    return True


def _is_identifier(w: String) -> Bool:
    return _all_match(w, 0)


def _is_identifier_no_us(w: String) -> Bool:
    return _all_match(w, 1)


def _is_number_like(w: String) -> Bool:
    return _all_match(w, 2)


def _is_digits_only(w: String) -> Bool:
    return _all_match(w, 3)


def _has_digit(w: String) -> Bool:
    """word.IndexOfAny('0'..'9') != -1"""
    for i in range(w.byte_length()):
        if _is_digit(_byte_at(w, i)):
            return True
    return False


def _has_any(w: String, chars: String) -> Bool:
    """word.IndexOfAny(chars) != -1"""
    for i in range(w.byte_length()):
        var c = _byte_at(w, i)
        for k in range(chars.byte_length()):
            if Int(c) == Int(_byte_at(chars, k)):
                return True
    return False


def _is_keyword_word(w: String) -> Bool:
    """TokenBuilder.cs:51 — сравнение ToLower() со списком ключевых слов."""
    return (" " + w.lower() + " ") in KEYWORDS


def _is_class_name(w: String) -> Bool:
    """TokenBuilder.cs:34 — _className.Contains(firstWord.ToLower())."""
    return (" " + w.lower() + " ") in CLASS_NAMES


# ============================================================================
# classify_word — порт TokenBuilder.GetToken (TokenBuilder.cs:17-265)
# ============================================================================


def _is_letter(c: UInt8) -> Bool:
    """C# (word[0] >= 'A' && <= 'Z') || (>= 'a' && <= 'z') — TokenBuilder.cs:115."""
    return _is_upper(c) or _is_lower(c)


def _starts_with_word_space(line: String, word_lower: String, index: Int) -> Bool:
    """Условие "строка начинается с '<word> '" из TokenBuilder.cs:55 и :86.

    C#: line.ToLower().IndexOf(word) != -1 && line.Length > index
        && line[0..index-1].ToLower() == word && line[index] == ' '
    """
    var ll = line.lower()
    if ll.find(word_lower) == -1:
        return False
    if line.byte_length() <= index:
        return False
    for i in range(word_lower.byte_length()):
        if _byte_at(ll, i) != _byte_at(word_lower, i):
            return False
    return Int(_byte_at(line, index)) == 32


def _thread_run_present(line: String) -> Bool:
    """line.ToLower().IndexOf("thread.run") != -1 — выбор ветки thread.run.

    Важно: в C# это `else if`, поэтому при попадании в ветку и неудаче
    эвристики управление уходит в общий `return Tokens.NON`, а НЕ в
    последующие проверки goto/VARIABLE.
    """
    return line.lower().find("thread.run") != -1


def _thread_run_hit(line: String, word: String) -> Bool:
    """Эвристика `thread.run = ИМЯ` (TokenBuilder.cs:153-163 и :243-252).

    i1 — позиция "thread.run" в НИЖНЕМ регистре строки, i2 — позиция "=",
    i3 — позиция слова в СЫРОЙ строке. SUBNAME только если i1 < i2 < i3.
    """
    var ll = line.lower()
    var i1 = ll.find("thread.run")
    if i1 == -1:
        return False
    var i2 = ll.find("=")
    if i2 == -1:
        return False
    var i3 = line.find(word)
    return i1 < i2 and i2 < i3


def classify_word(
    word: String, prev_word: String, foll_word: String, line: String
) -> Int:
    """Классифицировать слово. Порядок проверок — строго как в таблице §4.

    Все сравнения слов — через ToLower().
    """
    # --- 1. Строковый литерал: >=2 кавычек, последняя позже первой ----------
    var q1 = word.find('"')
    if q1 != -1 and word.rfind('"') != -1 and word.rfind('"') > q1:
        return TOK_STRING

    # --- 2. Препроцессор: ровно "#" ----------------------------------------
    if word.lower() == "#":
        return TOK_PREPROCESSOR

    # --- 3. Слово содержит "." ---------------------------------------------
    if word.find(".") != -1:
        if _is_number_like(word):
            return TOK_NUMBER
        var dot = word.find(".")
        var first_word = _sub_bytes(word, 0, dot)
        if _is_class_name(first_word):
            return TOK_METHOD
        if foll_word == "(" or foll_word == "()":
            return TOK_MODULEMETHOD
        return TOK_MODULEPROPERTY

    # --- 4. Ключевое слово --------------------------------------------------
    if _is_keyword_word(word):
        return TOK_KEYWORD

    # --- 5. Строка начинается с "sub " (проверка по СЫРОЙ строке) ----------
    if _starts_with_word_space(line, "sub", 3):
        if word.lower() == "sub" or word.lower() == "endsub":
            return TOK_KEYWORD
        if word.lower() == "(":
            return TOK_BRACKETLEFT
        if word.lower() == ")":
            return TOK_BRACKETRIGHT
        if word.lower() == "()":
            return TOK_DOUBLEBRACKET
        if _is_identifier(word):
            if prev_word.lower() == "sub":
                return TOK_SUBNAME
        elif word.strip() == ",":
            return TOK_COMMA
        return TOK_NON

    # --- 6. Строка начинается с "function " --------------------------------
    if _starts_with_word_space(line, "function", 8):
        if word.lower() == "function" or word.lower() == "endfunction":
            return TOK_KEYWORD
        if word.lower() == "(":
            return TOK_BRACKETLEFT
        if word.lower() == ")":
            return TOK_BRACKETRIGHT
        if word.lower() == "()":
            return TOK_DOUBLEBRACKET
        if _is_identifier(word):
            if prev_word.lower() == "function":
                return TOK_FUNCNAME
            var pw = prev_word.lower()
            if (
                _is_letter(_byte_at(word, 0))
                and (
                    pw == "number"
                    or pw == "number[]"
                    or pw == "string"
                    or pw == "string[]"
                )
            ):
                return TOK_VARIABLE
        elif word.strip() == ",":
            return TOK_COMMA
        return TOK_NON

    # --- 7. Слово содержит ":" -> метка ------------------------------------
    if word.find(":") != -1:
        return TOK_LABEL

    # --- 8. Слово содержит цифру -------------------------------------------
    if _has_digit(word):
        if _is_digits_only(word):
            return TOK_NUMBER
        if word.byte_length() > 1 and Int(_byte_at(word, 0)) == 64:
            return TOK_VARIABLE
        if _is_identifier(word):
            if foll_word != "" and foll_word.find("(") != -1:
                return TOK_SUBNAME
            # C#: else-if-цепочка. Ветка thread.run, не вернув SUBNAME,
            # проваливается в общий return NON — до goto/VARIABLE дело не доходит.
            if _thread_run_present(line):
                if _thread_run_hit(line, word):
                    return TOK_SUBNAME
                return TOK_NON
            if prev_word.lower() == "goto":
                return TOK_LABELNAME
            return TOK_VARIABLE
        return TOK_NON

    # --- 9. Математические операторы ---------------------------------------
    if _has_any(word, "+-*/"):
        if word == "++" or word == "--":
            return TOK_DOUBLEMATH
        if word == "+=" or word == "-=" or word == "*=" or word == "/=":
            return TOK_EQUMATH
        return TOK_MATHOPERATOR

    # --- 10. Операторы сравнения -------------------------------------------
    if word == "<>" or word == "<=" or word == ">=" or word == "<" or word == ">":
        return TOK_BOOLOPERATOR

    # --- 11. Скобки ---------------------------------------------------------
    if _has_any(word, "()[]"):
        if word == "()":
            return TOK_DOUBLEBRACKET
        if word == "[]":
            return TOK_DOUBLEBRACKETARRAY
        if word == "(":
            return TOK_BRACKETLEFT
        if word == ")":
            return TOK_BRACKETRIGHT
        if word == "[":
            return TOK_BRACKETLEFTARRAY
        if word == "]":
            return TOK_BRACKETRIGHTARRAY
        return TOK_NON

    # --- 12. Запятая --------------------------------------------------------
    if word.strip() == ",":
        return TOK_COMMA

    # --- 13. Присваивание ---------------------------------------------------
    if word == "=":
        return TOK_EQU

    # --- 14. `@`-глобал -----------------------------------------------------
    if word.byte_length() > 1 and Int(_byte_at(word, 0)) == 64:
        return TOK_VARIABLE

    # --- 15. Идентификатор --------------------------------------------------
    if _is_identifier(word):
        if foll_word != "" and foll_word.find("(") != -1:
            return TOK_SUBNAME
        # См. комментарий выше: ветка thread.run не проваливается в goto/VARIABLE.
        if _thread_run_present(line):
            if _thread_run_hit(line, word):
                return TOK_SUBNAME
            return TOK_NON
        if prev_word.lower() == "goto":
            return TOK_LABELNAME
        return TOK_VARIABLE

    # --- 16. Не классифицировано -------------------------------------------
    return TOK_NON


# ============================================================================
# get_words — порт LineBuilder.GetWords (LineBuilder.cs:11-292)
# ============================================================================


def get_words(raw_line: String) -> List[String]:
    """Шаги 1-4: обрезка комментария, разбиение с учётом кавычек,
    порезка спецсимволов, склейка пар.

    Возвращает список слов ПОСЛЕ Trim, но БЕЗ классификации и БЕЗ ToUpper.
    """
    # --- Шаг 1. Комментарий режется ДО разбора кавычек (строки 17-31) ------
    var line = String("")
    var comment = raw_line.find("'")
    if comment == -1:
        line = String(raw_line.strip())
    elif comment > 0:
        line = String(_sub_bytes(raw_line, 0, comment).strip())
    # comment == 0 -> line остаётся "" (строка целиком комментарий)

    # --- Шаг 2. Разбиение по пробелам с учётом кавычек (строки 35-93) ------
    var tmp_words = List[String]()
    if line.find('"') != -1:
        var list_tmp = List[String]()
        var stop = False
        var tmp_s = String("")
        for i in range(line.byte_length()):
            var ch = _byte_at(line, i)
            if not stop:
                if Int(ch) == 34:
                    stop = True
                    if tmp_s != "":
                        for w in tmp_s.split(" "):
                            if String(w) != "":
                                list_tmp.append(String(w))
                    tmp_s = String(chr(34))
                else:
                    tmp_s += _byte_to_string(ch)
            else:
                if Int(ch) == 34:
                    stop = False
                    tmp_s += _byte_to_string(ch)
                    list_tmp.append(tmp_s)
                    tmp_s = String("")
                else:
                    tmp_s += _byte_to_string(ch)
        if tmp_s != "":
            for w in tmp_s.split(" "):
                if String(w) != "":
                    list_tmp.append(String(w))
        tmp_words = list_tmp^
    else:
        for w in line.split(" "):
            if String(w) != "":
                tmp_words.append(String(w))

    # --- Шаг 3. Порезка спецсимволов (строки 97-140) ------------------------
    var tmp_list = List[String]()
    for i in range(len(tmp_words)):
        if tmp_words[i].find('"') != -1:
            # Слово с кавычкой не режется вовсе.
            tmp_list.append(tmp_words[i])
            continue
        var tmp = String("")
        for j in range(tmp_words[i].byte_length()):
            var ch = _byte_at(tmp_words[i], j)
            if _is_special(ch):
                if tmp != "":
                    var low = tmp.lower()
                    if Int(ch) == 91 and (low == "string" or low == "number"):
                        tmp += _byte_to_string(ch)
                        continue
                    elif Int(ch) == 93 and (low == "string[" or low == "number["):
                        tmp += _byte_to_string(ch)
                        continue
                    else:
                        tmp_list.append(tmp)
                        tmp = String("")
                tmp_list.append(_byte_to_string(ch))
                continue
            else:
                tmp += _byte_to_string(ch)
        if tmp != "":
            tmp_list.append(tmp)

    # --- Шаг 4. Склейка пар (строки 142-235) -------------------------------
    var words = List[String]()
    var j = 0
    while j < len(tmp_list):
        if j < len(tmp_list) - 1:
            var a = tmp_list[j]
            var b = tmp_list[j + 1]
            var merge = False
            if (
                a == "<"
                or a == ">"
                or a == "="
                or a == "!"
                or a == "+"
                or a == "-"
                or a == "/"
                or a == "*"
            ) and b == "=":
                merge = True
            if not merge and a == "&" and b == "&":
                merge = True
            if not merge and a == "|" and b == "|":
                merge = True
            if not merge and a == "(" and b == ")":
                merge = True
            if not merge and a == "{" and b == "}":
                merge = True
            if not merge and a == "[" and b == "]":
                merge = True
            if not merge and a == "+" and b == "+":
                merge = True
            if not merge and a == "-" and b == "-":
                # `--` склеивается ТОЛЬКО если пара — последние слова строки.
                if j + 2 == len(tmp_list):
                    merge = True
            if not merge and a == "<" and b == ">":
                merge = True
            if not merge and a == "@":
                merge = True
            if merge:
                words.append(a + b)
                j += 2
                continue
        words.append(tmp_list[j])
        j += 1

    # Trim каждого слова (строки 239-242).
    for i in range(len(words)):
        var t = String(words[i].strip())
        words[i] = t

    return words^


def canonical_text(words: List[String]) -> String:
    """string.Join(" ", words) — канонический текст строки (Line.NewLine)."""
    return String(" ").join(words)


# ============================================================================
# get_line_type — порт LineBuilder.GetType (LineBuilder.cs:295-424)
# ============================================================================


def get_line_type(words: List[String], tokens: List[Int]) -> Int:
    """Тип строки. Смотрит ТОЛЬКО на первое слово."""
    if len(words) == 0:
        return LT_EMPTY

    var token = tokens[0]
    var first = words[0].copy().lower()

    if token == TOK_KEYWORD:
        if first == "include":
            return LT_INCLUDE
        if first == "folder":
            return LT_FOLDER
        if first == "import":
            return LT_IMPORT
        if first == "sub":
            return LT_SUBINIT
        if first == "function":
            return LT_FUNCINIT
        if first == "for":
            return LT_FORINIT
        if first == "if":
            return LT_IFINIT
        if first == "elseif":
            return LT_ELSEIFINIT
        if first == "while":
            return LT_WHILEINIT
        if first == "goto":
            return LT_LABELCALL
        if first == "number":
            return LT_NUMBERINIT
        if first == "number[]":
            return LT_NUMBERARRAYINIT
        if first == "string":
            return LT_STRINGINIT
        if first == "string[]":
            return LT_STRINGARRAYINIT
        if (
            first == "endfor"
            or first == "endif"
            or first == "endwhile"
            or first == "endsub"
            or first == "endfunction"
            or first == "else"
            or first == "private"
            or first == "break"
            or first == "continue"
            or first == "return"
        ):
            return LT_ONEKEYWORD
        return LT_NON
    if token == TOK_LABEL:
        return LT_LABELINIT
    if token == TOK_METHOD:
        return LT_METHODCALL
    if token == TOK_SUBNAME:
        return LT_SUBCALL
    if token == TOK_FUNCNAME:
        return LT_FUNCCALL
    if token == TOK_MODULEMETHOD:
        return LT_MODULEMETHODCALL
    if token == TOK_MODULEPROPERTY:
        return LT_MODULEPROPERTY
    if token == TOK_VARIABLE:
        if len(words) > 1:
            var next_token = tokens[1]
            if next_token == TOK_EQU:
                return LT_VARINIT
            if next_token == TOK_EQUMATH:
                return LT_VAREQUMATH
            if next_token == TOK_DOUBLEMATH:
                return LT_VARDOUBLEMATH
            if next_token == TOK_BRACKETLEFTARRAY:
                return LT_VARARRAYINIT
    if token == TOK_PREPROCESSOR:
        return LT_EMPTY

    return LT_NON


# ============================================================================
# build_line — сборка Line (Line..ctor + GetWords + GetType)
# ============================================================================


def build_line(raw_line: String, line_number: Int) -> Line:
    """Полный конвейер стадий 1-2 для одной строки исходника."""
    var words = get_words(raw_line)
    var tokens = List[Int]()
    var result = List[Word]()

    for i in range(len(words)):
        var prev = String("")
        var foll = String("")
        if i > 0:
            prev = words[i - 1]
        if i < len(words) - 1:
            foll = words[i + 1]

        var token = classify_word(words[i], prev, foll, raw_line)
        tokens.append(token)

        # Имена -> ВЕРХНИЙ регистр (LineBuilder.cs:250-264).
        var text = words[i]
        if (
            token == TOK_VARIABLE
            or token == TOK_SUBNAME
            or token == TOK_FUNCNAME
            or token == TOK_LABELNAME
            or token == TOK_LABEL
        ):
            text = text.upper()

        result.append(Word(text, words[i], token, i + 1))

    return Line(result^, get_line_type(words, tokens), line_number)