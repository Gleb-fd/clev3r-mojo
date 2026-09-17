"""Стадия 3: компилятор развёрнутого исходника `~Name.bp` → листинг `.lmsb`.

Порт Interpreter/Compiler/{Compiler,Scanner,Expression,FunctionDefinition,
LibraryEntry}.cs (Clev3r / EV3-Basic). Вход — строки развёрнутого файла
(семантика StreamReader.ReadLine), выход — текст .lmsb с переводами строк
"\n" (как File.WriteAllLines на Linux).

Дерево выражений хранится ареной узлов (Compiler.enodes): рекурсивные
структуры с полями-списками в текущем Mojo запрещены, поэтому узлы ссылаются
на дочерние узлы по индексам.

Ссылки вида Compiler.cs:N — на Clev3r-1/Interpreter/Compiler/Compiler.cs.
"""

from std.collections import Dict

from bp.lexer import _byte_at, _bytes_to_string, _sub_bytes
from bp.compiler3_resources import (
    C_ASSERT,
    C_BUTTONS,
    C_BYTE,
    C_EV3,
    C_EV3FILE,
    C_LCD,
    C_MAILBOX,
    C_MATH,
    C_MOTOR,
    C_PROGRAM,
    C_ROW,
    C_RUNTIMELIBRARY,
    C_SENSOR,
    C_SENSOR1,
    C_SENSOR2,
    C_SENSOR3,
    C_SENSOR4,
    C_SPEAKER,
    C_TEXT,
    C_THREAD,
    C_TIME,
    C_VECTOR,
    C_MOTORA,
    C_MOTORB,
    C_MOTORC,
    C_MOTORD,
    C_MOTORAB,
    C_MOTORAC,
    C_MOTORAD,
    C_MOTORBC,
    C_MOTORBD,
    C_MOTORCD,
    C_NATIVECODE,
)

# ============================================================================
# Перечисления — Scanner.cs:26 (SymType), Expression.cs:25 (ExpressionType)
# ============================================================================

comptime SYM_ID = 0
comptime SYM_NUMBER = 1
comptime SYM_STRING = 2
comptime SYM_KEYWORD = 3
comptime SYM_SPECIAL = 4
comptime SYM_EOL = 5
comptime SYM_EOF = 6
comptime SYM_PRAGMA = 7

comptime ET_NUMBER = 0
comptime ET_TEXT = 1
comptime ET_NUMBER_ARRAY = 2
comptime ET_TEXT_ARRAY = 3
comptime ET_VOID = 4

# виды узлов Expression
comptime EK_NUMBER = 0  # NumberExpression
comptime EK_ATOMIC = 1  # AtomicExpression (переменная или 'строка')
comptime EK_CALL = 2  # CallExpression (в т.ч. inline-тело модуля)
comptime EK_COMPARISON = 3  # ComparisonExpression
comptime EK_AND = 4
comptime EK_OR = 5
comptime EK_UNSAFE_ARRAY = 6  # UnsafeArrayGetExpression
comptime EK_FUNCTION = 7  # FunctionExpression (F.CALL)

# 17 ключевых слов стадии 3 (Scanner.cs:249-252)
comptime KEYWORDS3 = (
    " AND ELSE ELSEIF ENDFOR ENDIF ENDSUB ENDWHILE FOR GOTO IF OR STEP SUB "
    "THEN TO WHILE "
)


def sym_name(t: Int) -> String:
    """C# SymType.ToString()."""
    if t == SYM_ID:
        return "ID"
    if t == SYM_NUMBER:
        return "NUMBER"
    if t == SYM_STRING:
        return "STRING"
    if t == SYM_KEYWORD:
        return "KEYWORD"
    if t == SYM_SPECIAL:
        return "SPECIAL"
    if t == SYM_EOL:
        return "EOL"
    if t == SYM_EOF:
        return "EOF"
    return "PRAGMA"


def et_name(t: Int) -> String:
    """C# ExpressionType.ToString()."""
    if t == ET_NUMBER:
        return "Number"
    if t == ET_TEXT:
        return "Text"
    if t == ET_NUMBER_ARRAY:
        return "NumberArray"
    if t == ET_TEXT_ARRAY:
        return "TextArray"
    return "Void"


# ============================================================================
# Посимвольные помощники (байтовая работа со строками)
# ============================================================================


def _is_letter(c: UInt8) -> Bool:
    return (65 <= Int(c) <= 90) or (97 <= Int(c) <= 122)


def _is_digit(c: UInt8) -> Bool:
    return 48 <= Int(c) <= 57


def _is_id_start(c: UInt8) -> Bool:
    return _is_letter(c) or Int(c) == 95


def _is_id_char(c: UInt8) -> Bool:
    return _is_letter(c) or Int(c) == 95 or _is_digit(c)


def _byte_to_string(b: UInt8) -> String:
    if Int(b) < 128:
        return String(chr(Int(b)))
    var raw: List[UInt8] = [b]
    var span = Span(unsafe_ptr=raw.unsafe_ptr(), length=len(raw))
    return String(StringSlice(unsafe_from_utf8=span))


def to_upper_ascii(s: String) -> String:
    """ToUpperInvariant для ASCII-идентификаторов."""
    var out = String("")
    for i in range(s.byte_length()):
        var c = _byte_at(s, i)
        if 97 <= Int(c) <= 122:
            c = UInt8(Int(c) - 32)
        out = out + _byte_to_string(c)
    return out


# ----------------------------------------------------------------------------
# Форматирование double как .NET double.ToString(InvariantCulture)
# (shortest round-trip; fixed при -5 < X < 15, иначе "1E+15"/"1E-06")
# ----------------------------------------------------------------------------


def _parse_exp(s: String) -> Int:
    var sign = 1
    var start = 0
    if s.byte_length() > 0 and _byte_at(s, 0) == 43:  # '+'
        start = 1
    elif s.byte_length() > 0 and _byte_at(s, 0) == 45:  # '-'
        sign = -1
        start = 1
    var v = 0
    for i in range(start, s.byte_length()):
        v = v * 10 + (Int(_byte_at(s, i)) - 48)
    return sign * v


def _pad_exp(v: Int) -> String:
    var s = String(v)
    if v < 0:
        s = String(_sub_bytes(s, 1, s.byte_length()))
    if s.byte_length() < 2:
        s = "0" + s
    if v < 0:
        s = "-" + s
    return s


def fmt_double_dotnet(v: Float64) -> String:
    var s = String(v)
    var neg = False
    if s.startswith("-"):
        neg = True
        s = String(_sub_bytes(s, 1, s.byte_length()))
    var digits = String("")
    var x = 0
    var epos = s.find("e")
    if epos >= 0:
        var mant = String(_sub_bytes(s, 0, epos))
        x = _parse_exp(String(_sub_bytes(s, epos + 1, s.byte_length())))
        for i in range(mant.byte_length()):
            var ch = _byte_at(mant, i)
            if ch != 46:
                digits = digits + _byte_to_string(ch)
    else:
        var dot = s.find(".")
        if dot >= 0:
            var ip = String(_sub_bytes(s, 0, dot))
            var fp = String(_sub_bytes(s, dot + 1, s.byte_length()))
            var k = 0
            while k < ip.byte_length() and _byte_at(ip, k) == 48:
                k += 1
            digits = String(_sub_bytes(ip, k, ip.byte_length()))
            x = ip.byte_length() - 1 - k
            digits = digits + fp
        else:
            digits = s
            x = s.byte_length() - 1
    # ведущие нули
    var lead = 0
    while lead < digits.byte_length() and _byte_at(digits, lead) == 48:
        lead += 1
        x -= 1
    digits = String(_sub_bytes(digits, lead, digits.byte_length()))
    # хвостовые нули
    var tl = digits.byte_length()
    while tl > 0 and _byte_at(digits, tl - 1) == 48:
        tl -= 1
    digits = String(_sub_bytes(digits, 0, tl))
    if digits.byte_length() == 0:
        return "0"
    var out = String("")
    if neg:
        out = "-"
    if -5 < x < 15:
        if x >= 0:
            if digits.byte_length() > x + 1:
                out = (
                    out
                    + String(_sub_bytes(digits, 0, x + 1))
                    + "."
                    + String(_sub_bytes(digits, x + 1, digits.byte_length()))
                )
            else:
                out = out + digits
                for i in range(x + 1 - digits.byte_length()):
                    out = out + "0"
        else:
            out = out + "0."
            for i in range(-x - 1):
                out = out + "0"
            out = out + digits
    else:
        out = out + _byte_to_string(_byte_at(digits, 0))
        if digits.byte_length() > 1:
            out = out + "." + String(_sub_bytes(digits, 1, digits.byte_length()))
        if x >= 0:
            out = out + "E+" + _pad_exp(x)
        else:
            out = out + "E" + _pad_exp(x)
    return out


def fmt_number_literal(v: Float64) -> String:
    """NumberExpression.PreparedValue / FunctionDefinition.tostring(double[])."""
    var s = fmt_double_dotnet(v)
    if s.find(".") == -1:
        return s + ".0"
    return s


def escape_string_lit(v: String) -> String:
    """EscapeString (Compiler.cs:1701-1723): <32, >127, ', \\ → \\DDD.

    Обход по UTF-16-кодам C# (суррогатная пара — два кода > 255 → \\001\\001).
    """
    var bytes = List[UInt8]()
    for i in range(v.byte_length()):
        bytes.append(_byte_at(v, i))
    var out = String("")
    var i = 0
    var n = len(bytes)
    while i < n:
        var c = 0
        var b0 = Int(bytes[i])
        if b0 < 0x80:
            c = b0
            i += 1
        elif 0xC0 <= b0 < 0xE0 and i + 1 < n:
            c = ((b0 & 0x1F) << 6) | (Int(bytes[i + 1]) & 0x3F)
            i += 2
        elif 0xE0 <= b0 < 0xF0 and i + 2 < n:
            c = ((b0 & 0x0F) << 12) | ((Int(bytes[i + 1]) & 0x3F) << 6) | (
                Int(bytes[i + 2]) & 0x3F
            )
            i += 3
        elif 0xF0 <= b0 < 0xF8 and i + 3 < n:
            c = (
                ((b0 & 0x07) << 18)
                | ((Int(bytes[i + 1]) & 0x3F) << 12)
                | ((Int(bytes[i + 2]) & 0x3F) << 6)
                | (Int(bytes[i + 3]) & 0x3F)
            )
            i += 4
        else:
            c = b0
            i += 1
        if c > 0xFFFF:
            # обе UTF-16 единицы суррогатной пары > 255 → каждая даёт \001
            out = out + _escape_one(1)
            out = out + _escape_one(1)
            continue
        out = out + _escape_one(c)
    return out


