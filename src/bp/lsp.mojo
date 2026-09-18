"""LSP-сервер языка Basic Plus (протокол LSP 3.17 поверх stdio).

Точка входа: `def cmd_lsp() raises -> Int` (см. сигнатуру для main.mojo
в конце файла). Транспорт — заголовки Content-Length + JSON-RPC 2.0.
Весь ввод читается из stdin, ответы пишутся строго в stdout, логи — в stderr
(в stdout не попадает ничего, кроме фреймов ответов/уведомлений).

Обязательные методы:
  initialize -> capabilities {textDocumentSync=Full, hoverProvider,
    completionProvider}; initialized — noop; shutdown/exit;
  textDocument/didOpen + textDocument/didChange — тексты хранятся in-memory,
    после каждого изменения документ пересчитывается и рассылается
    textDocument/publishDiagnostics.

Диагностики строятся реальным конвейером стадий 1-2 БЕЗ модификации чужих
модулей: текст документа пишется во временный файл, затем build_line
(лексер) по каждой строке + run_expansion (препроцессор/линковка/
интерпретация). Позиция модели (docs/05 §2.1: пара (файл, 1-based строка),
колонок нет) маппится в LSP-range как (строка-1, колонка 0); severity=1
(Error); конвейер останавливается на первой ошибке, поэтому диагностик
за прогон — не более одной.

hover возвращает короткий текст для builtin-классов (docs/03);
completion — KEYWORDS + BUILTIN_CLASSES из grammar/grammar.js.
Неизвестный метод с id — ответ result:null; неизвестное уведомление — молча.
"""

from std.python import Python, PythonObject
from std.os import mkdir
from bp.json import (
    JDoc,
    JK_ARR,
    JK_NUM,
    JK_OBJ,
    JK_STR,
    jarray_at,
    jarray_len,
    jint,
    jobject_get,
    json_parse,
    json_quote,
    jstr,
)
from bp.lexer import _byte_at, build_line
from bp.compiler3 import compile_source_lines
from bp.expand import Ctx, run_expansion
from bp.util import text_to_lines, write_text


comptime LSP_TMP_DIR = "/tmp/bp_lsp_docs"

# KEYWORDS (30) и BUILTIN_CLASSES (31) — дословно из grammar/grammar.js.
comptime LSP_KEYWORDS = (
    "for endfor if then endif else elseif while endwhile and or sub endsub "
    "goto step to import include folder in out function endfunction number "
    "number[] string string[] private break continue return "
)
comptime LSP_CLASSES = (
    "assert buttons byte ev3file ev3 lcd mailbox math motorab motorac motorad "
    "motorbc motorbd motorcd motora motorb motorc motord motor program row "
    "sensor1 sensor2 sensor3 sensor4 sensor speaker text thread time vector "
)


# ============================================================================
# Транспорт stdio (бинарный, через Python interop)
# ============================================================================


struct LspIo(Copyable, Movable):
    """Бинарные stdin/stdout + текстовый stderr."""

    var inp: PythonObject
    var out: PythonObject
    var err: PythonObject

    def __init__(out self) raises:
        var sys = Python.import_module("sys")
        self.inp = sys.stdin.buffer
        self.out = sys.stdout.buffer
        self.err = sys.stderr

    def log(mut self, s: String):
        """Лог в stderr. Никогда не падает (вызывается из except-веток)."""
        try:
            _ = self.err.write(s + "\n")
            _ = self.err.flush()
        except:
            pass

    def read_line(mut self) raises -> String:
        """Одна строка заголовка (без \\r\\n). Пустые байты = EOF."""
        var raw = self.inp.readline()
        if Int(raw.__len__()) == 0:
            raise Error("lsp: eof")
        var s = String(raw.decode("utf-8", "replace"))
        var n = s.byte_length()
        while n > 0:
            var c = Int(s.unsafe_ptr().unsafe_offset(n - 1)[])
            if c == 10 or c == 13:
                n -= 1
            else:
                break
        return String(s[byte=0:n])

    def read_exact(mut self, n: Int) raises -> String:
        """Ровно n байт тела (UTF-8). Пустое чтение = EOF."""
        var data = self.inp.read(0)
        var got = 0
        while got < n:
            var chunk = self.inp.read(n - got)
            if Int(chunk.__len__()) == 0:
                raise Error("lsp: eof")
            data = data + chunk
            got = Int(data.__len__())
        return String(data.decode("utf-8", "replace"))

    def write_msg(mut self, body: String) raises:
        """Фрейм Content-Length + тело в stdout (байтовая длина!)."""
        var bb = PythonObject(body).encode("utf-8")
        var n = Int(bb.__len__())
        var hb = PythonObject(
            "Content-Length: " + String(n) + "\r\n\r\n"
        ).encode("utf-8")
        _ = self.out.write(hb + bb)
        _ = self.out.flush()


