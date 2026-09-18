"""Минимальный JSON для LSP-сервера Basic Plus.

Парсинг значений object/array/string/number/true/false/null (включая
escapes \\uXXXX с суррогатными парами) и сериализация. Достаточно для
сообщений JSON-RPC протокола LSP 3.17.

Модель: арена узлов (рекурсивные struct'ы вида List[Self] в Mojo
не собираются, поэтому дети связываются индексами first-child /
next-sibling). Парсер — рекурсивный спуск, глубина сообщений LSP мала.
"""

# ============================================================================
# Виды узлов
# ============================================================================

comptime JK_NULL = 0
comptime JK_BOOL = 1
comptime JK_NUM = 2
comptime JK_STR = 3
comptime JK_ARR = 4
comptime JK_OBJ = 5


@fieldwise_init
struct JNode(Copyable, Movable):
    """Узел арены.

    kind — JK_*; raw — STR: декодированный текст, NUM: литерал как в
    исходнике (для точного эха id), BOOL: "true"/"false", иначе "";
    key — имя члена объекта (декодированное), "" для элементов массива;
    kid — первый ребёнок или -1; sib — следующий сосед или -1.
    """

    var kind: Int
    var raw: String
    var key: String
    var kid: Int
    var sib: Int


struct JDoc(Copyable, Movable):
    """Распарсенный документ: арена + индекс корня."""

    var nodes: List[JNode]
    var root: Int

    def __init__(out self):
        self.nodes = List[JNode]()
        self.root = -1

    def add(mut self, kind: Int, raw: String, key: String) -> Int:
        var i = len(self.nodes)
        self.nodes.append(JNode(kind, raw, key, -1, -1))
        return i


# ============================================================================
# Байтовые помощники (UTF-8 собирается вручную, как в bp.lexer)
# ============================================================================


def _jbyte_at(s: String, i: Int) -> UInt8:
    return s.unsafe_ptr().unsafe_offset(i)[]


def _jbytes_to_string(raw: List[UInt8]) -> String:
    if len(raw) == 0:
        return String("")
    var span = Span(unsafe_ptr=raw.unsafe_ptr(), length=len(raw))
    return String(StringSlice(unsafe_from_utf8=span))


def _jsub_bytes(s: String, start: Int, end: Int) -> String:
    var raw = List[UInt8]()
    for i in range(start, end):
        raw.append(_jbyte_at(s, i))
    return _jbytes_to_string(raw^)


def _is_hex(b: UInt8) -> Bool:
    var c = Int(b)
    return (
        (48 <= c and c <= 57) or (65 <= c and c <= 70) or (97 <= c and c <= 102)
    )


def _hex_val(b: UInt8) -> Int:
    var c = Int(b)
    if 48 <= c and c <= 57:
        return c - 48
    if 65 <= c and c <= 70:
        return c - 55
    return c - 87