def _escape_one(c_in: Int) -> String:
    var c = c_in
    if c <= 0 or c > 255:
        c = 1
    if c < 32 or c > 127 or c == 39 or c == 92:
        var d0 = c % 8
        var d1 = (c // 8) % 8
        var d2 = c // 64
        return "\\" + String(d2) + String(d1) + String(d0)
    return _byte_to_string(UInt8(c))


def split_readline(text: String) -> List[String]:
    """Разбиение текста на строки как StringReader.ReadLine (\\n, хвостовой \\r)."""
    var raw = text.split("\n")
    var out = List[String]()
    for i in range(len(raw)):
        var s = String(raw[i])
        if s.endswith("\r"):
            s = String(_sub_bytes(s, 0, s.byte_length() - 1))
        out.append(s)
    # хвостовой пустой элемент после завершающего \n не является строкой
    if len(out) > 0 and out[len(out) - 1].byte_length() == 0:
        _ = out.pop()
    return out^


def split_ws(s: String) -> List[String]:
    """Split по ' ' и '\\t' с удалением пустых (RemoveEmptyEntries)."""
    var out = List[String]()
    var cur = String("")
    for i in range(s.byte_length()):
        var c = _byte_at(s, i)
        if c == 32 or c == 9:
            if cur.byte_length() > 0:
                out.append(cur)
            cur = String("")
        else:
            cur = cur + _byte_to_string(c)
    if cur.byte_length() > 0:
        out.append(cur)
    return out^


# ============================================================================
# Буфер вывода
# ============================================================================


@fieldwise_init
struct Buf(Copyable, Movable):
    var parts: List[String]

    def __init__(out self):
        self.parts = List[String]()

    def w(mut self, s: String):
        self.parts.append(s)

    def wl(mut self, s: String):
        self.parts.append(s + "\n")

    def text(self) -> String:
        return String("").join(self.parts)


# ============================================================================
# Библиотека — LibraryEntry.cs
# ============================================================================


@fieldwise_init
struct LibEntry(Copyable, Movable):
    var inline: Bool
    var return_type: Int
    var param_types: List[Int]
    var refs: List[String]
    var program_code: String


def decode_type(c: UInt8) raises -> Int:
    if c == 70:  # F
        return ET_NUMBER
    if c == 83:  # S
        return ET_TEXT
    if c == 65:  # A
        return ET_NUMBER_ARRAY
    if c == 88:  # X
        return ET_TEXT_ARRAY
    if c == 86:  # V
        return ET_VOID
    raise Error("Can not read runtime library")


def make_lib_entry(inline: Bool, parts: List[String], code: String) raises -> LibEntry:
    var descriptor = parts[0]
    var rt = decode_type(_byte_at(descriptor, descriptor.byte_length() - 1))
    var param_types = List[Int]()
    for i in range(descriptor.byte_length() - 1):
        param_types.append(decode_type(_byte_at(descriptor, i)))
    var refs = List[String]()
    for i in range(1, len(parts)):
        refs.append(parts[i])
    var program_code = code
    if inline:
        var startbrace = code.find("{")
        var endbrace = code.find("}")
        program_code = String(String(_sub_bytes(code, startbrace + 1, endbrace - 1)).strip())
    return LibEntry(inline, rt, param_types^, refs^, program_code)^


# ============================================================================
# FunctionDefinition.cs
# ============================================================================


@fieldwise_init
struct DefaultVal(Copyable, Movable):
    var is_text: Bool
    var num: Float64
    var text: String


@fieldwise_init
struct FuncDef(Copyable, Movable):
    var fname: String
    var startsub: String
    var paramnames: List[String]
    var defaults: List[DefaultVal]
    var res_num: Int
    var max_num: Int
    var res_text: Int
    var max_text: Int
    var return_type: Int

    def find_parameter(self, name: String) -> Int:
        for i in range(len(self.paramnames)):
            if self.paramnames[i] == name:
                return i
        return -1

    def parameter_number(self) -> Int:
        return len(self.paramnames)

    def parameter_type(self, i: Int) -> Int:
        if self.defaults[i].is_text:
            return ET_TEXT
        return ET_NUMBER

    def parameter_default_literal(self, i: Int) -> String:
        if self.defaults[i].is_text:
            return "'" + self.defaults[i].text + "'"
        return fmt_number_literal(self.defaults[i].num)

    def parameter_variable(self, i: Int) -> String:
        if self.parameter_type(i) == ET_NUMBER:
            return "F" + self.fname + "." + self.paramnames[i]
        if self.parameter_type(i) == ET_TEXT:
            return "S" + self.fname + "." + self.paramnames[i]
        return ""

    def get_return_type(self) -> Int:
        return self.return_type

    def get_return_variable(self) -> String:
        if self.return_type == ET_NUMBER:
            return "F" + self.fname + "."
        if self.return_type == ET_TEXT:
            return "S" + self.fname + "."
        return ""

    def reserve_variable(mut self, t: Int) -> String:
        if t == ET_NUMBER:
            self.res_num += 1
            if self.res_num > self.max_num:
                self.max_num = self.res_num
            return "F" + self.fname + "." + String(self.res_num - 1)
        if t == ET_TEXT:
            self.res_text += 1
            if self.res_text > self.max_text:
                self.max_text = self.res_text
            return "S" + self.fname + "." + String(self.res_text - 1)
        return ""

    def release_variable(mut self, t: Int):
        if t == ET_NUMBER:
            self.res_num -= 1
        elif t == ET_TEXT:
            self.res_text -= 1

    def get_max_reserved(self, t: Int) -> Int:
        if t == ET_NUMBER:
            return self.max_num
        if t == ET_TEXT:
            return self.max_text
        return 0

    def get_all_local_variables(self, t: Int) -> List[String]:
        var prefix = String("S")
        if t == ET_NUMBER:
            prefix = String("F")
        prefix = prefix + self.fname + "."
        var l = List[String]()
        if self.return_type == t:
            l.append(prefix)
        for i in range(len(self.paramnames)):
            if self.parameter_type(i) == t:
                l.append(prefix + self.paramnames[i])
        for i in range(self.get_max_reserved(t)):
            l.append(prefix + String(i))
        return l^

    def get_current_local_variables(self, t: Int) -> List[String]:
        var prefix = String("S")
        if t == ET_NUMBER:
            prefix = String("F")
        prefix = prefix + self.fname + "."
        var l = List[String]()
        for i in range(len(self.paramnames)):
            if self.parameter_type(i) == t:
                l.append(prefix + self.paramnames[i])
        var res = 0
        if t == ET_NUMBER:
            res = self.res_num
        elif t == ET_TEXT:
            res = self.res_text
        for i in range(res):
            l.append(prefix + String(i))
        return l^


def split_ws_multi(s: String) -> List[String]:
    """Split по ' ', '\\t', ',' с удалением пустых (FunctionDefinition.make)."""
    var out = List[String]()
    var cur = String("")
    for i in range(s.byte_length()):
        var c = _byte_at(s, i)
        if c == 32 or c == 9 or c == 44:
            if cur.byte_length() > 0:
                out.append(cur)
            cur = String("")
        else:
            cur = cur + _byte_to_string(c)
    if cur.byte_length() > 0:
        out.append(cur)
    return out^


def funcdef_make(fname: String, startsub: String, pardeclarator: String) raises -> FuncDef:
    """FunctionDefinition.make: split по ' ', '\\t', ','."""
    var parlist = split_ws_multi(pardeclarator)
    var paramnames = List[String]()
    var defaults = List[DefaultVal]()
    for i in range(len(parlist)):
        var item = parlist[i]
        var colon = item.find(":")
        if colon > 0:
            var v = String(_sub_bytes(item, colon + 1, item.byte_length()))
            paramnames.append(to_upper_ascii(String(_sub_bytes(item, 0, colon))))
            var num = try_parse_float(v)
            if num.has:
                defaults.append(DefaultVal(False, num.value, ""))
            else:
                defaults.append(DefaultVal(True, 0.0, v))
        else:
            paramnames.append(to_upper_ascii(item))
            defaults.append(DefaultVal(False, 0.0, ""))
    return FuncDef(
        fname, startsub, paramnames^, defaults^, 0, 0, 0, 0, ET_VOID
    )^


# --- упрощённый double.TryParse для дескрипторов и числовых литералов ------


@fieldwise_init
struct OptFloat(Copyable, Movable):
    var has: Bool
    var value: Float64


def try_parse_float(s: String) raises -> OptFloat:
    """double.TryParse(NumberStyles.Float, InvariantCulture) для лексем
    сканера: [0-9.]* (возможен один '.', без знака и экспоненты)."""
    var dot_count = 0
    var digits = 0
    for i in range(s.byte_length()):
        var c = _byte_at(s, i)
        if _is_digit(c):
            digits += 1
        elif c == 46:
            dot_count += 1
            if dot_count > 1:
                return OptFloat(False, 0.0)
        else:
            return OptFloat(False, 0.0)
    if digits == 0:
        return OptFloat(False, 0.0)
    var norm = s
    if s.endswith("."):
        norm = String(_sub_bytes(s, 0, s.byte_length() - 1))
    if norm.find(".") == -1:
        norm = norm + ".0"
    return OptFloat(True, Float64(norm))


# ============================================================================
# Узлы дерева выражений (арена; Expression.cs)
# ============================================================================


@fieldwise_init
struct ExprNode(Copyable, Movable):
    var etype: Int
    var kind: Int
    var num: Float64
    var text: String
    var alt1: String
    var alt2: String
    var fd_idx: Int
    var children: List[Int]


# ============================================================================
# Scanner.cs
# ============================================================================


@fieldwise_init
struct Scanner(Copyable, Movable):
    var lines: List[String]
    var line_idx: Int
    var col: Int
    var next_type: Int
    var next_content: String
    var pb_type: List[Int]
    var pb_content: List[String]

    def __init__(out self, lines: List[String]):
        self.lines = lines.copy()
        self.line_idx = 0
        self.col = 0
        self.next_type = SYM_EOF
        self.next_content = ""
        self.pb_type = List[Int]()
        self.pb_content = List[String]()

    def start_from_begin(mut self):
        self.next_type = SYM_EOF
        self.next_content = ""
        self.line_idx = 0
        self.col = 0
        self.pb_type = List[Int]()
        self.pb_content = List[String]()

    def next_is_keyword(self, txt: String) -> Bool:
        return self.next_type == SYM_KEYWORD and self.next_content == txt

    def next_is_special(self, txt: String) -> Bool:
        return self.next_type == SYM_SPECIAL and self.next_content == txt

    def throw_parse_error(self, message: String) raises:
        raise Error(
            message
            + " at: "
            + String(self.line_idx + 1)
            + ":"
            + String(self.col + 1)
        )

    def throw_unexpected_symbol(self) raises:
        self.throw_parse_error(
            "Unexpected " + sym_name(self.next_type) + " " + self.next_content
        )

    def throw_expected_symbol(self, t: Int, content: String) raises:
        if content != "":
            self.throw_parse_error("Expected " + content)
        else:
            self.throw_parse_error("Expected " + sym_name(t))

    def get_sym(mut self) raises:
        if len(self.pb_type) > 0:
            self.next_type = self.pb_type.pop()
            self.next_content = self.pb_content.pop()
            return
        while True:
            if self.line_idx >= len(self.lines):
                self.next_type = SYM_EOF
                self.next_content = ""
                return
            var line = self.lines[self.line_idx]
            var llen = line.byte_length()
            if self.col >= llen:
                self.next_type = SYM_EOL
                self.next_content = ""
                self.line_idx += 1
                self.col = 0
                return
            if self.col == 0 and line.startswith("'PRAGMA "):
                self.next_type = SYM_PRAGMA
                self.next_content = String(String(_sub_bytes(line, 8, llen)).strip())
                self.line_idx += 1
                self.col = 0
                return
            var c = _byte_at(line, self.col)
            if c == 39:  # "'" — комментарий до конца строки
                self.col = llen
                continue
            if c == 32 or c == 9:
                self.col += 1
                continue
            if _is_digit(c):
                var start = self.col
                self.col += 1
                while self.col < llen:
                    var d = _byte_at(line, self.col)
                    if _is_digit(d) or d == 46:
                        self.col += 1
                    else:
                        break
                self.next_type = SYM_NUMBER
                self.next_content = String(_sub_bytes(line, start, self.col))
                return
            if c == 34:  # '"'
                var start = self.col
                self.col += 1
                while True:
                    if self.col >= llen:
                        raise Error(
                            "Nonterminated string at: "
                            + String(self.line_idx + 1)
                            + ":"
                            + String(self.col + 1)
                        )
                    if _byte_at(line, self.col) == 34:
                        self.col += 1
                        # дополнительная " продолжает строку
                        if self.col < llen and _byte_at(line, self.col) == 34:
                            self.col += 1
                        else:
                            break
                    self.col += 1
                self.next_type = SYM_STRING
                self.next_content = String(_sub_bytes(line, start + 1, self.col - 1))
                return
            if _is_id_start(c):
                var start = self.col
                self.col += 1
                while self.col < llen and _is_id_char(_byte_at(line, self.col)):
                    self.col += 1
                var w = to_upper_ascii(String(_sub_bytes(line, start, self.col)))
                self.next_type = SYM_ID
                self.next_content = w
                if (" " + w + " ") in KEYWORDS3:
                    self.next_type = SYM_KEYWORD
                return
            # спецсимвол (возможны двухсимвольные <=, >=, <>)
            self.next_type = SYM_SPECIAL
            self.next_content = _byte_to_string(c)
            self.col += 1
            var nc = self.next_content
            if nc == "<" and self.col < llen and _byte_at(line, self.col) == 61:
                self.next_content = "<="
                self.col += 1
            elif nc == ">" and self.col < llen and _byte_at(line, self.col) == 61:
                self.next_content = ">="
                self.col += 1
            elif nc == "<" and self.col < llen and _byte_at(line, self.col) == 62:
                self.next_content = "<>"
                self.col += 1
            return

    def push_back(mut self, prev_type: Int, prev_content: String):
        self.pb_type.append(self.next_type)
        self.pb_content.append(self.next_content)
        self.next_type = prev_type
        self.next_content = prev_content


# ============================================================================
# Compiler.cs
# ============================================================================


@fieldwise_init
struct Compiler:
    var library: Dict[String, Int]
    var lib_entries: List[LibEntry]
    var runtimeglobals: String
    var runtimeinit: String

    var s: Scanner

    var scs_keys: List[String]  # subcallstructure: sub → список вызываемых sub
    var scs_map: Dict[String, List[String]]
    var fcs_keys: List[String]  # functioncallstructure: sub → список функций
    var fcs_map: Dict[String, List[String]]
    var fos_map: Dict[String, Int]  # functionofsub: sub → индекс FuncDef
    var rts_map: Dict[String, Int]  # returntypeofsub: sub → ExpressionType

    var functiondefs: List[FuncDef]
    var fdef_index: Dict[String, Int]

    var currentsub: String
    var currentfunction: Int
    var labelcount: Int
    var vkeys: List[String]
    var vmap: Dict[String, Int]
    var vtypes: List[Int]
    var references: List[Int]
    var refset: Dict[Int, Bool]
    var threadnames: List[String]

    var noboundscheck: Bool
    var nodivisioncheck: Bool
    var has_any_recursion: Bool

    var enodes: List[ExprNode]  # арена выражений

    def __init__(out self) raises:
        self.library = Dict[String, Int]()
        self.lib_entries = List[LibEntry]()
        self.runtimeglobals = ""
        self.runtimeinit = ""
        self.s = Scanner(List[String]())
        self.scs_keys = List[String]()
        self.scs_map = Dict[String, List[String]]()
        self.fcs_keys = List[String]()
        self.fcs_map = Dict[String, List[String]]()
        self.fos_map = Dict[String, Int]()
        self.rts_map = Dict[String, Int]()
        self.functiondefs = List[FuncDef]()
        self.fdef_index = Dict[String, Int]()
        self.currentsub = ""
        self.currentfunction = 0
        self.labelcount = 0
        self.vkeys = List[String]()
        self.vmap = Dict[String, Int]()
        self.vtypes = List[Int]()
        self.references = List[Int]()
        self.refset = Dict[Int, Bool]()
        self.threadnames = List[String]()
        self.noboundscheck = False
        self.nodivisioncheck = False
        self.has_any_recursion = False
        self.enodes = List[ExprNode]()
        self.read_library()

    # --- арена выражений: конструкторы узлов --------------------------------

    def ex_number(mut self, v: Float64) -> Int:
        self.enodes.append(
            ExprNode(ET_NUMBER, EK_NUMBER, v, "", "", "", -1, List[Int]())
        )
        return len(self.enodes) - 1

    def ex_atomic(mut self, t: Int, v: String) -> Int:
        self.enodes.append(ExprNode(t, EK_ATOMIC, 0.0, v, "", "", -1, List[Int]()))
        return len(self.enodes) - 1

    def ex_call(mut self, t: Int, function: String, children: List[Int]) -> Int:
        self.enodes.append(
            ExprNode(t, EK_CALL, 0.0, function, "", "", -1, children.copy())
        )
        return len(self.enodes) - 1

    def ex_comparison(
        mut self, function: String, alt_true: String, alt_false: String, p1: Int, p2: Int
    ) -> Int:
        var children = List[Int]()
        children.append(p1)
        children.append(p2)
        self.enodes.append(
            ExprNode(
                ET_TEXT,
                EK_COMPARISON,
                0.0,
                function,
                alt_true,
                alt_false,
                -1,
                children^,
            )
        )
        return len(self.enodes) - 1

    def ex_and(mut self, p1: Int, p2: Int) -> Int:
        var children = List[Int]()
        children.append(p1)
        children.append(p2)
        self.enodes.append(
            ExprNode(ET_TEXT, EK_AND, 0.0, "CALL AND", "", "", -1, children^)
        )
        return len(self.enodes) - 1

    def ex_or(mut self, p1: Int, p2: Int) -> Int:
        var children = List[Int]()
        children.append(p1)
        children.append(p2)
        self.enodes.append(
            ExprNode(ET_TEXT, EK_OR, 0.0, "CALL OR", "", "", -1, children^)
        )
        return len(self.enodes) - 1

    def ex_unsafe_array(mut self, variablename: String, index: Int) -> Int:
        var children = List[Int]()
        children.append(index)
        self.enodes.append(
            ExprNode(
                ET_NUMBER, EK_UNSAFE_ARRAY, 0.0, variablename, "", "", -1, children^
            )
        )
        return len(self.enodes) - 1

    def ex_function(mut self, fd_idx: Int, return_type: Int, children: List[Int]) -> Int:
        self.enodes.append(
            ExprNode(return_type, EK_FUNCTION, 0.0, "", "", "", fd_idx, children.copy())
        )
        return len(self.enodes) - 1

    # доступ к узлам
    def etype_of(self, e: Int) -> Int:
        return self.enodes[e].etype

    def kind_of(self, e: Int) -> Int:
        return self.enodes[e].kind

    def num_of(self, e: Int) -> Float64:
        return self.enodes[e].num

    def text_of(self, e: Int) -> String:
        return self.enodes[e].text

    def child(self, e: Int, k: Int) -> Int:
        return self.enodes[e].children[k]

    # --- библиотека (Compiler.cs:73-168) ------------------------------------

    def read_library(mut self) raises:
        self.read_library_module(C_RUNTIMELIBRARY)
        self.read_library_module(C_ASSERT)
        self.read_library_module(C_BUTTONS)
        self.read_library_module(C_BYTE)
        self.read_library_module(C_EV3)
        self.read_library_module(C_EV3FILE)
        self.read_library_module(C_LCD)
        self.read_library_module(C_MAILBOX)
        self.read_library_module(C_MATH)
        self.read_library_module(C_MOTOR)
        self.read_library_module(C_PROGRAM)
        self.read_library_module(C_SENSOR)
        self.read_library_module(C_SPEAKER)
        self.read_library_module(C_TEXT)
        self.read_library_module(C_THREAD)
        self.read_library_module(C_VECTOR)
        self.read_library_module(C_SENSOR1)
        self.read_library_module(C_SENSOR2)
        self.read_library_module(C_SENSOR3)
        self.read_library_module(C_SENSOR4)
        self.read_library_module(C_MOTORA)
        self.read_library_module(C_MOTORB)
        self.read_library_module(C_MOTORC)
        self.read_library_module(C_MOTORD)
        self.read_library_module(C_MOTORAB)
        self.read_library_module(C_MOTORAC)
        self.read_library_module(C_MOTORAD)
        self.read_library_module(C_MOTORBC)
        self.read_library_module(C_MOTORBD)
        self.read_library_module(C_MOTORCD)
        self.read_library_module(C_ROW)
        self.read_library_module(C_TIME)

    def read_library_module(mut self, moduletext: String) raises:
        var lines = split_readline(moduletext)
        var has_first = False
        var first = String("")
        var body = List[String]()
        for i in range(len(lines)):
            var line = lines[i]
            if not has_first:
                if line.startswith("subcall") or line.startswith("inline") or line.startswith(
                    "init"
                ):
                    has_first = True
                    first = line
                    body = List[String]()
                    body.append(line)
                else:
                    var cidx = line.find("//")
                    if cidx >= 0:
                        line = String(_sub_bytes(line, 0, cidx))
                    if String(line.strip()).byte_length() > 0:
                        self.runtimeglobals = self.runtimeglobals + line + "\n"
            else:
                body.append(line)
                if line.startswith("}"):
                    if first.startswith("init"):
                        var bt = String("")
                        for j in range(1, len(body)):
                            bt = bt + body[j] + "\n"
                        var inner = bt.replace("{", " ").replace("}", " ")
                        self.runtimeinit = (
                            self.runtimeinit + "    " + String(inner.strip()) + "\n"
                        )
                    else:
                        var inline = first.startswith("inline")
                        var idx1 = 7
                        if inline:
                            idx1 = 6
                        var idx2 = first.find("//", idx1)
                        var functionname = String(
                            String(_sub_bytes(first, idx1, idx2)).strip()
                        )
                        var rest = String(
                            String(_sub_bytes(first, idx2 + 2, first.byte_length())).strip()
                        )
                        var parts = split_ws(rest)
                        var bt = String("")
                        for j in range(len(body)):
                            bt = bt + body[j] + "\n"
                        var le = make_lib_entry(inline, parts, bt)
                        self.lib_entries.append(le^)
                        self.library[to_upper_ascii(functionname)] = (
                            len(self.lib_entries) - 1
                        )
                    has_first = False

    def memorize_reference(mut self, name: String) raises:
        if name in self.library:
            var idx = self.library[name]
            var already = False
            for i in range(len(self.references)):
                if self.references[i] == idx:
                    already = True
                    break
            if not already:
                self.references.append(idx)
                self.refset[idx] = True
                var le = self.lib_entries[idx].copy()
                for i in range(len(le.refs)):
                    self.memorize_reference(le.refs[i])
        else:
            self.s.throw_parse_error("Reference to undefined function: " + name)

    # --- переменные/метки/временные (Compiler.cs:512-525) --------------------

    def reserve_variable(mut self, t: Int) -> String:
        var idx = self.currentfunction
        var fd = self.functiondefs[idx].copy()
        var name = fd.reserve_variable(t)
        self.functiondefs[idx] = fd^
        return name

    def release_variable(mut self, t: Int):
        var idx = self.currentfunction
        var fd = self.functiondefs[idx].copy()
        fd.release_variable(t)
        self.functiondefs[idx] = fd^

    def get_label_number(mut self) raises -> Int:
        self.labelcount += 1
        return self.labelcount - 1

    def define_variable(mut self, varname: String, t: Int) raises -> Bool:
        """Добавить переменную; False — уже есть с другим типом."""
        if varname in self.vmap:
            return self.vtypes[self.vmap[varname]] == t
        self.vkeys.append(varname)
        self.vtypes.append(t)
        self.vmap[varname] = len(self.vkeys) - 1
        return True

    def variable_type(self, varname: String) raises -> Int:
        return self.vtypes[self.vmap[varname]]

    def has_variable(self, varname: String) raises -> Bool:
        return varname in self.vmap

    # --- анализ рекурсии (Compiler.cs:2084-2125) -----------------------------

    def determine_direct_callees(self, fd_idx: Int) raises -> List[Int]:
        var callees = List[Int]()
        # обход по functionofsub (порядок не важен — результат булев)
        var keys = List[String]()
        for k in self.fos_map:
            keys.append(k)
        for i in range(len(keys)):
            var sub = keys[i]
            if self.fos_map[sub] == fd_idx and sub in self.fcs_map:
                var fns = self.fcs_map[sub].copy()
                for j in range(len(fns)):
                    var callee = fns[j]
                    if callee in self.fdef_index:
                        var c_idx = self.fdef_index[callee]
                        var seen = False
                        for k2 in range(len(callees)):
                            if callees[k2] == c_idx:
                                seen = True
                                break
                        if not seen:
                            callees.append(c_idx)
        return callees^^

    def function_could_call(self, f1: Int, f2: Int) raises -> Bool:
        var allcallees = self.determine_direct_callees(f1)
        var i = 0
        while i < len(allcallees):
            if allcallees[i] == f2:
                return True
            var sub = self.determine_direct_callees(allcallees[i])
            for j in range(len(sub)):
                var c_idx = sub[j]
                var seen = False
                for k in range(len(allcallees)):
                    if allcallees[k] == c_idx:
                        seen = True
                        break
                if not seen:
                    allcallees.append(c_idx)
            i += 1
        return False

    def set_all_functionofsub(mut self, fd_idx: Int, sub: String) raises:
        if sub in self.fos_map:
            if self.fos_map[sub] != fd_idx:
                self.s.throw_parse_error(
                    "Subroutine called from outside function context: " + sub
                )
        else:
            self.fos_map[sub] = fd_idx
            if sub in self.scs_map:
                var callees = self.scs_map[sub].copy()
                for i in range(len(callees)):
                    self.set_all_functionofsub(fd_idx, callees[i])

    # ======================= полный прогон (Compiler.cs:170-466) ============

    def compile_program(mut self, lines: List[String]) raises -> String:
        self.s = Scanner(lines)

        # ---- первый проход: поды и функции (Compiler.cs:176-230) ----
        self.s.get_sym()
        self.scs_keys.append("")
        var l0 = List[String]()
        l0.append("")
        self.scs_map[""] = l0^
        var fd0 = funcdef_make("", "", "")
        self.functiondefs.append(fd0^)
        self.fdef_index[""] = 0
        self.has_any_recursion = False

        while self.s.next_type != SYM_EOF:
            if self.s.next_is_keyword("SUB"):
                self.extractfinfo_sub()
            else:
                self.extractfinfo_statement("")

        for i in range(len(self.functiondefs)):
            var fd = self.functiondefs[i].copy()
            self.set_all_functionofsub(i, fd.startsub)
            if fd.startsub in self.rts_map:
                var fd2 = self.functiondefs[i].copy()
                fd2.return_type = self.rts_map[fd2.startsub]
                self.functiondefs[i] = fd2^
        for i in range(len(self.scs_keys)):
            var subname = self.scs_keys[i]
            if not (subname in self.fos_map):
                self.set_all_functionofsub(0, subname)
        for i in range(len(self.functiondefs)):
            self.has_any_recursion = self.has_any_recursion or self.function_could_call(
                i, i
            )

        # ---- второй проход (Compiler.cs:259-299) ----
        self.s.start_from_begin()
        self.s.get_sym()

        self.currentfunction = 0
        self.currentsub = ""
        self.labelcount = 0
        self.vkeys = List[String]()
        self.vmap = Dict[String, Int]()
        self.vtypes = List[Int]()
        self.references = List[Int]()
        self.refset = Dict[Int, Bool]()
        self.threadnames = List[String]()
        self.noboundscheck = False
        self.nodivisioncheck = False

        var mainprogram = Buf()
        var subroutines = Buf()

        while self.s.next_type != SYM_EOF:
            if self.s.next_is_keyword("SUB"):
                self.compile_sub(subroutines)
            else:
                self.compile_statement(mainprogram)

        return self.assemble(mainprogram, subroutines)

    # --- сборка выходного файла (Compiler.cs:302-465) -----------------------

    def assemble(mut self, mainprogram: Buf, subroutines: Buf) raises -> String:
        var b = Buf()
        b.w(self.runtimeglobals)

        var initlist = Buf()
        for i in range(len(self.vkeys)):
            var vname = self.vkeys[i]
            var t = self.vtypes[i]
            if t == ET_NUMBER:
                b.wl("DATAF " + vname)
                initlist.wl("    MOVEF_F 0.0 " + vname)
            elif t == ET_TEXT:
                b.wl("DATAS " + vname + " 252")
                initlist.wl("    STRINGS DUPLICATE '' " + vname)
            elif t == ET_NUMBER_ARRAY:
                b.wl("ARRAY16 " + vname + " 2")
                initlist.wl("    CALL ARRAYCREATE_FLOAT " + vname)
                self.memorize_reference("ARRAYCREATE_FLOAT")
            elif t == ET_TEXT_ARRAY:
                b.wl("ARRAY16 " + vname + " 2")
                initlist.wl("    CALL ARRAYCREATE_STRING " + vname)
                self.memorize_reference("ARRAYCREATE_STRING")
        for i in range(len(self.threadnames)):
            var n = self.threadnames[i]
            b.wl("DATA32 RUNCOUNTER_" + n)
            initlist.wl("    MOVE32_32 0 RUNCOUNTER_" + n)

        b.wl("")

        # vmthread MAIN
        b.wl("vmthread MAIN")
        b.wl("{")
        b.w(self.runtimeinit)
        b.w(initlist.text())
        b.wl("    ARRAY CREATE8 1 LOCKS")
        if self.is_nativecode_referenced():
            b.w(self.create_native_code_download())
        b.wl("    CALL PROGRAM_MAIN -1")
        b.wl("    PROGRAM_STOP -1")
        b.wl("}")

        # не-main потоки
        for i in range(len(self.threadnames)):
            var n = self.threadnames[i]
            b.wl("vmthread " + "T" + n)
            b.wl("{")
            b.wl("    DATA32 tmp")
            b.wl("  launch:")
            b.wl("    CALL PROGRAM_" + n + " " + String(i))
            b.wl(
                "    CALL GETANDINC32 RUNCOUNTER_"
                + n
                + " -1 RUNCOUNTER_"
                + n
                + " tmp"
            )
            b.wl("    JR_GT32 tmp 1 launch")
            b.wl("}")
            self.memorize_reference("GETANDINC32")

        # subcall PROGRAM_* (общая реализация)
        b.wl("subcall PROGRAM_MAIN")
        for i in range(len(self.threadnames)):
            var n = self.threadnames[i]
            b.wl("subcall PROGRAM_" + n)
        b.wl("{")
        b.wl("    IN_32 SUBPROGRAM")
        b.wl("    DATA32 INDEX")
        b.wl("    ARRAY8 STACKPOINTER 4")
        for i in range(len(self.functiondefs)):
            var fd = self.functiondefs[i].copy()
            var locals_n = fd.get_all_local_variables(ET_NUMBER)
            for j in range(len(locals_n)):
                b.wl("    DATAF " + locals_n[j])
        b.wl("    ARRAY32 RETURNSTACK2 128")
        b.wl("    ARRAY32 RETURNSTACK 128")
        for i in range(len(self.functiondefs)):
            var fd = self.functiondefs[i].copy()
            var locals_s = fd.get_all_local_variables(ET_TEXT)
            for j in range(len(locals_s)):
                b.wl("    DATAS " + locals_s[j] + " 252")
        if self.has_any_recursion:
            b.wl("    DATA16 NUMBERSTACKHANDLE")
            b.wl("    DATAF NUMBERSTACKSIZE")
            b.wl("    DATA16 STRINGSTACKHANDLE")
            b.wl("    DATAF STRINGSTACKSIZE")
            b.wl("    CALL ARRAYCREATE_FLOAT NUMBERSTACKHANDLE")
            b.wl("    MOVEF_F 0.0 NUMBERSTACKSIZE")
            b.wl("    CALL ARRAYCREATE_STRING STRINGSTACKHANDLE")
            b.wl("    MOVEF_F 0.0 STRINGSTACKSIZE")
            self.memorize_reference("ARRAYCREATE_FLOAT")
            self.memorize_reference("ARRAYCREATE_STRING")
        b.wl("    MOVE8_8 0 STACKPOINTER")

        for i in range(len(self.threadnames)):
            var l = self.get_label_number()
            var n = self.threadnames[i]
            b.wl("    JR_NEQ32 SUBPROGRAM " + String(i) + " dispatch" + String(l))
            b.wl("    WRITE32 ENDSUB_" + n + ":ENDTHREAD STACKPOINTER RETURNSTACK")
            b.wl("    ADD8 STACKPOINTER 1 STACKPOINTER")
            b.wl("    JR SUB_" + n)
            b.wl("  dispatch" + String(l) + ":")

        b.w(mainprogram.text())
        b.wl("ENDTHREAD:")
        if self.has_any_recursion:
            b.wl("    ARRAY DELETE NUMBERSTACKHANDLE")
            b.wl("    ARRAY DELETE STRINGSTACKHANDLE")
        b.wl("    RETURN")
        b.w(subroutines.text())
        b.wl("}")

        # тела библиотечных subcall в порядке references
        for i in range(len(self.references)):
            var le = self.lib_entries[self.references[i]].copy()
            if not le.inline:
                b.w(le.program_code)
        return b.text()

    def is_nativecode_referenced(self) raises -> Bool:
        if "EV3.NATIVECODE" in self.library:
            var idx = self.library["EV3.NATIVECODE"]
            return idx in self.refset
        return False

    def create_native_code_download(self) -> String:
        """CreateNativeCodeDownload (Compiler.cs:469-496)."""
        var c = C_NATIVECODE
        var clen = c.byte_length() // 2
        var b = Buf()
        b.wl("    DATA16 nativefd")
        b.wl("    DATA32 padding")
        b.wl("    ARRAY8 errorcode 4")
        b.wl("    ARRAY8 nativecode " + String(clen))
        var line = "    INIT_BYTES nativecode " + String(clen)
        for i in range(clen):
            var hi = _byte_at(c, 2 * i)
            var lo = _byte_at(c, 2 * i + 1)
            var v = (_hexval(hi) << 4) | _hexval(lo)
            if v <= 127:
                line = line + " " + String(v)
            else:
                line = line + " -" + String(256 - v)
        b.wl(line)
        b.wl("    FILE OPEN_WRITE '/tmp/nativecode' nativefd")
        b.wl("    FILE WRITE_BYTES nativefd " + String(clen) + " nativecode")
        b.wl("    FILE CLOSE nativefd")
        b.wl("    SYSTEM 'chmod a+x /tmp/nativecode' errorcode")
        return b.text()

    # ======================= компиляция операторов ==========================

    def compile_sub(mut self, mut target: Buf) raises:
        self.parse_keyword("SUB")
        self.currentsub = self.parse_id()
        self.parse_eol()

        var prev = self.currentfunction
        self.currentfunction = self.fos_map[self.currentsub]

        target.wl("SUB_" + self.currentsub + ":")

        while not self.s.next_is_keyword("ENDSUB"):
            self.compile_statement(target)
        self.parse_keyword("ENDSUB")
        self.parse_eol()

        target.wl("RETSUB_" + self.currentsub + ":")
        target.wl("    SUB8 STACKPOINTER 1 STACKPOINTER")
        target.wl("    READ32 RETURNSTACK STACKPOINTER INDEX")
        target.wl("    JR_DYNAMIC INDEX")
        target.wl("ENDSUB_" + self.currentsub + ":")

        self.currentfunction = prev
        self.currentsub = ""

    def compile_statement(mut self, mut target: Buf) raises:
        if self.s.next_type == SYM_PRAGMA:
            if self.s.next_content == "NOBOUNDSCHECK":
                self.noboundscheck = True
            elif self.s.next_content == "BOUNDSCHECK":
                self.noboundscheck = False
            elif self.s.next_content == "NODIVISIONCHECK":
                self.nodivisioncheck = True
            elif self.s.next_content == "DIVISIONCHECK":
                self.nodivisioncheck = False
            else:
                self.s.throw_parse_error("Unknown PRAGMA: " + self.s.next_content)
            self.s.get_sym()
            return
        elif self.s.next_type == SYM_EOL:
            self.s.get_sym()
            return
        elif self.s.next_is_keyword("IF"):
            self.compile_if(target)
        elif self.s.next_is_keyword("WHILE"):
            self.compile_while(target)
        elif self.s.next_is_keyword("FOR"):
            self.compile_for(target)
        elif self.s.next_is_keyword("GOTO"):
            self.compile_goto(target)
        else:
            self.compile_atomic_statement(target)
            self.parse_eol()

    def compile_if(mut self, mut target: Buf) raises:
        var l = self.get_label_number()

        self.parse_keyword("IF")

        var e = self.parse_typed_expression(
            ET_TEXT, "Need a text as a boolean value here"
        )
        self.expr_gen_jump_if(e, target, "else" + String(l) + "_1", False)

        self.parse_keyword("THEN")
        self.parse_eol()

        var numbranches = 0
        while True:
            if self.s.next_is_keyword("ELSEIF"):
                self.parse_keyword("ELSEIF")

                var e2 = self.parse_typed_expression(
                    ET_TEXT, "Need a text as a boolean value here"
                )

                numbranches += 1
                target.wl("    JR endif" + String(l))
                target.wl("  else" + String(l) + "_" + String(numbranches) + ":")
                self.expr_gen_jump_if(
                    e2,
                    target,
                    "else" + String(l) + "_" + String(numbranches + 1),
                    False,
                )

                self.parse_keyword("THEN")
                self.parse_eol()
            elif self.s.next_is_keyword("ELSE"):
                self.parse_keyword("ELSE")
                self.parse_eol()

                numbranches += 1
                target.wl("    JR endif" + String(l))
                target.wl("  else" + String(l) + "_" + String(numbranches) + ":")

                while not self.s.next_is_keyword("ENDIF"):
                    self.compile_statement(target)
                break
            elif self.s.next_is_keyword("ENDIF"):
                break
            else:
                self.compile_statement(target)

        self.parse_keyword("ENDIF")
        self.parse_eol()

        target.wl("  else" + String(l) + "_" + String(numbranches + 1) + ":")
        target.wl("  endif" + String(l) + ":")

    def compile_while(mut self, mut target: Buf) raises:
        var l = self.get_label_number()

        self.parse_keyword("WHILE")

        var e = self.parse_typed_expression(
            ET_TEXT, "Need a text as a boolean value here"
        )

        target.wl("  while" + String(l) + ":")
        self.expr_gen_jump_if(e, target, "endwhile" + String(l), False)
        target.wl("  whilebody" + String(l) + ":")
        self.parse_eol()

        while not self.s.next_is_keyword("ENDWHILE"):
            self.compile_statement(target)
        self.parse_keyword("ENDWHILE")
        self.parse_eol()

        self.expr_gen_jump_if(e, target, "whilebody" + String(l), True)
        target.wl("  endwhile" + String(l) + ":")

    def compile_for(mut self, mut target: Buf) raises:
        var l = self.get_label_number()

        self.parse_keyword("FOR")

        var basicvarname = self.parse_id()
        var varname = "V" + basicvarname

        if not self.has_variable(varname):
            _ = self.define_variable(varname, ET_NUMBER)
        elif self.variable_type(varname) != ET_NUMBER:
            self.s.throw_parse_error(
                "Can not use "
                + basicvarname
                + " as loop counter. Is already defined to contain non-number"
            )

        self.parse_special("=")

        var startexpression = self.parse_float_expression(
            "Can only use a number as loop start value"
        )

        self.parse_keyword("TO")

        var stopexpression = self.parse_float_expression(
            "Can only use a number as loop stop value"
        )

        var testexpression: Int
        var incexpression: Int
        if self.s.next_is_keyword("STEP"):
            self.parse_keyword("STEP")
            var stepexpression = self.parse_float_expression(
                "Can only use a number as loop step value"
            )

            if self.expr_is_positive(stepexpression):
                testexpression = self.ex_comparison(
                    "CALL LE",
                    "JR_LTEQF",
                    "JR_GTF",
                    self.ex_atomic(ET_NUMBER, varname),
                    stopexpression,
                )
            elif self.expr_is_negative(stepexpression):
                testexpression = self.ex_comparison(
                    "CALL GE",
                    "JR_GTEQF",
                    "JR_LTF",
                    self.ex_atomic(ET_NUMBER, varname),
                    stopexpression,
                )
            else:
                var args = List[Int]()
                args.append(self.ex_atomic(ET_NUMBER, varname))
                args.append(stopexpression)
                args.append(stepexpression)
                testexpression = self.ex_call(ET_TEXT, "CALL LE_STEP", args)
            var args2 = List[Int]()
            args2.append(self.ex_atomic(ET_NUMBER, varname))
            args2.append(stepexpression)
            incexpression = self.ex_call(ET_NUMBER, "ADDF", args2)
        else:
            testexpression = self.ex_comparison(
                "CALL LE",
                "JR_LTEQF",
                "JR_GTF",
                self.ex_atomic(ET_NUMBER, varname),
                stopexpression,
            )
            var args2 = List[Int]()
            args2.append(self.ex_atomic(ET_NUMBER, varname))
            args2.append(self.ex_number(1.0))
            incexpression = self.ex_call(ET_NUMBER, "ADDF", args2)
        self.parse_eol()

        self.expr_generate(startexpression, target, varname)

        target.wl("  for" + String(l) + ":")
        self.expr_gen_jump_if(testexpression, target, "endfor" + String(l), False)
        target.wl("  forbody" + String(l) + ":")

        while not self.s.next_is_keyword("ENDFOR"):
            self.compile_statement(target)
        self.parse_keyword("ENDFOR")
        self.parse_eol()

        self.expr_generate(incexpression, target, varname)
        self.expr_gen_jump_if(testexpression, target, "forbody" + String(l), True)
        target.wl("  endfor" + String(l) + ":")

    def compile_goto(mut self, mut target: Buf) raises:
        self.parse_keyword("GOTO")

        if self.s.next_type != SYM_ID:
            self.s.throw_expected_symbol(SYM_ID, "")

        var label = self.s.next_content
        self.s.get_sym()

        target.wl("    JR L" + label)

        self.parse_eol()

    def compile_atomic_statement(mut self, mut target: Buf) raises:
        if self.s.next_type != SYM_ID:
            self.s.throw_expected_symbol(SYM_ID, "")
        var id = self.s.next_content
        self.s.get_sym()

        if self.s.next_is_special("="):
            self.s.push_back(SYM_ID, id)
            self.compile_variable_assignment(target)
        elif self.s.next_is_special("["):
            self.s.push_back(SYM_ID, id)
            self.compile_array_assignment(target)
        elif self.s.next_is_special("."):
            self.s.push_back(SYM_ID, id)
            self.compile_procedure_call_or_property_set(target)
        elif self.s.next_is_special("("):
            # вызов подпрограммы
            self.parse_special("(")
            self.parse_special(")")

            var returnlabel = "CALLSUB" + String(self.get_label_number())
            target.wl(
                "    WRITE32 ENDSUB_"
                + id
                + ":"
                + returnlabel
                + " STACKPOINTER RETURNSTACK"
            )
            target.wl("    ADD8 STACKPOINTER 1 STACKPOINTER")
            target.wl("    JR SUB_" + id)
            target.wl(returnlabel + ":")
        elif self.s.next_is_special(":"):
            # метка перехода
            self.parse_special(":")
            target.wl("  L" + id + ":")
        else:
            self.s.throw_unexpected_symbol()

    def compile_variable_assignment(mut self, mut target: Buf) raises:
        var basicvarname = self.parse_id()
        self.parse_special("=")
        var e = self.parse_expression()

        var varname = "V" + basicvarname
        if not self.has_variable(varname):
            _ = self.define_variable(varname, self.etype_of(e))
        elif self.variable_type(varname) != self.etype_of(e):
            self.s.throw_parse_error("Can not assign different types to " + basicvarname)

        self.expr_generate(e, target, varname)

    def compile_array_assignment(mut self, mut target: Buf) raises:
        var basicvarname = self.parse_id()
        self.parse_special("[")
        var eidx = self.parse_float_expression("Can only have number as array index")
        self.parse_special("]")
        self.parse_special("=")
        var e = self.parse_expression()

        if self.etype_of(e) != ET_NUMBER and self.etype_of(e) != ET_TEXT:
            self.s.throw_parse_error("Can only store numbers or strings into arrays")
        var atype = ET_TEXT_ARRAY
        if self.etype_of(e) == ET_NUMBER:
            atype = ET_NUMBER_ARRAY

        var varname = "V" + basicvarname
        if not self.has_variable(varname):
            _ = self.define_variable(varname, atype)
        elif self.variable_type(varname) != atype:
            self.s.throw_parse_error(
                "Can not use " + basicvarname + " as array to store this type"
            )

        if self.etype_of(e) == ET_TEXT:
            var args = List[Int]()
            args.append(eidx)
            args.append(e)
            var aex = self.ex_call(
                ET_VOID, "CALL ARRAYSTORE_STRING :0 :1 " + varname, args
            )
            self.expr_generate(aex, target, "")
        else:
            if self.noboundscheck:
                if self.kind_of(eidx) == EK_NUMBER:
                    var indexval = Int(self.num_of(eidx))
                    if indexval >= 0:
                        var args = List[Int]()
                        args.append(e)
                        var aex = self.ex_call(
                            ET_VOID,
                            "ARRAY_WRITE " + varname + " " + String(indexval),
                            args,
                        )
                        self.expr_generate(aex, target, "")
                else:
                    var args = List[Int]()
                    args.append(eidx)
                    args.append(e)
                    var aex = self.ex_call(
                        ET_VOID,
                        "MOVEF_32 :0 INDEX\n    ARRAY_WRITE " + varname + " INDEX :1",
                        args,
                    )
                    self.expr_generate(aex, target, "")
            else:
                var args = List[Int]()
                args.append(eidx)
                args.append(e)
                var aex = self.ex_call(
                    ET_VOID, "CALL ARRAYSTORE_FLOAT :0 :1 " + varname, args
                )
                self.expr_generate(aex, target, "")

    def compile_procedure_call_or_property_set(mut self, mut target: Buf) raises:
        var objectname = self.parse_id()
        self.parse_special(".")
        var elementname = self.parse_id()

        # попытка присваивания свойства
        if self.s.next_is_special("="):
            self.parse_special("=")

            if objectname == "THREAD" and elementname == "RUN":
                var id = self.parse_id()
                var l = self.get_label_number()
                target.wl("    DATA32 tmp" + String(l))
                target.wl(
                    "    CALL GETANDINC32 RUNCOUNTER_"
                    + id
                    + " 1  RUNCOUNTER_"
                    + id
                    + " tmp"
                    + String(l)
                )
                target.wl(
                    "    JR_NEQ32 0 tmp" + String(l) + " alreadylaunched" + String(l)
                )
                target.wl("    OBJECT_START T" + id)
                target.wl("  alreadylaunched" + String(l) + ":")
                var found = False
                for i in range(len(self.threadnames)):
                    if self.threadnames[i] == id:
                        found = True
                        break
                if not found:
                    self.threadnames.append(id)
            elif objectname == "F" and elementname == "START":
                _ = self.parse_id()
            else:
                self.s.throw_parse_error(
                    "Unknown property to set:  " + objectname + "." + elementname
                )

            return
        else:
            var list = List[Int]()
            self.parse_special("(")

            var cmdname = objectname + "." + elementname

            # F.FUNCTION игнорируется (обработан в первом проходе)
            if cmdname == "F.FUNCTION":
                while not self.s.next_is_special(")"):
                    self.s.get_sym()
                self.parse_special(")")
                return

            # F.SET
            if cmdname == "F.SET":
                var vname = to_upper_ascii(self.parse_string())
                self.parse_optional_special(",")
                var cf = self.functiondefs[self.currentfunction].copy()
                var vidx = cf.find_parameter(vname)
                if vidx < 0:
                    self.s.throw_parse_error("Undefined local variable: " + vname)
                var t = cf.parameter_type(vidx)
                var e = self.parse_typed_expression_with_parameterconversion(t)
                self.parse_optional_special(",")
                self.parse_special(")")
                self.expr_generate(e, target, cf.parameter_variable(vidx))
                return
            # F.RETURN / F.RETURNNUMBER / F.RETURNTEXT
            elif (
                cmdname == "F.RETURN"
                or cmdname == "F.RETURNNUMBER"
                or cmdname == "F.RETURNTEXT"
            ):
                var rt = ET_VOID
                if cmdname.endswith("NUMBER"):
                    rt = ET_NUMBER
                elif cmdname.endswith("TEXT"):
                    rt = ET_TEXT

                var fd_idx = self.fos_map[self.currentsub]
                var fd = self.functiondefs[fd_idx].copy()
                if fd.fname.byte_length() < 1:
                    self.s.throw_parse_error("Can only use RETURN from inside function")
                if fd.startsub != self.currentsub:
                    self.s.throw_parse_error(
                        "Can only use RETURN in primary SUB of a function"
                    )

                if rt != ET_VOID:
                    if fd.get_return_type() != rt:
                        self.s.throw_parse_error(
                            "Return command must be of same type as function definiton"
                        )
                    var e = self.parse_typed_expression_with_parameterconversion(rt)
                    self.parse_optional_special(",")
                    self.expr_generate(e, target, fd.get_return_variable())
                self.parse_special(")")
                target.wl("    JR RETSUB_" + self.currentsub)
                return

            # любой F.CALL без возвращаемого значения
            if cmdname.startswith("F.CALL"):
                var fname = to_upper_ascii(self.parse_string())
                if not (fname in self.fdef_index):
                    self.s.throw_parse_error("Undefined function: " + fname)
                self.parse_optional_special(",")
                var fd = self.functiondefs[self.fdef_index[fname]].copy()

                while not self.s.next_is_special(")"):
                    if len(list) >= fd.parameter_number():
                        self.s.throw_parse_error(
                            "Too many arguments for function: " + fname
                        )
                    var t = fd.parameter_type(len(list))
                    var e = self.parse_typed_expression_with_parameterconversion(t)
                    list.append(e)
                    self.parse_optional_special(",")
                self.parse_special(")")

                var fex = self.ex_function(
                    self.fdef_index[fname], fd.get_return_type(), list
                )
                self.expr_generate(fex, target, "")
                return

            if not (cmdname in self.library):
                self.s.throw_parse_error("Undefined command: " + cmdname)

            var le = self.lib_entries[self.library[cmdname]].copy()

            while len(list) < len(le.param_types):
                var e = self.parse_typed_expression_with_parameterconversion(
                    le.param_types[len(list)]
                )
                list.append(e)
                self.parse_optional_special(",")
            self.parse_special(")")

            var callname = String("CALL ")
            if le.inline:
                callname = le.program_code
            else:
                callname = "CALL " + cmdname
            var ex = self.ex_call(le.return_type, callname, list)
            if le.return_type == ET_VOID:
                self.expr_generate(ex, target, "")
            else:
                var retvar = self.reserve_variable(le.return_type)
                if retvar == "":
                    self.s.throw_parse_error(
                        "Return value that is an array must be directly stored in a variable"
                    )
                self.expr_generate(ex, target, retvar)
                self.release_variable(le.return_type)

    # ======================= генерация кода выражений =======================

    def expr_prepared_value(self, e: Int) -> Tuple[Bool, String]:
        """PreparedValue: (False, "") — требуется генерация вычисления."""
        var node = self.enodes[e].copy()
        if node.kind == EK_NUMBER:
            return True, fmt_number_literal(node.num)
        if node.kind == EK_ATOMIC:
            return True, node.text
        return False, ""

    def expr_is_positive(self, e: Int) -> Bool:
        return self.enodes[e].kind == EK_NUMBER and self.enodes[e].num > 0

    def expr_is_negative(self, e: Int) -> Bool:
        return self.enodes[e].kind == EK_NUMBER and self.enodes[e].num < 0

    def expr_base_generate(self, e: Int, mut b: Buf, outputvar: String) raises:
        """Expression.Generate по умолчанию (копирование подготовленного)."""
        var prepared = self.expr_prepared_value(e)
        if not prepared[0]:
            raise Error("Internal error: no implementation to compute this exception")
        var v = prepared[1]
        var node = self.enodes[e].copy()
        if node.etype == ET_NUMBER:
            b.wl("    MOVEF_F " + v + " " + outputvar)
        elif node.etype == ET_TEXT:
            b.wl("    STRINGS DUPLICATE " + v + " " + outputvar)
        elif node.etype == ET_NUMBER_ARRAY or node.etype == ET_TEXT_ARRAY:
            b.wl("    ARRAY COPY " + v + " " + outputvar)

    def expr_generate(mut self, e: Int, mut b: Buf, outputvar: String) raises:
        """Expression.Generate — диспетчеризация по виду узла."""
        var kind = self.enodes[e].kind
        if kind == EK_NUMBER or kind == EK_ATOMIC:
            self.expr_base_generate(e, b, outputvar)
        elif kind == EK_UNSAFE_ARRAY:
            self.expr_unsafe_generate(e, b, outputvar)
        elif kind == EK_FUNCTION:
            self.expr_function_generate(e, b, outputvar)
        else:
            self.expr_call_generate(e, b, outputvar)

    def expr_call_generate(mut self, e: Int, mut b: Buf, outputvar: String) raises:
        """CallExpression.Generate (Expression.cs:198-265)."""
        var node = self.enodes[e].copy()
        var arguments = List[String]()
        var releases = List[Int]()
        for i in range(len(node.children)):
            var p = node.children[i]
            var prepared = self.expr_prepared_value(p)
            var arg = String("")
            if not prepared[0]:
                arg = self.reserve_variable(self.enodes[p].etype)
                releases.append(self.enodes[p].etype)
                self.expr_generate(p, b, arg)
            else:
                arg = prepared[1]
            arguments.append(arg)
        if outputvar != "":
            arguments.append(outputvar)

        var expansion = self.get_label_number()
        var fmt = inject_placeholders(arguments, node.text, expansion)
        b.w("    " + fmt)
        for i in range(len(arguments)):
            if arguments[i] != "":
                b.w(" " + arguments[i])
        b.wl("")

        for i in range(len(releases)):
            self.release_variable(releases[i])

        # memorize ссылок на subcall'ы из текста "CALL X ..."
        var idx = 0
        while True:
            idx = node.text.find("CALL ", idx)
            if idx < 0:
                break
            if idx == 0 or _byte_at(node.text, idx - 1) == 32 or _byte_at(
                node.text, idx - 1
            ) == 9:
                var n = String(_sub_bytes(node.text, idx + 5, node.text.byte_length()))
                var n2 = String(n.strip())
                var space = n2.find(" ")
                if space >= 0:
                    n2 = String(String(_sub_bytes(n2, 0, space)).strip())
                self.memorize_reference(n2)
            idx += 1

    def expr_unsafe_generate(mut self, e: Int, mut b: Buf, outputvar: String) raises:
        """UnsafeArrayGetExpression.Generate (Expression.cs:419-452)."""
        var index = self.enodes[e].children[0]
        if self.enodes[index].etype != ET_NUMBER:
            raise Error("Internal error: non-number type expression for array index")
        if self.enodes[index].kind == EK_NUMBER:
            var idxvalue = Int(self.enodes[index].num)
            if idxvalue < 0:
                b.wl("    MOVEF_F 0.0 " + outputvar)
            else:
                b.wl(
                    "    ARRAY_READ "
                    + self.enodes[e].text
                    + " "
                    + String(idxvalue)
                    + " "
                    + outputvar
                )
        else:
            var prepared = self.expr_prepared_value(index)
            if prepared[0]:
                b.wl("    MOVEF_32 " + prepared[1] + " INDEX")
                b.wl("    ARRAY_READ " + self.enodes[e].text + " INDEX " + outputvar)
            else:
                self.expr_generate(index, b, outputvar)
                b.wl("    MOVEF_32 " + outputvar + " INDEX")
                b.wl("    ARRAY_READ " + self.enodes[e].text + " INDEX " + outputvar)

    def expr_function_generate(mut self, e: Int, mut b: Buf, outputvar: String) raises:
        """FunctionExpression.Generate (Expression.cs:467-556) — F.CALL."""
        var node = self.enodes[e].copy()
        var cf_idx = self.currentfunction
        var dosave = self.function_could_call(node.fd_idx, cf_idx)
        if dosave:
            var cf = self.functiondefs[cf_idx].copy()
            var nums = cf.get_current_local_variables(ET_NUMBER)
            for i in range(len(nums)):
                b.wl(
                    "    CALL ARRAYSTORE_FLOAT NUMBERSTACKSIZE "
                    + nums[i]
                    + " NUMBERSTACKHANDLE"
                )
                b.wl("    ADDF NUMBERSTACKSIZE 1.0 NUMBERSTACKSIZE")
                self.memorize_reference("ARRAYSTORE_FLOAT")
            var texts = cf.get_current_local_variables(ET_TEXT)
            for i in range(len(texts)):
                b.wl(
                    "    CALL ARRAYSTORE_STRING STRINGSTACKSIZE "
                    + texts[i]
                    + " STRINGSTACKHANDLE"
                )
                b.wl("    ADDF STRINGSTACKSIZE 1.0 STRINGSTACKSIZE")
                self.memorize_reference("ARRAYSTORE_STRING")

        var fd = self.functiondefs[node.fd_idx].copy()
        var tmpvar = List[String]()
        for i in range(len(node.children)):
            var t = self.reserve_variable(self.enodes[node.children[i]].etype)
            tmpvar.append(t)
            self.expr_generate(node.children[i], b, t)
        for i in range(fd.parameter_number()):
            var pv = fd.parameter_variable(i)
            if fd.parameter_type(i) == ET_NUMBER:
                var src = fd.parameter_default_literal(i)
                if i < len(tmpvar):
                    src = tmpvar[i]
                b.wl("    MOVEF_F " + src + " " + pv)
            elif fd.parameter_type(i) == ET_TEXT:
                var src = fd.parameter_default_literal(i)
                if i < len(tmpvar):
                    src = tmpvar[i]
                b.wl("    STRINGS DUPLICATE " + src + " " + pv)
        for i in range(len(node.children)):
            var j = len(node.children) - 1 - i
            self.release_variable(self.enodes[node.children[j]].etype)

        var subid = fd.startsub
        var returnlabel = "CALLSUB" + String(self.get_label_number())
        b.wl(
            "    WRITE32 ENDSUB_"
            + subid
            + ":"
            + returnlabel
            + " STACKPOINTER RETURNSTACK"
        )
        b.wl("    ADD8 STACKPOINTER 1 STACKPOINTER")
        b.wl("    JR SUB_" + subid)
        b.wl(returnlabel + ":")

        if dosave:
            var cf2 = self.functiondefs[cf_idx].copy()
            var nums = cf2.get_current_local_variables(ET_NUMBER)
            var i = len(nums) - 1
            while i >= 0:
                b.wl("    SUBF NUMBERSTACKSIZE 1.0 NUMBERSTACKSIZE")
                b.wl(
                    "    CALL ARRAYGET_FLOAT NUMBERSTACKSIZE "
                    + nums[i]
                    + " NUMBERSTACKHANDLE"
                )
                self.memorize_reference("ARRAYGET_FLOAT")
                i -= 1
            var texts = cf2.get_current_local_variables(ET_TEXT)
            var j = len(texts) - 1
            while j >= 0:
                b.wl("    SUBF STRINGSTACKSIZE 1.0 STRINGSTACKSIZE")
                b.wl(
                    "    CALL ARRAYGET_STRING STRINGSTACKSIZE "
                    + texts[j]
                    + " STRINGSTACKHANDLE"
                )
                self.memorize_reference("ARRAYGET_STRING")
                j -= 1

        if outputvar != "":
            if fd.get_return_type() == ET_NUMBER:
                b.wl("    MOVEF_F " + fd.get_return_variable() + " " + outputvar)
            elif fd.get_return_type() == ET_TEXT:
                b.wl(
                    "    STRINGS DUPLICATE "
                    + fd.get_return_variable()
                    + " "
                    + outputvar
                )

    # --- условия ------------------------------------------------------------

    def expr_text_cond_jump(mut self, e: Int, mut b: Buf, jumplabel: String, jump_if_true: Bool) raises:
        """Expression.GenerateJumpIfCondition (Expression.cs:76-88)."""
        var v = self.reserve_variable(ET_TEXT)
        self.expr_generate(e, b, v)
        b.wl("    AND8888_32 " + v + " -538976289 " + v)
        b.wl("    STRINGS COMPARE " + v + " 'TRUE' " + v)
        var jr = "JR_EQ8"
        if jump_if_true:
            jr = "JR_NEQ8"
        b.wl("    " + jr + " " + v + " 0 " + jumplabel)
        self.release_variable(ET_TEXT)

    def expr_gen_jump_if(mut self, e: Int, mut b: Buf, jumplabel: String, jump_if_true: Bool) raises:
        """GenerateJumpIfCondition с диспетчеризацией по виду выражения."""
        var node = self.enodes[e].copy()
        if node.kind == EK_ATOMIC:
            if node.etype == ET_TEXT and node.text.startswith("'"):
                var is_true = node.text.upper() == "'TRUE'"
                if jump_if_true == is_true:
                    b.wl("    JR " + jumplabel)
                return
            self.expr_text_cond_jump(e, b, jumplabel, jump_if_true)
            return
        if node.kind == EK_COMPARISON:
            self.expr_comparison_jump(e, b, jumplabel, jump_if_true)
            return
        if node.kind == EK_AND:
            self.expr_and_jump(e, b, jumplabel, jump_if_true)
            return
        if node.kind == EK_OR:
            self.expr_or_jump(e, b, jumplabel, jump_if_true)
            return
        if node.etype != ET_TEXT:
            raise Error(
                "Internal error: Try to generate jump for non text condition type"
            )
        self.expr_text_cond_jump(e, b, jumplabel, jump_if_true)

    def expr_comparison_jump(mut self, e: Int, mut b: Buf, jumplabel: String, jump_if_true: Bool) raises:
        """ComparisonExpression.GenerateJumpIfCondition (Expression.cs:326-358)."""
        var numrelease = 0
        var p1 = self.enodes[e].children[0]
        var prepared1 = self.expr_prepared_value(p1)
        var v1 = String("")
        if not prepared1[0]:
            v1 = self.reserve_variable(ET_NUMBER)
            numrelease += 1
            self.expr_generate(p1, b, v1)
        else:
            v1 = prepared1[1]
        var p2 = self.enodes[e].children[1]
        var prepared2 = self.expr_prepared_value(p2)
        var v2 = String("")
        if not prepared2[0]:
            v2 = self.reserve_variable(ET_NUMBER)
            numrelease += 1
            self.expr_generate(p2, b, v2)
        else:
            v2 = prepared2[1]
        var jump = self.enodes[e].alt2
        if jump_if_true:
            jump = self.enodes[e].alt1
        b.wl("    " + jump + " " + v1 + " " + v2 + " " + jumplabel)
        for i in range(numrelease):
            self.release_variable(ET_NUMBER)

    def expr_and_jump(mut self, e: Int, mut b: Buf, jumplabel: String, jump_if_true: Bool) raises:
        """AndExpression.GenerateJumpIfCondition (Expression.cs:367-381)."""
        if jump_if_true:
            var l = self.get_label_number()
            self.expr_gen_jump_if(
                self.enodes[e].children[0], b, "and" + String(l), False
            )
            self.expr_gen_jump_if(self.enodes[e].children[1], b, jumplabel, True)
            b.wl("  and" + String(l) + ":")
        else:
            self.expr_gen_jump_if(self.enodes[e].children[0], b, jumplabel, False)
            self.expr_gen_jump_if(self.enodes[e].children[1], b, jumplabel, False)

    def expr_or_jump(mut self, e: Int, mut b: Buf, jumplabel: String, jump_if_true: Bool) raises:
        """OrExpression.GenerateJumpIfCondition (Expression.cs:390-404)."""
        if jump_if_true:
            self.expr_gen_jump_if(self.enodes[e].children[0], b, jumplabel, True)
            self.expr_gen_jump_if(self.enodes[e].children[1], b, jumplabel, True)
        else:
            var l = self.get_label_number()
            self.expr_gen_jump_if(self.enodes[e].children[0], b, "or" + String(l), True)
            self.expr_gen_jump_if(self.enodes[e].children[1], b, jumplabel, False)
            b.wl("  or" + String(l) + ":")

    # ======================= разбор выражений ===============================

    def parse_typed_expression_with_parameterconversion(mut self, t: Int) raises -> Int:
        var e = self.parse_expression()

        if self.etype_of(e) == ET_NUMBER and t == ET_TEXT:
            # автоматическое преобразование числа в текст
            var args = List[Int]()
            args.append(e)
            return self.ex_call(ET_TEXT, "STRINGS VALUE_FORMATTED :0 '%g' 99", args)
        elif self.etype_of(e) != t:
            self.s.throw_parse_error(
                "Can not use this expression type here: "
                + et_name(self.etype_of(e))
                + ". Expected: "
                + et_name(t)
            )
        return e

    def parse_float_expression(mut self, reasonmessage: String) raises -> Int:
        return self.parse_typed_expression(ET_NUMBER, reasonmessage)

    def parse_typed_expression(mut self, t: Int, reasonmessage: String) raises -> Int:
        var e = self.parse_expression()
        if self.etype_of(e) != t:
            self.s.throw_parse_error(reasonmessage)
        return e

    def parse_expression(mut self) raises -> Int:
        return self.parse_or_expression()

    def parse_or_expression(mut self) raises -> Int:
        var total = self.parse_and_expression()
        while True:
            if self.s.next_is_keyword("OR"):
                self.s.get_sym()

                if self.etype_of(total) != ET_TEXT:
                    self.s.throw_parse_error("need text on left side of OR")
                var right = self.parse_and_expression()
                if self.etype_of(right) != ET_TEXT:
                    self.s.throw_parse_error("need text on right side of OR")

                total = self.ex_or(total, right)
            else:
                break
        return total

    def parse_and_expression(mut self) raises -> Int:
        var total = self.parse_comparative_expression()
        while True:
            if self.s.next_is_keyword("AND"):
                self.s.get_sym()

                if self.etype_of(total) != ET_TEXT:
                    self.s.throw_parse_error("need text on left side of AND")
                var right = self.parse_comparative_expression()
                if self.etype_of(right) != ET_TEXT:
                    self.s.throw_parse_error("need text on right side of AND")
                total = self.ex_and(total, right)
            else:
                break
        return total

    def parse_comparative_expression(mut self) raises -> Int:
        var total = self.parse_additive_expression()

        while True:
            if self.s.next_is_special("="):
                self.s.get_sym()

                var right = self.parse_additive_expression()
                if self.etype_of(total) != self.etype_of(right):
                    self.s.throw_parse_error(
                        "Need identical types on both sides of '='"
                    )
                if self.etype_of(total) == ET_NUMBER:
                    total = self.ex_comparison(
                        "CALL EQ_FLOAT", "JR_EQF", "JR_NEQF", total, right
                    )
                elif self.etype_of(total) == ET_TEXT:
                    var args = List[Int]()
                    args.append(total)
                    args.append(right)
                    total = self.ex_call(ET_TEXT, "CALL EQ_STRING", args)
                else:
                    self.s.throw_parse_error("Can not compare arrays")
            elif self.s.next_is_special("<>"):
                self.s.get_sym()

                var right = self.parse_additive_expression()
                if self.etype_of(total) != self.etype_of(right):
                    self.s.throw_parse_error(
                        "Need identical types on both sides of '<>'"
                    )
                if self.etype_of(total) == ET_NUMBER:
                    total = self.ex_comparison(
                        "CALL NEQ_FLOAT", "JR_NEQF", "JR_EQF", total, right
                    )
                elif self.etype_of(total) == ET_TEXT:
                    var args = List[Int]()
                    args.append(total)
                    args.append(right)
                    total = self.ex_call(ET_TEXT, "CALL NE_STRING", args)
                else:
                    self.s.throw_parse_error("Can not compare arrays")
            elif self.s.next_is_special("<"):
                self.s.get_sym()
                if self.etype_of(total) != ET_NUMBER:
                    self.s.throw_parse_error("need number on left side of '<'")
                var right = self.parse_additive_expression()
                if self.etype_of(right) != ET_NUMBER:
                    self.s.throw_parse_error("need number on right side of '<'")
                total = self.ex_comparison("CALL LT", "JR_LTF", "JR_GTEQF", total, right)
            elif self.s.next_is_special(">"):
                self.s.get_sym()
                if self.etype_of(total) != ET_NUMBER:
                    self.s.throw_parse_error("need number on left side of '>'")
                var right = self.parse_additive_expression()
                if self.etype_of(right) != ET_NUMBER:
                    self.s.throw_parse_error("need number on right side of '>'")
                total = self.ex_comparison("CALL GT", "JR_GTF", "JR_LTEQF", total, right)
            elif self.s.next_is_special("<="):
                self.s.get_sym()
                if self.etype_of(total) != ET_NUMBER:
                    self.s.throw_parse_error("need number on left side of '<='")
                var right = self.parse_additive_expression()
                if self.etype_of(right) != ET_NUMBER:
                    self.s.throw_parse_error("need number on right side of '<='")
                total = self.ex_comparison(
                    "CALL LE", "JR_LTEQF", "JR_GTF", total, right
                )
            elif self.s.next_is_special(">="):
                self.s.get_sym()
                if self.etype_of(total) != ET_NUMBER:
                    self.s.throw_parse_error("need number on left side of '>='")
                var right = self.parse_additive_expression()
                if self.etype_of(right) != ET_NUMBER:
                    self.s.throw_parse_error("need number on right side of '>='")
                total = self.ex_comparison(
                    "CALL GE", "JR_GTEQF", "JR_LTF", total, right
                )
            else:
                break

        return total

    def parse_additive_expression(mut self) raises -> Int:
        var total = self.parse_multiplicative_expression()

        while True:
            if self.s.next_is_special("+"):
                self.s.get_sym()

                var right = self.parse_multiplicative_expression()

                if self.etype_of(total) == ET_TEXT:
                    if self.etype_of(right) == ET_NUMBER:
                        var args = List[Int]()
                        args.append(right)
                        right = self.ex_call(
                            ET_TEXT, "STRINGS VALUE_FORMATTED :0 '%g' 99", args
                        )
                    if self.etype_of(right) != ET_TEXT:
                        self.s.throw_parse_error("Can not concat arrays")
                    var args = List[Int]()
                    args.append(total)
                    args.append(right)
                    total = self.ex_call(ET_TEXT, "CALL TEXT.APPEND", args)
                elif self.etype_of(total) == ET_NUMBER:
                    if self.etype_of(right) == ET_TEXT:
                        var args = List[Int]()
                        args.append(total)
                        total = self.ex_call(
                            ET_TEXT, "STRINGS VALUE_FORMATTED :0 '%g' 99", args
                        )
                        var args2 = List[Int]()
                        args2.append(total)
                        args2.append(right)
                        total = self.ex_call(ET_TEXT, "CALL TEXT.APPEND", args2)
                    elif self.etype_of(right) == ET_NUMBER:
                        if (
                            self.kind_of(total) == EK_NUMBER
                            and self.kind_of(right) == EK_NUMBER
                        ):
                            # вычисление на этапе компиляции
                            total = self.ex_number(self.num_of(total) + self.num_of(right))
                        else:
                            var args = List[Int]()
                            args.append(total)
                            args.append(right)
                            total = self.ex_call(ET_NUMBER, "ADDF", args)
                    else:
                        self.s.throw_parse_error("Can not concat arrays")
                else:
                    self.s.throw_parse_error("Can not concat arrays")

            elif self.s.next_is_special("-"):
                self.s.get_sym()
                if self.etype_of(total) != ET_NUMBER:
                    self.s.throw_parse_error("need number on left side of '-'")
                var right = self.parse_multiplicative_expression()
                if self.etype_of(right) != ET_NUMBER:
                    self.s.throw_parse_error("need number on right side of '-'")

                if (
                    self.kind_of(total) == EK_NUMBER
                    and self.kind_of(right) == EK_NUMBER
                ):
                    total = self.ex_number(self.num_of(total) - self.num_of(right))
                else:
                    var args = List[Int]()
                    args.append(total)
                    args.append(right)
                    total = self.ex_call(ET_NUMBER, "SUBF", args)
            else:
                break

        return total

    def parse_multiplicative_expression(mut self) raises -> Int:
        var total = self.parse_unary_minus_expression()

        while True:
            if self.s.next_is_special("*"):
                self.s.get_sym()
                if self.etype_of(total) != ET_NUMBER:
                    self.s.throw_parse_error("need number on left side of '*'")
                var right = self.parse_unary_minus_expression()
                if self.etype_of(right) != ET_NUMBER:
                    self.s.throw_parse_error("need number on right side of '*'")

                if (
                    self.kind_of(total) == EK_NUMBER
                    and self.kind_of(right) == EK_NUMBER
                ):
                    total = self.ex_number(self.num_of(total) * self.num_of(right))
                else:
                    var args = List[Int]()
                    args.append(total)
                    args.append(right)
                    total = self.ex_call(ET_NUMBER, "MULF", args)
            elif self.s.next_is_special("/"):
                self.s.get_sym()
                if self.etype_of(total) != ET_NUMBER:
                    self.s.throw_parse_error("need number on left side of '/'")
                var right = self.parse_unary_minus_expression()
                if self.etype_of(right) != ET_NUMBER:
                    self.s.throw_parse_error("need number on right side of '/'")

                if (
                    self.kind_of(total) == EK_NUMBER
                    and self.kind_of(right) == EK_NUMBER
                ):
                    # константное деление: деление на 0 даёт 0.0
                    var a = self.num_of(total)
                    var bnum = self.num_of(right)
                    var res = 0.0
                    if bnum != 0.0:
                        res = a / bnum
                    total = self.ex_number(res)
                else:
                    if self.nodivisioncheck:
                        var args = List[Int]()
                        args.append(total)
                        args.append(right)
                        total = self.ex_call(ET_NUMBER, "DIVF", args)
                    else:
                        var args = List[Int]()
                        args.append(total)
                        args.append(right)
                        total = self.ex_call(
                            ET_NUMBER,
                            "DATAF tmpf:#\n"
                            + "    DATA8 flag:#\n"
                            + "    DIVF :0 :1 tmpf:#\n"
                            + "    CP_EQF 0.0 :1 flag:#\n"
                            + "    SELECTF flag:# 0.0 tmpf:# :2\n",
                            args,
                        )
            else:
                break

        return total

    def parse_unary_minus_expression(mut self) raises -> Int:
        if self.s.next_is_special("-"):
            self.s.get_sym()

            var e = self.parse_unary_minus_expression()
            if self.etype_of(e) != ET_NUMBER:
                self.s.throw_parse_error("need number after '-'")

            if self.kind_of(e) == EK_NUMBER:
                return self.ex_number(-self.num_of(e))
            else:
                var args = List[Int]()
                args.append(e)
                return self.ex_call(ET_NUMBER, "MATH NEGATE", args)
        else:
            return self.parse_atomic_expression()

    def parse_atomic_expression(mut self) raises -> Int:
        if self.s.next_is_special("("):
            self.s.get_sym()
            var e = self.parse_expression()
            self.parse_special(")")
            return e
        elif self.s.next_type == SYM_STRING:
            var val = self.s.next_content
            if val.byte_length() > 251:
                self.s.throw_parse_error("Text is longer than 251 letters")
            self.s.get_sym()
            return self.ex_atomic(ET_TEXT, "'" + escape_string_lit(val) + "'")
        elif self.s.next_type == SYM_NUMBER:
            var parsed = try_parse_float(self.s.next_content)
            if not parsed.has:
                self.s.throw_parse_error(
                    "Can not decode number: " + self.s.next_content
                )
            var val = parsed.value
            self.s.get_sym()
            return self.ex_number(val)
        elif self.s.next_type == SYM_ID:
            var var_or_object = self.parse_id()

            if self.s.next_is_special("."):
                self.s.push_back(SYM_ID, var_or_object)
                return self.parse_function_call_or_property()
            elif self.s.next_is_special("["):
                # ссылка на массив
                var varname = "V" + var_or_object
                if not self.has_variable(varname):
                    self.s.throw_parse_error(
                        "can not use array "
                        + var_or_object
                        + " before first assignment"
                    )
                var atype = ET_VOID
                var vt = self.variable_type(varname)
                if vt == ET_NUMBER_ARRAY:
                    atype = ET_NUMBER
                elif vt == ET_TEXT_ARRAY:
                    atype = ET_TEXT
                else:
                    self.s.throw_parse_error("Need array to use with '[]'")

                self.parse_special("[")
                var e = self.parse_float_expression(
                    "only numbers are allowed as array index"
                )
                self.parse_special("]")

                if atype == ET_TEXT:
                    var args = List[Int]()
                    args.append(e)
                    return self.ex_call(
                        ET_TEXT, "CALL ARRAYGET_STRING :0 :1 " + varname, args
                    )
                else:
                    if self.noboundscheck:
                        return self.ex_unsafe_array(varname, e)
                    else:
                        var args = List[Int]()
                        args.append(e)
                        return self.ex_call(
                            ET_NUMBER, "CALL ARRAYGET_FLOAT :0 :1 " + varname, args
                        )
            else:
                # использование переменной
                var varname = "V" + var_or_object
                if not self.has_variable(varname):
                    self.s.throw_parse_error(
                        "can not use variable "
                        + var_or_object
                        + " before first assignment"
                    )
                return self.ex_atomic(self.variable_type(varname), varname)
        else:
            self.s.throw_unexpected_symbol()
            return self.ex_number(0.0)

    def parse_function_call_or_property(mut self) raises -> Int:
        var list = List[Int]()
        var objectname = self.parse_id()
        self.parse_special(".")
        var elementname = self.parse_id()

        var cmdname = objectname + "." + elementname

        # F.GET
        if cmdname == "F.GET":
            self.parse_special("(")
            var name = to_upper_ascii(self.parse_string())
            self.parse_optional_special(",")
            self.parse_special(")")
            var cf = self.functiondefs[self.currentfunction].copy()
            var vidx = cf.find_parameter(name)
            if vidx < 0:
                self.s.throw_parse_error("Undefined local variable: " + name)
            var t = cf.parameter_type(vidx)
            return self.ex_atomic(t, cf.parameter_variable(vidx))

        # любой F.CALL как выражение
        if cmdname.startswith("F.CALL"):
            self.parse_special("(")
            var fname = to_upper_ascii(self.parse_string())
            if not (fname in self.fdef_index):
                self.s.throw_parse_error("Undefined function: " + fname)
            var fd = self.functiondefs[self.fdef_index[fname]].copy()

            self.parse_optional_special(",")
            while not self.s.next_is_special(")"):
                if len(list) >= fd.parameter_number():
                    self.s.throw_parse_error(
                        "Too many arguments for function: " + fname
                    )
                var e = self.parse_typed_expression_with_parameterconversion(
                    fd.parameter_type(len(list))
                )
                list.append(e)
                self.parse_optional_special(",")
            self.parse_special(")")

            return self.ex_function(self.fdef_index[fname], fd.get_return_type(), list)

        if not (cmdname in self.library):
            self.s.throw_parse_error("Undefined command or property: " + cmdname)

        var le = self.lib_entries[self.library[cmdname]].copy()
        if le.return_type == ET_VOID:
            self.s.throw_parse_error(
                "Can not use command that returns nothing in an expression"
            )

        if self.s.next_is_special("("):
            # вызов метода
            self.parse_special("(")

            while len(list) < len(le.param_types):
                var e = self.parse_typed_expression_with_parameterconversion(
                    le.param_types[len(list)]
                )
                list.append(e)
                self.parse_optional_special(",")
            self.parse_special(")")

            if len(list) < len(le.param_types):
                self.s.throw_parse_error("Too few arguments to " + cmdname)
        else:
            # свойство
            if len(le.param_types) != 0:
                self.s.throw_parse_error(
                    "Can not reference " + cmdname + " as a property"
                )

        var callname = String("CALL ")
        if le.inline:
            callname = le.program_code
        else:
            callname = "CALL " + cmdname
        return self.ex_call(le.return_type, callname, list)

    # --- базовые разборщики (Compiler.cs:1635-1699) -------------------------

    def parse_id(mut self) raises -> String:
        if self.s.next_type != SYM_ID:
            self.s.throw_expected_symbol(SYM_ID, "")
        var id = self.s.next_content
        self.s.get_sym()
        return id

    def parse_id_expected(mut self, expected: String) raises:
        var id = self.parse_id()
        if id != expected:
            self.s.throw_expected_symbol(SYM_ID, expected)

    def parse_keyword(mut self, k: String) raises:
        if not self.s.next_is_keyword(k):
            self.s.throw_expected_symbol(SYM_KEYWORD, k)
        self.s.get_sym()

    def parse_special(mut self, k: String) raises:
        if not self.s.next_is_special(k):
            self.s.throw_expected_symbol(SYM_SPECIAL, k)
        self.s.get_sym()

    def parse_optional_special(mut self, x: String) raises:
        if self.s.next_is_special(x):
            self.parse_special(x)

    def parse_string(mut self) raises -> String:
        if self.s.next_type != SYM_STRING:
            self.s.throw_expected_symbol(SYM_STRING, "")
        var st = self.s.next_content
        self.s.get_sym()
        return st

    def parse_eol(mut self) raises:
        if self.s.next_type != SYM_EOL:
            self.s.throw_expected_symbol(SYM_EOL, "")
        self.s.get_sym()

    # ======================= первый проход ==================================

    def extractfinfo_sub(mut self) raises:
        self.parse_keyword("SUB")
        var subname = self.parse_id()

        if subname in self.scs_map:
            self.s.throw_parse_error("Redefined Sub " + subname)

        self.scs_keys.append(subname)
        var lsub = List[String]()
        lsub.append(subname)
        self.scs_map[subname] = lsub^

        self.parse_eol()
        while not self.s.next_is_keyword("ENDSUB"):
            self.extractfinfo_statement(subname)
        self.parse_keyword("ENDSUB")
        self.parse_eol()

    def extractfinfo_statement(mut self, currentsub: String) raises:
        if self.s.next_type == SYM_PRAGMA or self.s.next_type == SYM_EOL:
            self.s.get_sym()
        elif self.s.next_is_keyword("IF"):
            self.parse_keyword("IF")
            self.extractfinfo_expression(currentsub)
            self.parse_keyword("THEN")
            self.parse_eol()
            while True:
                if self.s.next_is_keyword("ELSEIF"):
                    self.parse_keyword("ELSEIF")
                    self.extractfinfo_expression(currentsub)
                    self.parse_keyword("THEN")
                    self.parse_eol()
                elif self.s.next_is_keyword("ELSE"):
                    self.parse_keyword("ELSE")
                    self.parse_eol()
                    while not self.s.next_is_keyword("ENDIF"):
                        self.extractfinfo_statement(currentsub)
                    break
                elif self.s.next_is_keyword("ENDIF"):
                    break
                else:
                    self.extractfinfo_statement(currentsub)
            self.parse_keyword("ENDIF")
            self.parse_eol()
        elif self.s.next_is_keyword("WHILE"):
            self.parse_keyword("WHILE")
            self.extractfinfo_expression(currentsub)
            self.parse_eol()
            while not self.s.next_is_keyword("ENDWHILE"):
                self.extractfinfo_statement(currentsub)
            self.parse_keyword("ENDWHILE")
            self.parse_eol()
        elif self.s.next_is_keyword("FOR"):
            self.parse_keyword("FOR")
            _ = self.parse_id()
            self.parse_special("=")
            self.extractfinfo_expression(currentsub)
            self.parse_keyword("TO")
            self.extractfinfo_expression(currentsub)
            if self.s.next_is_keyword("STEP"):
                self.parse_keyword("STEP")
                self.extractfinfo_expression(currentsub)
            self.parse_eol()
            while not self.s.next_is_keyword("ENDFOR"):
                self.extractfinfo_statement(currentsub)
            self.parse_keyword("ENDFOR")
            self.parse_eol()
        elif self.s.next_is_keyword("GOTO"):
            self.parse_keyword("GOTO")
            if self.s.next_type != SYM_ID:
                self.s.throw_expected_symbol(SYM_ID, "")
            self.s.get_sym()
            self.parse_eol()
        else:
            # атомарный оператор
            if self.s.next_type != SYM_ID:
                self.s.throw_expected_symbol(SYM_ID, "")
            var id = self.s.next_content

            self.s.get_sym()

            if self.s.next_is_special("="):
                # присваивание переменной
                self.parse_special("=")
                self.extractfinfo_expression(currentsub)
            elif self.s.next_is_special("["):
                # присваивание элементу массива
                self.parse_special("[")
                self.extractfinfo_expression(currentsub)
                self.parse_special("]")
                self.parse_special("=")
                self.extractfinfo_expression(currentsub)
            elif self.s.next_is_special("."):
                # свойство или вызов библиотеки
                self.parse_special(".")
                var elementname = self.parse_id()
                if self.s.next_is_special("="):
                    self.parse_special("=")
                    # объявление функции
                    if id == "F" and elementname == "START":
                        var subname = self.parse_id()
                        self.parse_eol()
                        self.parse_id_expected("F")
                        self.parse_special(".")
                        self.parse_id_expected("FUNCTION")
                        self.parse_special("(")
                        var fname = to_upper_ascii(self.parse_string())
                        self.parse_optional_special(",")
                        var pardcl = self.parse_string()
                        self.parse_optional_special(",")

                        self.parse_special(")")
                        if fname in self.fdef_index:
                            self.s.throw_parse_error(
                                "Double function definition: " + fname
                            )
                        var fd = funcdef_make(fname, subname, pardcl)
                        self.functiondefs.append(fd^)
                        self.fdef_index[fname] = len(self.functiondefs) - 1
                    else:
                        self.extractfinfo_expression(currentsub)
                else:
                    self.parse_special("(")
                    # F.RETURN определяет тип возврата
                    if id == "F" and elementname.startswith("RETURN"):
                        var rt = ET_VOID
                        if elementname == "RETURNNUMBER":
                            rt = ET_NUMBER
                        elif elementname == "RETURNTEXT":
                            rt = ET_TEXT
                        if (
                            currentsub in self.rts_map
                            and self.rts_map[currentsub] != rt
                        ):
                            self.s.throw_parse_error(
                                "Mismatching returns in: " + currentsub
                            )
                        self.rts_map[currentsub] = rt
                    elif id == "F" and elementname.startswith("CALL"):
                        var calledfn = to_upper_ascii(self.parse_string())
                        self.parse_optional_special(",")
                        self.fcs_add(currentsub, calledfn)
                    while not self.s.next_is_special(")"):
                        self.extractfinfo_expression(currentsub)
                        self.parse_optional_special(",")
                    self.parse_special(")")
            elif self.s.next_is_special("("):
                # вызов подпрограммы
                self.parse_special("(")
                self.parse_special(")")

                # запоминаем связь между подпрограммами
                self.scs_add(currentsub, id)
            elif self.s.next_is_special(":"):
                # метка
                self.parse_special(":")
            else:
                self.s.throw_unexpected_symbol()

            self.parse_eol()

    def fcs_add(mut self, sub: String, fnname: String) raises:
        """Добавить вызов функции в functioncallstructure[sub]."""
        if not (sub in self.fcs_map):
            self.fcs_keys.append(sub)
            self.fcs_map[sub] = List[String]()
        var fns = self.fcs_map[sub].copy()
        for i in range(len(fns)):
            if fns[i] == fnname:
                return
        fns.append(fnname)
        self.fcs_map[sub] = fns^^

    def scs_add(mut self, sub: String, callee: String) raises:
        """Добавить вызов sub в subcallstructure[sub]."""
        if not (sub in self.scs_map):
            self.scs_keys.append(sub)
            self.scs_map[sub] = List[String]()
        var callees = self.scs_map[sub].copy()
        for i in range(len(callees)):
            if callees[i] == callee:
                return
        callees.append(callee)
        self.scs_map[sub] = callees^^

    def extractfinfo_expression(mut self, currentsub: String) raises:
        while True:
            self.extractfinfo_unary_minus_expression(currentsub)

            if self.s.next_is_keyword("OR") or self.s.next_is_keyword("AND") or (
                self.s.next_type == SYM_SPECIAL
                and (
                    self.s.next_content == "="
                    or self.s.next_content == "<>"
                    or self.s.next_content == "<"
                    or self.s.next_content == ">"
                    or self.s.next_content == "<="
                    or self.s.next_content == ">="
                    or self.s.next_content == "+"
                    or self.s.next_content == "-"
                    or self.s.next_content == "*"
                    or self.s.next_content == "/"
                )
            ):
                self.s.get_sym()
            else:
                break

    def extractfinfo_unary_minus_expression(mut self, currentsub: String) raises:
        while self.s.next_is_special("-"):
            self.parse_special("-")
        self.extractfinfo_atomic_expression(currentsub)

    def extractfinfo_atomic_expression(mut self, currentsub: String) raises:
        if self.s.next_is_special("("):
            self.parse_special("(")
            self.extractfinfo_expression(currentsub)
            self.parse_special(")")
        elif self.s.next_type == SYM_STRING or self.s.next_type == SYM_NUMBER:
            self.s.get_sym()
        elif self.s.next_type == SYM_ID:
            var var_or_object = self.parse_id()
            if self.s.next_is_special("."):
                # свойство или функция объекта
                self.parse_special(".")
                var f_or_property = self.parse_id()
                if self.s.next_is_special("("):
                    # вызов функции
                    self.parse_special("(")

                    # обработка F.Call
                    if var_or_object == "F" and f_or_property.startswith("CALL"):
                        var id = to_upper_ascii(self.parse_string())
                        self.parse_optional_special(",")
                        self.fcs_add(currentsub, id)

                    # потребляем остальные параметры
                    while not self.s.next_is_special(")"):
                        self.extractfinfo_expression(currentsub)
                        self.parse_optional_special(",")
                    self.parse_special(")")
                else:
                    # свойство
                    _ = f_or_property
            elif self.s.next_is_special("["):
                # ссылка на массив
                self.parse_special("[")
                self.extractfinfo_expression(currentsub)
                self.parse_special("]")
            else:
                # использование переменной
                _ = var_or_object
        else:
            self.s.throw_unexpected_symbol()


# ============================================================================
# Вспомогательные функции и точка входа
# ============================================================================


def _hexval(c: UInt8) -> Int:
    if 48 <= Int(c) <= 57:
        return Int(c) - 48
    if 65 <= Int(c) <= 70:
        return Int(c) - 55
    if 97 <= Int(c) <= 102:
        return Int(c) - 87
    return 0


def inject_placeholders(mut par: List[String], fmt_in: String, expansion: Int) -> String:
    """CallExpression.InjectPlaceholders (Expression.cs:267-311).

    Использованные аргументы помечаются пустой строкой (в C# — null) и не
    дописываются в конец.
    """
    var format = fmt_in
    var uses = List[Int]()
    var cursor = 0
    while cursor < format.byte_length():
        var idx = format.find(":", cursor)
        if idx < 0:
            break
        if idx + 1 < format.byte_length():
            var nxt = _byte_at(format, idx + 1)
            if nxt == 35:  # '#'
                var strn = String(expansion)
                format = (
                    String(_sub_bytes(format, 0, idx))
                    + strn
                    + String(_sub_bytes(format, idx + 2, format.byte_length()))
                )
                cursor = cursor + strn.byte_length()
                continue
            elif 48 <= Int(nxt) <= 57:
                var pnum = Int(nxt) - 48
                var val = par[pnum]
                format = (
                    String(_sub_bytes(format, 0, idx))
                    + val
                    + String(_sub_bytes(format, idx + 2, format.byte_length()))
                )
                cursor = cursor + val.byte_length()
                uses.append(pnum)
                continue
        cursor = idx + 1
    for i in range(len(uses)):
        par[uses[i]] = ""
    return format


def compile_source_lines(lines: List[String]) raises -> String:
    """Точка входа: строки развёрнутого ~Name.bp → текст .lmsb."""
    var c = Compiler()
    return c.compile_program(lines)