def _parse_header_int(s: String) -> Int:
    """Ручной разбор неотрицательного целого; -1 при неудаче."""
    var v = 0
    var any = False
    for i in range(s.byte_length()):
        var c = Int(s.unsafe_ptr().unsafe_offset(i)[])
        if 48 <= c and c <= 57:
            v = v * 10 + (c - 48)
            any = True
        else:
            return -1
    if not any:
        return -1
    return v


def _read_headers(mut io: LspIo) raises -> Int:
    """Читать заголовки до пустой строки. Вернуть Content-Length (-1 нет)."""
    var length = -1
    while True:
        var line = io.read_line()
        if line == "":
            break
        var colon = line.find(":")
        if colon != -1:
            var name = String(String(line[byte=0:colon]).strip()).lower()
            var val = String(String(line[byte=colon + 1 :]).strip())
            if name == "content-length":
                length = _parse_header_int(val)
    return length


# ============================================================================
# Хранилище документов
# ============================================================================


@fieldwise_init
struct DocEntry(Copyable, Movable):
    var uri: String
    var text: String
    var tmp: String


struct LspState(Copyable, Movable):
    var docs: List[DocEntry]
    var seq: Int
    var shutdown_seen: Bool

    def __init__(out self):
        self.docs = List[DocEntry]()
        self.seq = 0
        self.shutdown_seen = False

    def find(self, uri: String) -> Int:
        for i in range(len(self.docs)):
            if self.docs[i].uri == uri:
                return i
        return -1

    def store(mut self, uri: String, text: String) -> Int:
        """Сохранить/создать документ. Вернуть индекс (tmp выдаётся раз)."""
        var i = self.find(uri)
        if i != -1:
            self.docs[i].text = text
            return i
        var tmp = LSP_TMP_DIR + "/d" + String(self.seq) + ".bp"
        self.seq += 1
        self.docs.append(DocEntry(uri, text, tmp))
        return len(self.docs) - 1

    def drop(mut self, uri: String):
        var i = self.find(uri)
        if i != -1:
            _ = self.docs.pop(i)


# ============================================================================
# Анализ документа реальным конвейером
# ============================================================================


def _clamp_line(line_1based: Int, nlines: Int) -> Int:
    """1-based строка модели -> 0-based строка LSP с клампом."""
    var l = line_1based - 1
    if nlines <= 0:
        return 0
    if l < 0:
        return 0
    if l >= nlines:
        return nlines - 1
    return l


def _publish_for(
    mut io: LspIo, uri: String, diags_body: String
) raises:
    var note = (
        '{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics",'
        '"params":{"uri":' + json_quote(uri) + ',"diagnostics":[' + diags_body + "]}}"
    )
    io.write_msg(note)


def _append_stage3(mut ctx: Ctx, file: String, msg: String):
    """Ошибка стадии 3 -> диагностика (код 3000 = маркер стадии lmsb, как в buildcmd).

    Хвост C#-сообщения " at: L:C" даёт строку (в развёрнутом тексте; карта
    развёртка->исходник утеряна — docs/05 §0.4, кламп ниже привяжет к документу).
    """
    var marker = " at: "
    var body = msg
    var line_no = 0
    var idx = msg.rfind(marker)
    if idx != -1:
        body = String(msg[byte=0:idx])
        var tail = String(msg[byte = idx + marker.byte_length() :])
        var parts = tail.split(":")
        if len(parts) >= 1:
            var head = String(String(parts[0]).strip())
            var v = 0
            var ok = head.byte_length() > 0
            for i in range(head.byte_length()):
                var c = Int(_byte_at(head, i))
                if c < 48 or c > 57:
                    ok = False
                    break
                v = v * 10 + (c - 48)
            if ok:
                line_no = v
    ctx.diags.add(file, line_no, 3000, body)