def _append_utf8(mut out: List[UInt8], cp_in: Int):
    """Закодировать кодпоинт в UTF-8."""
    var cp = cp_in
    if cp < 0:
        cp = 0xFFFD
    if cp < 0x80:
        out.append(UInt8(cp))
    elif cp < 0x800:
        out.append(UInt8(0xC0 | (cp >> 6)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
    elif cp < 0x10000:
        out.append(UInt8(0xE0 | (cp >> 12)))
        out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
    elif cp < 0x110000:
        out.append(UInt8(0xF0 | (cp >> 18)))
        out.append(UInt8(0x80 | ((cp >> 12) & 0x3F)))
        out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
    else:
        out.append(UInt8(0xEF))
        out.append(UInt8(0xBF))
        out.append(UInt8(0xBD))


# ============================================================================
# Парсер
# ============================================================================


struct JParser(Copyable, Movable):
    var text: String
    var pos: Int

    def __init__(out self, t: String):
        self.text = t
        self.pos = 0

    def eof(self) -> Bool:
        return self.pos >= self.text.byte_length()

    def peek(mut self) raises -> UInt8:
        if self.eof():
            raise Error("json: неожиданный конец ввода")
        return _jbyte_at(self.text, self.pos)

    def expect(mut self, want: UInt8) raises:
        var got = self.peek()
        if Int(got) != Int(want):
            raise Error("json: ожидался другой символ")
        self.pos += 1

    def skip_ws(mut self):
        while not self.eof():
            var c = Int(_jbyte_at(self.text, self.pos))
            if c == 32 or c == 9 or c == 10 or c == 13:
                self.pos += 1
            else:
                break

    def expect_word(mut self, word: String) raises:
        for i in range(word.byte_length()):
            self.expect(_jbyte_at(word, i))

    def read_hex4(mut self) raises -> Int:
        var cp = 0
        for _ in range(4):
            var b = self.peek()
            if not _is_hex(b):
                raise Error("json: неверный \\u escape")
            cp = cp * 16 + _hex_val(b)
            self.pos += 1
        return cp


def _parse_string(mut p: JParser, mut doc: JDoc, key: String) raises -> Int:
    """Текущая позиция — на открывающей кавычке. Возвращает узел STR."""
    p.expect(34)  # "
    var out = List[UInt8]()
    while True:
        var b = p.peek()
        var c = Int(b)
        if c == 34:  # закрывающая кавычка
            p.pos += 1
            break
        if c == 92:  # backslash
            p.pos += 1
            var e = p.peek()
            var ec = Int(e)
            if ec == 34:
                out.append(UInt8(34))
                p.pos += 1
            elif ec == 92:
                out.append(UInt8(92))
                p.pos += 1
            elif ec == 47:
                out.append(UInt8(47))
                p.pos += 1
            elif ec == 98:
                out.append(UInt8(8))
                p.pos += 1
            elif ec == 102:
                out.append(UInt8(12))
                p.pos += 1
            elif ec == 110:
                out.append(UInt8(10))
                p.pos += 1
            elif ec == 114:
                out.append(UInt8(13))
                p.pos += 1
            elif ec == 116:
                out.append(UInt8(9))
                p.pos += 1
            elif ec == 117:
                p.pos += 1
                var cp = p.read_hex4()
                if 0xD800 <= cp and cp <= 0xDBFF:
                    # старшая половина пары: ждём \uDC00..\uDFFF
                    if not p.eof() and Int(_jbyte_at(p.text, p.pos)) == 92:
                        var save = p.pos
                        p.pos += 1
                        if not p.eof() and Int(_jbyte_at(p.text, p.pos)) == 117:
                            p.pos += 1
                            var lo = p.read_hex4()
                            if 0xDC00 <= lo and lo <= 0xDFFF:
                                cp = (
                                    0x10000
                                    + ((cp - 0xD800) << 10)
                                    + (lo - 0xDC00)
                                )
                            else:
                                cp = 0xFFFD
                        else:
                            p.pos = save
                            cp = 0xFFFD
                    else:
                        cp = 0xFFFD
                elif 0xDC00 <= cp and cp <= 0xDFFF:
                    cp = 0xFFFD
                _append_utf8(out, cp)
            else:
                raise Error("json: неверный escape")
        elif c < 0x20:
            raise Error("json: управляющий символ в строке")
        else:
            out.append(b)
            p.pos += 1
    return doc.add(JK_STR, _jbytes_to_string(out^), key)


def _parse_number(mut p: JParser, mut doc: JDoc, key: String) raises -> Int:
    var start = p.pos
    if not p.eof() and Int(_jbyte_at(p.text, p.pos)) == 45:  # -
        p.pos += 1
    var digits = 0
    while not p.eof():
        var c = Int(_jbyte_at(p.text, p.pos))
        if 48 <= c and c <= 57:
            digits += 1
            p.pos += 1
        else:
            break
    if digits == 0:
        raise Error("json: неверное число")
    if not p.eof() and Int(_jbyte_at(p.text, p.pos)) == 46:  # .
        p.pos += 1
        var frac = 0
        while not p.eof():
            var c = Int(_jbyte_at(p.text, p.pos))
            if 48 <= c and c <= 57:
                frac += 1
                p.pos += 1
            else:
                break
        if frac == 0:
            raise Error("json: неверное число")
    if not p.eof():
        var c = Int(_jbyte_at(p.text, p.pos))
        if c == 101 or c == 69:  # e E
            p.pos += 1
            if not p.eof():
                var s = Int(_jbyte_at(p.text, p.pos))
                if s == 43 or s == 45:
                    p.pos += 1
            var ed = 0
            while not p.eof():
                var cc = Int(_jbyte_at(p.text, p.pos))
                if 48 <= cc and cc <= 57:
                    ed += 1
                    p.pos += 1
                else:
                    break
            if ed == 0:
                raise Error("json: неверное число")
    return doc.add(JK_NUM, _jsub_bytes(p.text, start, p.pos), key)


def _parse_value(mut p: JParser, mut doc: JDoc, key: String) raises -> Int:
    var b = p.peek()
    var c = Int(b)
    if c == 123:  # {
        return _parse_object(p, doc, key)
    if c == 91:  # [
        return _parse_array(p, doc, key)
    if c == 34:  # "
        return _parse_string(p, doc, key)
    if c == 116:  # true
        p.expect_word("true")
        return doc.add(JK_BOOL, "true", key)
    if c == 102:  # false
        p.expect_word("false")
        return doc.add(JK_BOOL, "false", key)
    if c == 110:  # null
        p.expect_word("null")
        return doc.add(JK_NULL, "", key)
    if c == 45 or (48 <= c and c <= 57):
        return _parse_number(p, doc, key)
    raise Error("json: неверное значение")


def _link_child(mut doc: JDoc, parent: Int, child: Int):
    if doc.nodes[parent].kid == -1:
        doc.nodes[parent].kid = child
    else:
        var s = doc.nodes[parent].kid
        while doc.nodes[s].sib != -1:
            s = doc.nodes[s].sib
        doc.nodes[s].sib = child


def _parse_object(mut p: JParser, mut doc: JDoc, key: String) raises -> Int:
    p.expect(123)  # {
    var obj = doc.add(JK_OBJ, "", key)
    p.skip_ws()
    if not p.eof() and Int(_jbyte_at(p.text, p.pos)) == 125:  # }
        p.pos += 1
        return obj
    while True:
        p.skip_ws()
        if p.eof() or Int(_jbyte_at(p.text, p.pos)) != 34:
            raise Error("json: в объекте ожидалась строка-ключ")
        var ks = p.pos
        # ключ парсим как строку, но забираем только текст (узел выкидываем)
        var tmp = _parse_string(p, doc, "")
        var k = doc.nodes[tmp].raw
        _ = doc.nodes.pop()
        p.skip_ws()
        p.expect(58)  # :
        p.skip_ws()
        var v = _parse_value(p, doc, k)
        _link_child(doc, obj, v)
        _ = ks
        p.skip_ws()
        var b = p.peek()
        if Int(b) == 44:  # ,
            p.pos += 1
        elif Int(b) == 125:  # }
            p.pos += 1
            break
        else:
            raise Error("json: в объекте ожидались , или }")
    return obj


def _parse_array(mut p: JParser, mut doc: JDoc, key: String) raises -> Int:
    p.expect(91)  # [
    var arr = doc.add(JK_ARR, "", key)
    p.skip_ws()
    if not p.eof() and Int(_jbyte_at(p.text, p.pos)) == 93:  # ]
        p.pos += 1
        return arr
    while True:
        p.skip_ws()
        var v = _parse_value(p, doc, "")
        _link_child(doc, arr, v)
        p.skip_ws()
        var b = p.peek()
        if Int(b) == 44:  # ,
            p.pos += 1
        elif Int(b) == 93:  # ]
            p.pos += 1
            break
        else:
            raise Error("json: в массиве ожидались , или ]")
    return arr


def json_parse(text: String) raises -> JDoc:
    """Распарсить JSON-значение целиком (вокруг — только пробелы)."""
    var doc = JDoc()
    var p = JParser(text)
    p.skip_ws()
    var r = _parse_value(p, doc, "")
    doc.root = r
    p.skip_ws()
    if not p.eof():
        raise Error("json: мусор после значения")
    return doc^


# ============================================================================
# Навигация
# ============================================================================


def jkind(doc: JDoc, i: Int) -> Int:
    if i < 0 or i >= len(doc.nodes):
        return -1
    return doc.nodes[i].kind


def jstr(doc: JDoc, i: Int) -> String:
    """Текстовое значение узла (STR — декодированное, NUM/BOOL — литерал)."""
    if i < 0 or i >= len(doc.nodes):
        return String("")
    return doc.nodes[i].raw


def jobject_get(doc: JDoc, obj: Int, key: String) -> Int:
    """Индекс члена объекта или -1."""
    if obj < 0 or obj >= len(doc.nodes):
        return -1
    if doc.nodes[obj].kind != JK_OBJ:
        return -1
    var c = doc.nodes[obj].kid
    while c != -1:
        if doc.nodes[c].key == key:
            return c
        c = doc.nodes[c].sib
    return -1


def jarray_len(doc: JDoc, arr: Int) -> Int:
    if arr < 0 or arr >= len(doc.nodes):
        return 0
    if doc.nodes[arr].kind != JK_ARR:
        return 0
    var n = 0
    var c = doc.nodes[arr].kid
    while c != -1:
        n += 1
        c = doc.nodes[c].sib
    return n


def jarray_at(doc: JDoc, arr: Int, n: Int) -> Int:
    """Индекс n-го элемента массива или -1."""
    if arr < 0 or arr >= len(doc.nodes):
        return -1
    if doc.nodes[arr].kind != JK_ARR:
        return -1
    var c = doc.nodes[arr].kid
    var i = 0
    while c != -1:
        if i == n:
            return c
        i += 1
        c = doc.nodes[c].sib
    return -1


def jint(doc: JDoc, i: Int) raises -> Int:
    """Целое из NUM-узла (знак + цифры; хвост .eE отбрасывается)."""
    if i < 0 or i >= len(doc.nodes):
        raise Error("json: нет узла")
    var s = doc.nodes[i].raw
    var neg = False
    var p = 0
    var n = s.byte_length()
    if n > 0 and Int(_jbyte_at(s, 0)) == 45:
        neg = True
        p = 1
    var v = 0
    var any = False
    while p < n:
        var c = Int(_jbyte_at(s, p))
        if 48 <= c and c <= 57:
            v = v * 10 + (c - 48)
            any = True
            p += 1
        else:
            break
    if not any:
        raise Error("json: не целое число")
    if neg:
        return -v
    return v


# ============================================================================
# Сериализация
# ============================================================================


def _escape_hex(v: Int) -> String:
    var out = String("")
    var x = v
    for _ in range(4):
        var d = x & 15
        var ch = 48 + d
        if d >= 10:
            ch = 87 + d
        out = String(chr(ch)) + out
        x = x >> 4
    return out


def _esc_byte(mut out: List[UInt8], b: Int):
    out.append(UInt8(b))


def _esc_text(mut out: List[UInt8], t: String):
    for i in range(t.byte_length()):
        out.append(_jbyte_at(t, i))


def json_escape(s: String) -> String:
    """Экранировать строку для JSON (UTF-8 проходит как есть).

    Собирается побайтово: String(chr(b)) для b >= 0x80 дал бы двухбайтовую
    кодировку кодпоинта U+00Bx вместо сырого байта, поэтому только append.
    """
    var out = List[UInt8]()
    var n = s.byte_length()
    var i = 0
    while i < n:
        var b = Int(_jbyte_at(s, i))
        if b == 34:  # "
            _esc_text(out, "\\\"")
            i += 1
        elif b == 92:  # \
            _esc_text(out, "\\\\")
            i += 1
        elif b == 8:
            _esc_text(out, "\\b")
            i += 1
        elif b == 12:
            _esc_text(out, "\\f")
            i += 1
        elif b == 10:
            _esc_text(out, "\\n")
            i += 1
        elif b == 13:
            _esc_text(out, "\\r")
            i += 1
        elif b == 9:
            _esc_text(out, "\\t")
            i += 1
        elif b < 0x20:
            _esc_text(out, "\\u")
            _esc_text(out, _escape_hex(b))
            i += 1
        elif b < 0x80:
            _esc_byte(out, b)
            i += 1
        else:
            # многобайтовая последовательность — скопировать сырые байты
            var ln = 1
            if (b & 0xE0) == 0xC0:
                ln = 2
            elif (b & 0xF0) == 0xE0:
                ln = 3
            elif (b & 0xF8) == 0xF0:
                ln = 4
            if i + ln > n:
                ln = n - i
            var k = 0
            while k < ln:
                _esc_byte(out, Int(_jbyte_at(s, i + k)))
                k += 1
            i += ln
    return _jbytes_to_string(out^)


def json_quote(s: String) -> String:
    return String('"') + json_escape(s) + String('"')


def json_dump(doc: JDoc, i: Int) -> String:
    """Сериализовать узел (рекурсия по индексам, глубина мала)."""
    if i < 0 or i >= len(doc.nodes):
        return String("null")
    var nd = doc.nodes[i].copy()
    if nd.kind == JK_NULL:
        return String("null")
    if nd.kind == JK_BOOL:
        return nd.raw
    if nd.kind == JK_NUM:
        return nd.raw
    if nd.kind == JK_STR:
        return json_quote(nd.raw)
    if nd.kind == JK_ARR:
        var out = String("[")
        var c = nd.kid
        var first = True
        while c != -1:
            if not first:
                out += ","
            first = False
            out += json_dump(doc, c)
            c = doc.nodes[c].sib
        out += "]"
        return out
    # JK_OBJ
    var out = String("{")
    var c = nd.kid
    var first = True
    while c != -1:
        if not first:
            out += ","
        first = False
        out += json_quote(doc.nodes[c].key) + ":" + json_dump(doc, c)
        c = doc.nodes[c].sib
    out += "}"
    return out