def lsp_analyze(mut io: LspIo, mut st: LspState, idx: Int) raises:
    """Пересчитать документ idx и опубликовать диагностики."""
    var uri = st.docs[idx].uri
    var text = st.docs[idx].text
    var tmp = st.docs[idx].tmp
    var lines = text_to_lines(text)

    # стадия 1-2: лексер по каждой строке (диагностик сам не даёт —
    # NON-строки и ошибки выявляют проходы expand ниже)
    for i in range(len(lines)):
        _ = build_line(lines[i], i + 1)

    var ctx = Ctx()
    var texts = List[String]()
    try:
        write_text(tmp, text)
        texts = run_expansion(tmp, "", ctx)
    except e:
        io.log("lsp: конвейер упал: " + String(e))
        _publish_for(io, uri, "")
        return

    # стадия 3: компиляция развёрнутого текста in-memory (ловит то, что
    # expand не валидирует: скобки, выражения, несуществующие методы).
    try:
        _ = compile_source_lines(texts)
    except e:
        _append_stage3(ctx, tmp, String(e))

    var body = String("")
    for i in range(ctx.diags.count()):
        var d = ctx.diags.items[i].copy()
        var l = _clamp_line(d.line, len(lines))
        var msg = ctx.diags.bp_message(i)
        if i > 0:
            body += ","
        body += (
            '{"range":{"start":{"line":' + String(l) + ',"character":0},'
            '"end":{"line":' + String(l) + ',"character":0}},'
            '"severity":1,"code":' + String(d.code) + ',"message":'
            + json_quote(msg) + "}"
        )
    _publish_for(io, uri, body)


# ============================================================================
# Hover: builtin-классы (docs/03, кратко)
# ============================================================================


def hover_for(name: String) -> String:
    """Короткая справка по builtin-классу ("" — неизвестно)."""
    var n = name.lower()
    if n == "assert":
        return "Assert — проверки: Equal/NotEqual/Less/Greater/LessEqual/GreaterEqual/Near(a, b, msg), Failed(msg)."
    if n == "buttons":
        return "Buttons — кнопки кирпича: Current (property), GetClicks, Wait, Flush."
    if n == "byte":
        return "Byte — 8-битная арифметика: Not/And_/Or_/Xor/Bit/Shl/Shr, ToHex/ToBinary/ToLogic, H/B/L."
    if n == "ev3":
        return "EV3 — кирпич: Time/BatteryLevel/BatteryVoltage/BatteryCurrent/BrickName (properties), SetLEDColor, SystemCall, QueueNextCommand."
    if n == "ev3file":
        return "EV3File — файлы: OpenRead/OpenWrite/OpenAppend, Close, ReadLine/WriteLine, ReadByte/WriteByte, ReadNumberArray/WriteNumberArray, ConvertToNumber, TableLookup."
    if n == "lcd":
        return "LCD — экран: Clear, Update/StopUpdate, Text/Write, Rect/FillRect/InverseRect, Line, Circle/FillCircle, Pixel, BmpFile."
    if n == "mailbox":
        return "Mailbox — почта BT: Create/CreateForNumber, IsAvailable, Send/SendNumber, Receive/ReceiveNumber, Connect."
    if n == "math":
        return "Math — математика (тригонометрия в градусах): Pi, Abs/Floor/Ceiling/Round, Sin/Cos/Tan, ArcSin/ArcCos/ArcTan, Power, Max/Min, Log/NaturalLog, SquareRoot, Remainder, GetDegrees/GetRadians, GetRandomNumber."
    if n == "motor":
        return "Motor — моторы по дескриптору порта (A, AB, 1A): Start/StartPower/StartSteer/StartSync, Schedule*, Move*, Stop, Wait, GetSpeed/GetCount, IsBusy, ResetCount, Invert."
    if n == "motora" or n == "motorb" or n == "motorc" or n == "motord":
        return "MotorA/B/C/D — один мотор (порт зашит): Start(Set)Speed/Power, Off/OffAndBrake, GetSpeed/GetTacho, ResetCount, IsLarge/IsMedium, SetDirectPolarity/SetReversPolarity."
    if (
        n == "motorab"
        or n == "motorac"
        or n == "motorad"
        or n == "motorbc"
        or n == "motorbd"
        or n == "motorcd"
    ):
        return "MotorAB/AC/AD/BC/BD/CD — пара моторов: Start(Set)Speed/Power, Off/OffAndBrake (делят ячейки setSpeedA/setPowerA)."
    if n == "program":
        return "Program — программа: Delay(ms), End, Directory (property); ArgumentCount/GetArgument — заглушки (0/'')."
    if n == "row":
        return "Row — массивы-числа по handle: Init, Delete, Read/Write, Size, Resize."
    if n == "sensor":
        return "Sensor — датчики по номеру порта 1..4: ReadPercent/ReadRaw/ReadRawValue, GetName/GetType/GetMode, SetMode, Wait, IsBusy, I2C (CommunicateI2C, Read/WriteI2CRegister(s)), SendUartData."
    if n == "sensor1" or n == "sensor2" or n == "sensor3" or n == "sensor4":
        return "Sensor1..4 — быстрый путь к порту N (layer 0): Raw1, Raw3."
    if n == "speaker":
        return "Speaker — звук: Tone, Note, Play, Stop, Wait, IsBusy."
    if n == "text":
        return "Text — строки: Append, ConvertToLowerCase/ConvertToUpperCase, StartsWith/EndsWith/IsSubText, GetIndexOf, GetSubText/GetSubTextToEnd, GetLength, GetCharacter/GetCharacterCode."
    if n == "thread":
        return "Thread — потоки: Run = SUBNAME (event), Yield, CreateMutex, Lock/Unlock."
    if n == "time":
        return "Time — 9 таймеров (мс): Get1..Get9, Reset1..Reset9."
    if n == "vector":
        return "Vector — векторы/матрицы: Init, Data, Add, Sort, Multiply."
    return String("")


def _is_word_byte(c: UInt8) -> Bool:
    var x = Int(c)
    return (
        (65 <= x and x <= 90)
        or (97 <= x and x <= 122)
        or (48 <= x and x <= 57)
        or x == 95
        or x == 46
    )


def _word_at(line: String, ch: Int) -> String:
    """Слово [A-Za-z0-9_.]+ вокруг байтовой позиции ch."""
    var n = line.byte_length()
    var p = ch
    if p < 0:
        p = 0
    if p > n:
        p = n
    var a = p
    while a > 0 and _is_word_byte(line.unsafe_ptr().unsafe_offset(a - 1)[]):
        a -= 1
    var b = p
    while b < n and _is_word_byte(line.unsafe_ptr().unsafe_offset(b)[]):
        b += 1
    if a >= b:
        return String("")
    return String(line[byte=a:b])


def lsp_hover_text(st: LspState, uri: String, line: Int, ch: Int) -> String:
    """Текст hover или "" (нет документа/позиции/класса)."""
    var i = st.find(uri)
    if i == -1:
        return String("")
    var lines = text_to_lines(st.docs[i].text)
    if line < 0 or line >= len(lines):
        return String("")
    var w = _word_at(lines[line], ch)
    if w == "":
        return String("")
    var dot = w.find(".")
    var head = w
    if dot != -1:
        head = String(w[byte=0:dot])
    return hover_for(head)


# ============================================================================
# Ответы JSON-RPC
# ============================================================================


def _id_json(doc: JDoc, id_idx: Int) -> String:
    """Эхо id: строка — в кавычках, число — литералом как было."""
    if id_idx == -1:
        return String("null")
    if doc.nodes[id_idx].kind == JK_STR:
        return json_quote(doc.nodes[id_idx].raw)
    return doc.nodes[id_idx].raw


def _reply(id_part: String, result_part: String) -> String:
    return '{"jsonrpc":"2.0","id":' + id_part + ',"result":' + result_part + "}"


def _completion_list() -> String:
    var out = String("[")
    var first = True
    for w in LSP_KEYWORDS.split(" "):
        var label = String(w)
        if label == "":
            continue
        if not first:
            out += ","
        first = False
        out += '{"label":' + json_quote(label) + ',"kind":14}'
    for w in LSP_CLASSES.split(" "):
        var label = String(w)
        if label == "":
            continue
        if not first:
            out += ","
        first = False
        out += '{"label":' + json_quote(label) + ',"kind":7}'
    out += "]"
    return out


def _handle(
    mut io: LspIo, mut st: LspState, body: String
) raises -> Int:
    """Обработать одно сообщение. Вернуть код выхода или -1 (продолжить)."""
    var doc: JDoc
    try:
        doc = json_parse(body)
    except e:
        io.log("lsp: битый JSON: " + String(e))
        return -1
    if doc.root == -1 or doc.nodes[doc.root].kind != JK_OBJ:
        return -1
    var m_idx = jobject_get(doc, doc.root, "method")
    if m_idx == -1:
        return -1
    var method = jstr(doc, m_idx)
    var id_idx = jobject_get(doc, doc.root, "id")
    var has_id = id_idx != -1
    var p_idx = jobject_get(doc, doc.root, "params")

    if method == "initialize":
        var res = (
            '{"capabilities":{"textDocumentSync":1,"hoverProvider":true,'
            '"completionProvider":{}},'
            '"serverInfo":{"name":"bp-lsp","version":"0.1.0"}}'
        )
        io.write_msg(_reply(_id_json(doc, id_idx), res))
        return -1
    if method == "initialized":
        return -1
    if method == "shutdown":
        st.shutdown_seen = True
        io.write_msg(_reply(_id_json(doc, id_idx), "null"))
        return -1
    if method == "exit":
        if st.shutdown_seen:
            return 0
        return 1
    if method == "textDocument/didOpen":
        if p_idx == -1:
            return -1
        var td = jobject_get(doc, p_idx, "textDocument")
        if td == -1:
            return -1
        var uri = jstr(doc, jobject_get(doc, td, "uri"))
        var text = jstr(doc, jobject_get(doc, td, "text"))
        var idx = st.store(uri, text)
        lsp_analyze(io, st, idx)
        return -1
    if method == "textDocument/didChange":
        if p_idx == -1:
            return -1
        var td = jobject_get(doc, p_idx, "textDocument")
        if td == -1:
            return -1
        var uri = jstr(doc, jobject_get(doc, td, "uri"))
        var ch = jobject_get(doc, p_idx, "contentChanges")
        if ch == -1 or doc.nodes[ch].kind != JK_ARR or jarray_len(doc, ch) == 0:
            return -1
        var last = jarray_at(doc, ch, jarray_len(doc, ch) - 1)
        var t_idx = jobject_get(doc, last, "text")
        if t_idx == -1:
            return -1
        var idx = st.store(uri, jstr(doc, t_idx))
        lsp_analyze(io, st, idx)
        return -1
    if method == "textDocument/didClose":
        if p_idx != -1:
            var td = jobject_get(doc, p_idx, "textDocument")
            if td != -1:
                var uri = jstr(doc, jobject_get(doc, td, "uri"))
                st.drop(uri)
                _publish_for(io, uri, "")
        return -1
    if method == "textDocument/hover":
        if not has_id:
            return -1
        var result = String("null")
        if p_idx != -1:
            var td = jobject_get(doc, p_idx, "textDocument")
            var pos = jobject_get(doc, p_idx, "position")
            if td != -1 and pos != -1:
                var uri = jstr(doc, jobject_get(doc, td, "uri"))
                try:
                    var ln = jint(doc, jobject_get(doc, pos, "line"))
                    var ch = jint(doc, jobject_get(doc, pos, "character"))
                    var text = lsp_hover_text(st, uri, ln, ch)
                    if text != "":
                        result = (
                            '{"contents":{"kind":"plaintext","value":'
                            + json_quote(text) + "}}"
                        )
                except:
                    pass
        io.write_msg(_reply(_id_json(doc, id_idx), result))
        return -1
    if method == "textDocument/completion":
        if not has_id:
            return -1
        io.write_msg(_reply(_id_json(doc, id_idx), _completion_list()))
        return -1
    # неизвестный метод: запрос с id -> result:null, уведомление -> молча
    if has_id:
        io.write_msg(_reply(_id_json(doc, id_idx), "null"))
    return -1


def cmd_lsp() raises -> Int:
    """LSP-сервер Basic Plus поверх stdio. Возвращает код выхода."""
    var io = LspIo()
    var st = LspState()
    try:
        mkdir(LSP_TMP_DIR)
    except:
        pass
    io.log("bp lsp: старт (tmp=" + LSP_TMP_DIR + ")")
    while True:
        var length = -1
        try:
            length = _read_headers(io)
        except:
            break  # EOF / stdin закрыт — чистая остановка
        if length < 0:
            io.log("lsp: нет Content-Length — сообщение пропущено")
            continue
        var body = String("")
        try:
            body = io.read_exact(length)
        except:
            break
        var rc = -1
        try:
            rc = _handle(io, st, body)
        except e:
            io.log("lsp: ошибка обработки: " + String(e))
            rc = -1
        if rc >= 0:
            return rc
    return 0


# ============================================================================
# Врезка в src/bp/main.mojo (НЕ ПРИМЕНЕНА — main.mojo запрещён к изменению):
#
#   from bp.lsp import cmd_lsp
#   ...
#   if cmd == "lsp":
#       return cmd_lsp()
#
# (заменить существующую заглушку `if cmd == "lsp": _ = cmd_not_implemented(cmd)`).
# ============================================================================
