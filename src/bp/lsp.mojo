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

Диагностики строятся реальным конвейером стадий 1-2 БЕЗ семантического
форка: текст документа пишется в ПРИВАТНЫЙ (0700) каталог процесса,
созданный stdlib tempfile.mkdtemp, затем run_expansion(...) с реальным
родителем документа из decoded file URI в четвёртом аргументе project_dir.
Исходники, .bpi/.bpm и глобальный /tmp/bp_lsp_docs не изменяются; каталог
удаляется на didClose и на выходе процесса (включая ошибки).

Позиции LSP character — UTF-16 code units: hover переводит их в байтовое
смещение (ASCII — быстрый путь; середина суррогата отвергается). Диагностики
стадий 1-2 привязываются к строке исходника (end.character — UTF-16 длина
строки); диагностика физического include/import-файла получает anchor 0 и
correct path в relatedInformation. Ошибка стадии 3 непереводима на исходник:
код 3000, anchor 0 и явный текст «ошибка в развёрнутом коде...».

Транспорт fail-closed: Content-Length обязателен и валиден, тело <= 16 MiB,
строгий UTF-8, глубина JSON <= 128; битый JSON кадра — -32700, ошибка
кадрирования — фатальный ненулевой выход. id сериализуется JSON-парсером
(string/number/null), недопустимый тип id — -32600, неизвестный метод
запроса — -32601; уведомления без id ответа не получают.

hover возвращает короткий текст для builtin-классов (docs/03);
completion — KEYWORDS + BUILTIN_CLASSES из grammar/grammar.js.
"""

from std.python import Python, PythonObject
from bp.json import (
    JDoc,
    JK_ARR,
    JK_NULL,
    JK_NUM,
    JK_OBJ,
    JK_STR,
    jarray_at,
    jarray_len,
    jint,
    jobject_get,
    json_dump,
    json_parse,
    json_quote,
    jstr,
)
from bp.compiler3 import compile_source_lines
from bp.expand import Ctx, run_expansion
from bp.util import text_to_lines, write_text


# Границы доверенной области транспорта (фиксированы, без конфигурации).
comptime LSP_MAX_BODY = 16 * 1024 * 1024  # 16 MiB на тело JSON-RPC
comptime LSP_DIAG_ANALYSIS = 9000  # серверная ошибка анализа, не «чисто»
comptime LSP_STAGE3 = 3000  # маркер стадии 3 (как в buildcmd)

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
        var s = String(raw.decode("utf-8", "strict"))
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
                raise Error("lsp: eof в теле сообщения")
            data = data + chunk
            got = Int(data.__len__())
        return String(data.decode("utf-8", "strict"))

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
    """Ручной разбор неотрицательного Content-Length; -1 при неудаче.

    Знак, пробелы внутри, пустая строка и значения сверх LSP_MAX_BODY
    отвергаются: огромный Content-Length не переполняет счётчик и не
    приводит к выделению памяти под тело.
    """
    var v = 0
    var any = False
    for i in range(s.byte_length()):
        var c = Int(s.unsafe_ptr().unsafe_offset(i)[])
        if 48 <= c and c <= 57:
            v = v * 10 + (c - 48)
            if v > LSP_MAX_BODY:
                return -1
            any = True
        else:
            return -1
    if not any:
        return -1
    return v


def _read_headers(mut io: LspIo) raises -> Int:
    """Заголовки до пустой строки; вернуть Content-Length.

    EOF ровно на границе сообщений — чистая остановка ("lsp: eof").
    Любой другой дефект (обрыв заголовков, отсутствие/повтор/мусор
    Content-Length, строка без имени) — фатальная ошибка кадрирования:
    тело сообщения нельзя принять за следующий заголовок.
    """
    var line = ""
    try:
        line = io.read_line()
    except e:
        if String(e) == "lsp: eof":
            raise Error("lsp: eof")
        raise Error("lsp: некорректные заголовки")
    var length = -1
    var seen = False
    while line != "":
        var colon = line.find(":")
        if colon <= 0:
            raise Error("lsp: некорректная строка заголовка")
        var name = String(String(line[byte=0:colon]).strip()).lower()
        var val = String(String(line[byte=colon + 1 :]).strip())
        if name == "content-length":
            if seen:
                raise Error("lsp: повторный Content-Length")
            seen = True
            length = _parse_header_int(val)
            if length < 0:
                raise Error("lsp: некорректный Content-Length")
        try:
            line = io.read_line()
        except:
            raise Error("lsp: обрыв заголовков")
    if not seen:
        raise Error("lsp: отсутствует Content-Length")
    return length


# ============================================================================
# URI документа, UTF-8/UTF-16 и временные пути
# ============================================================================


def _u8(s: String, i: Int) -> Int:
    return Int(s.unsafe_ptr().unsafe_offset(i)[])


def _hex_digit(c: Int) -> Int:
    if 48 <= c and c <= 57:
        return c - 48
    if 65 <= c and c <= 70:
        return c - 55
    if 97 <= c and c <= 102:
        return c - 87
    return -1


def _bytes_to_string(raw: List[UInt8]) -> String:
    if len(raw) == 0:
        return String("")
    var span = Span(unsafe_ptr=raw.unsafe_ptr(), length=len(raw))
    return String(StringSlice(unsafe_from_utf8=span))


def _utf8_seq_len(b: Int) -> Int:
    if b < 0x80:
        return 1
    if (b & 0xE0) == 0xC0:
        return 2
    if (b & 0xF0) == 0xE0:
        return 3
    if (b & 0xF8) == 0xF0:
        return 4
    return 0


def _utf8_codepoint(s: String, i: Int, ln: Int) -> Int:
    var b0 = _u8(s, i)
    if ln == 1:
        return b0
    if ln == 2:
        return ((b0 & 0x1F) << 6) | (_u8(s, i + 1) & 0x3F)
    if ln == 3:
        return (
            ((b0 & 0x0F) << 12)
            | ((_u8(s, i + 1) & 0x3F) << 6)
            | (_u8(s, i + 2) & 0x3F)
        )
    return (
        ((b0 & 0x07) << 18)
        | ((_u8(s, i + 1) & 0x3F) << 12)
        | ((_u8(s, i + 2) & 0x3F) << 6)
        | (_u8(s, i + 3) & 0x3F)
    )


def _validate_utf8(raw: List[UInt8]) raises:
    """Строгая проверка UTF-8 (без overlong/суррогатов/выхода за U+10FFFF)."""
    var i = 0
    var n = len(raw)
    while i < n:
        var b = Int(raw[i])
        if b < 0x80:
            i += 1
            continue
        var ln = _utf8_seq_len(b)
        if ln == 0 or i + ln > n:
            raise Error("lsp: некорректный UTF-8 в URI")
        var cp = b & (0xFF >> (ln + 1))
        for k in range(1, ln):
            var c = Int(raw[i + k])
            if (c & 0xC0) != 0x80:
                raise Error("lsp: некорректный UTF-8 в URI")
            cp = (cp << 6) | (c & 0x3F)
        if (
            (ln == 2 and cp < 0x80)
            or (ln == 3 and cp < 0x800)
            or (ln == 4 and cp < 0x10000)
        ):
            raise Error("lsp: overlong UTF-8 в URI")
        if (0xD800 <= cp and cp <= 0xDFFF) or cp > 0x10FFFF:
            raise Error("lsp: некорректный code point в URI")
        i += ln


def _percent_decode(s: String) raises -> String:
    """Percent-decode UTF-8 URI. Некорректный %XX/UTF-8 — явная ошибка."""
    var raw = List[UInt8]()
    var i = 0
    var n = s.byte_length()
    while i < n:
        var b = _u8(s, i)
        if b == 37:  # '%'
            if i + 2 >= n:
                raise Error("lsp: обрезанный percent-escape в URI")
            var hi = _hex_digit(_u8(s, i + 1))
            var lo = _hex_digit(_u8(s, i + 2))
            if hi < 0 or lo < 0:
                raise Error("lsp: некорректный percent-escape в URI")
            var v = hi * 16 + lo
            if v == 0:
                raise Error("lsp: NUL в пути URI не поддерживается")
            raw.append(UInt8(v))
            i += 3
        else:
            raw.append(UInt8(b))
            i += 1
    _validate_utf8(raw)
    return _bytes_to_string(raw)


def _path_to_uri(path: String) -> String:
    """Абсолютный путь -> file URI с percent-кодированием не-ASCII/спецсимволов."""
    var out = List[UInt8]()
    var prefix = "file://"
    for i in range(prefix.byte_length()):
        out.append(UInt8(_u8(prefix, i)))
    for i in range(path.byte_length()):
        var b = _u8(path, i)
        var keep = (
            (48 <= b and b <= 57)
            or (65 <= b and b <= 90)
            or (97 <= b and b <= 122)
            or b == 45
            or b == 46
            or b == 95
            or b == 126
            or b == 47
        )
        if keep:
            out.append(UInt8(b))
        else:
            out.append(UInt8(37))
            out.append(UInt8(48 + (b >> 4)))
            var lo = b & 15
            if lo < 10:
                out.append(UInt8(48 + lo))
            else:
                out.append(UInt8(65 + lo - 10))
    return _bytes_to_string(out)


def _is_file_uri(uri: String) -> Bool:
    """Схема URI сравнивается без регистра (RFC 3986)."""
    if uri.byte_length() < 5:
        return False
    return String(uri[byte=0:5]).lower() == "file:"


def _file_uri_to_path(uri: String) raises -> String:
    """file:///abs или file://localhost/abs -> локальный путь.

    Пустой/localhost authority допустим; любой другой authority, query,
    fragment, относительный путь и битые percent-escape отвергаются явно.
    Никакого «срезания косых»/угадывания пути нет.
    """
    if not _is_file_uri(uri):
        raise Error("lsp: не file URI")
    if uri.byte_length() < 7 or String(uri[byte=0:7]).lower() != "file://":
        raise Error("lsp: file URI без // не поддерживается")
    var after = String(uri[byte=7:])
    var slash = after.find("/")
    var authority = after
    var path = String("")
    if slash != -1:
        authority = String(after[byte=0:slash])
        path = String(after[byte=slash:])
    var auth_low = authority.lower()
    if authority != "" and auth_low != "localhost":
        raise Error(
            "lsp: удалённый authority file URI не поддерживается: " + authority
        )
    if path == "":
        raise Error("lsp: file URI без локального пути")
    if path.find("?") != -1 or path.find("#") != -1:
        raise Error("lsp: query/fragment в file URI не поддерживаются")
    var decoded = _percent_decode(path)
    if not decoded.startswith("/"):
        raise Error("lsp: путь file URI должен быть абсолютным")
    return decoded^


def _parent_dir(path: String) -> String:
    var idx = path.rfind("/")
    if idx == -1:
        return String(".")
    if idx == 0:
        return String("/")
    return String(path[byte=0:idx])


def _cwd() -> String:
    try:
        return String(Python.import_module("os").getcwd())
    except:
        return String(".")


def _sanitize(msg_in: String, root: String, tmp: String) -> String:
    """Убрать внутренние временные пути из сообщений для stderr/диагностик."""
    var msg = msg_in
    if tmp != "":
        msg = msg.replace(tmp, "<временный документ>")
    if root != "":
        msg = msg.replace(root, "<приватный tmp>")
    return msg^


def _utf16_len(s: String) -> Int:
    var i = 0
    var n = s.byte_length()
    var units = 0
    while i < n:
        var ln = _utf8_seq_len(_u8(s, i))
        if ln == 0 or i + ln > n:
            ln = 1
        var cp = _utf8_codepoint(s, i, ln)
        if cp >= 0x10000:
            units += 2
        else:
            units += 1
        i += ln
    return units


def _is_ascii(s: String) -> Bool:
    for i in range(s.byte_length()):
        if _u8(s, i) >= 0x80:
            return False
    return True


def _utf16_to_byte(s: String, target: Int) -> Int:
    """UTF-16 code units -> байтовое смещение; -1: отрицательное/середина суррогата.

    Смещение за концом строки клампится к концу (как у большинства LSP-серверов);
    позиция ВНУТРИ суррогатной пары отвергается, а не сдвигается молча.
    """
    if target < 0:
        return -1
    var n = s.byte_length()
    if _is_ascii(s):
        if target > n:
            return n
        return target
    var i = 0
    var u = 0
    while i < n:
        if u == target:
            return i
        var ln = _utf8_seq_len(_u8(s, i))
        if ln == 0 or i + ln > n:
            ln = 1
        var width = 1
        if ln == 4:
            width = 2
        if u + width > target:
            return -1
        u += width
        i += ln
    if target >= u:
        return n
    return -1


# ============================================================================
# Хранилище документов
# ============================================================================


@fieldwise_init
struct DocEntry(Copyable, Movable):
    var uri: String
    var text: String
    var tmp: String
    var src_path: String
    var project_dir: String
    var display: String
    var usable: Bool
    var reject_reason: String
    var tmp_created: Bool


struct LspState(Copyable, Movable):
    var root: String
    var docs: List[DocEntry]
    var seq: Int
    var shutdown_seen: Bool

    def __init__(out self, root: String):
        self.root = root
        self.docs = List[DocEntry]()
        self.seq = 0
        self.shutdown_seen = False

    def find(self, uri: String) -> Int:
        for i in range(len(self.docs)):
            if self.docs[i].uri == uri:
                return i
        return -1

    def store(mut self, uri: String, text: String) raises -> Int:
        """Сохранить/создать документ. Вернуть индекс.

        Имя временного файла выделяется внутри ПРИВАТНОГО корня процесса;
        реальный родитель документа берётся из декодированного file URI и
        передаётся четвёртым аргументом run_expansion (project_dir).
        """
        var i = self.find(uri)
        if i != -1:
            self.docs[i].text = text
            return i
        var tmp = self.root + "/d" + String(self.seq) + ".bp"
        self.seq += 1
        var src = String("")
        var proj = String("")
        var disp = uri
        var usable = True
        var reason = String("")
        if _is_file_uri(uri):
            try:
                src = _file_uri_to_path(uri)
                proj = _parent_dir(src)
                disp = src
            except e:
                usable = False
                reason = String(e)
        else:
            # untitled: реального файла нет; include/import ищем от cwd и
            # явно сообщаем об ошибке конвейера, если файл не найден.
            proj = _cwd()
        self.docs.append(
            DocEntry(uri, text, tmp, src, proj, disp, usable, reason, False)
        )
        return len(self.docs) - 1

    def drop(mut self, uri: String):
        var i = self.find(uri)
        if i != -1:
            _ = self.docs.pop(i)


# ============================================================================
# Анализ документа реальным конвейером
# ============================================================================


def _publish_for(mut io: LspIo, uri: String, diags_body: String) raises:
    var note = (
        '{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics",'
        '"params":{"uri":' + json_quote(uri) + ',"diagnostics":[' + diags_body + "]}}"
    )
    io.write_msg(note)


def _range_json(line: Int, end_char: Int) -> String:
    return (
        '{"start":{"line":' + String(line) + ',"character":0},'
        '"end":{"line":' + String(line) + ',"character":' + String(end_char) + "}}"
    )


def _diag_json(code: Int, msg: String, rng: String, rel: String) -> String:
    return (
        '{"range":'
        + rng
        + ',"severity":1,"code":'
        + String(code)
        + ',"message":'
        + json_quote(msg)
        + rel
        + "}"
    )


def _failure_diag(msg: String) -> String:
    """Явная серверная диагностика: НИКОГДА не выдаётся за «чисто»."""
    return _diag_json(
        LSP_DIAG_ANALYSIS,
        msg,
        _range_json(0, 0),
        ',"source":"bp-lsp"',
    )


def _write_doc(tmp: String, text: String, exclusive: Bool) raises:
    """Первая запись — эксклюзивное создание (O_EXCL), далее — перезапись."""
    if exclusive:
        var builtins = Python.import_module("builtins")
        var f = builtins.open(PythonObject(tmp), "x")
        try:
            _ = f.write(PythonObject(text))
        finally:
            f.close()
        return
    write_text(tmp, text)


def _remove_owned(path: String):
    """Удалить только собственный временный файл; чужие пути не трогаем."""
    try:
        _ = Python.import_module("os").remove(PythonObject(path))
    except:
        pass


def _pipeline_diag(
    ctx: Ctx,
    i: Int,
    tmp: String,
    display: String,
    lines: List[String],
    root: String,
) -> String:
    """Диагностика стадий 1-2.

    Строка своей развёртки (d.file == tmp) относится к исходному документу:
    печатаем её под URI документа. Если диагностика пришла из физического
    include/import-файла, основная позиция остаётся anchor 0 (не выдаём
    чужую строку за строку документа), а correct path уходит в
    relatedInformation; при невозможности построить URI — только имя файла
    в сообщении.
    """
    var d = ctx.diags.items[i].copy()
    var code = d.code
    var line = d.line
    var body = _sanitize(d.message, root, tmp)
    if d.file == tmp:
        var msg = (
            "file: "
            + display
            + " line: "
            + String(line)
            + " | code: "
            + String(code)
            + " ===> "
            + body
        )
        var l = 0
        var end_char = 0
        if line >= 1 and line <= len(lines):
            l = line - 1
            end_char = _utf16_len(lines[l])  # LSP character — UTF-16 units
        else:
            msg += " (строка вне документа)"
        return _diag_json(code, msg, _range_json(l, end_char), "")
    var msg2 = (
        "file: "
        + d.file
        + " line: "
        + String(line)
        + " | code: "
        + String(code)
        + " ===> "
        + body
    )
    var rel = String("")
    if d.file.startswith("/"):
        var rel_line = 0
        if line >= 1:
            rel_line = line - 1
        rel = (
            ',"relatedInformation":[{"location":{"uri":'
            + json_quote(_path_to_uri(d.file))
            + ',"range":'
            + _range_json(rel_line, 0)
            + '},"message":'
            + json_quote(msg2)
            + "}]"
        )
    else:
        msg2 += " (файл диагностики: " + d.file + ")"
    return _diag_json(code, msg2, _range_json(0, 0), rel)


def _stage3_diag(msg: String) -> String:
    """Ошибка стадии 3 -> код 3000 + честный anchor 0.

    Строка в сообщении относится к РАЗВЁРНУТОМУ коду; карты на исходник нет,
    поэтому НЕ клампим её к последней строке документа и не выдаём за
    точную исходную позицию.
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
                var c = _u8(head, i)
                if c < 48 or c > 57:
                    ok = False
                    break
                v = v * 10 + (c - 48)
            if ok:
                line_no = v
    var reason = body
    if reason != "":
        reason += " — "
    reason += (
        "ошибка в развёрнутом коде, строка "
        + String(line_no)
        + "; точное место в исходнике неизвестно"
    )
    return _diag_json(LSP_STAGE3, reason, _range_json(0, 0), "")


def lsp_analyze(mut io: LspIo, mut st: LspState, idx: Int) raises:
    """Пересчитать документ idx и опубликовать диагностики.

    Любой сбой анализа публикует явную диагностику LSP_DIAG_ANALYSIS и
    заменяет прошлый результат (никакого пустого списка «всё чисто»).
    """
    var uri = st.docs[idx].uri
    var text = st.docs[idx].text
    var tmp = st.docs[idx].tmp
    var display = st.docs[idx].display
    var body = String("")
    if not st.docs[idx].usable:
        body = _failure_diag(
            "документ не анализируется: " + st.docs[idx].reject_reason
        )
        _publish_for(io, uri, body)
        return
    var lines = text_to_lines(text)
    try:
        _write_doc(tmp, text, not st.docs[idx].tmp_created)
        st.docs[idx].tmp_created = True
        var ctx = Ctx()
        var texts = run_expansion(tmp, "", ctx, st.docs[idx].project_dir)
        var parts = List[String]()
        for i in range(ctx.diags.count()):
            parts.append(_pipeline_diag(ctx, i, tmp, display, lines, st.root))
        # стадия 3 по развёрнутому тексту (если стадии 1-2 не остановили конвейер)
        if len(texts) > 0 and not ctx.diags.has_errors():
            try:
                _ = compile_source_lines(texts)
            except e:
                parts.append(
                    _stage3_diag(_sanitize(String(e), st.root, tmp))
                )
        body = String(",").join(parts)
    except e:
        var detail = _sanitize(String(e), st.root, tmp)
        io.log("lsp: анализ не удался: " + detail)
        body = _failure_diag("анализ не выполнен: " + detail)
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


def lsp_hover_text(st: LspState, uri: String, line: Int, ch_utf16: Int) -> String:
    """Текст hover или "" (нет документа/позиции/класса).

    incoming LSP character измеряется в UTF-16 code units; переводим его в
    байтовое смещение строки (ASCII — быстрый путь). Середина суррогатной
    пары и отрицательная позиция отвергаются, выход за строку клампится.
    """
    var i = st.find(uri)
    if i == -1:
        return String("")
    var lines = text_to_lines(st.docs[i].text)
    if line < 0 or line >= len(lines):
        return String("")
    var ch = _utf16_to_byte(lines[line], ch_utf16)
    if ch < 0:
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
    """Сериализовать допустимый id (string/number/null) через JSON-сериализатор.

    Никакой ручной вставки raw-текста: null даёт "null", строка — корректно
    экранированные кавычки, число — литерал, который разобрал парсер.
    """
    if id_idx == -1:
        return String("null")
    return json_dump(doc, id_idx)


def _valid_id_kind(kind: Int) -> Bool:
    return kind == JK_STR or kind == JK_NUM or kind == JK_NULL


def _reply(id_part: String, result_part: String) -> String:
    return '{"jsonrpc":"2.0","id":' + id_part + ',"result":' + result_part + "}"


def _error_reply(id_part: String, code: Int, message: String) -> String:
    return (
        '{"jsonrpc":"2.0","id":'
        + id_part
        + ',"error":{"code":'
        + String(code)
        + ',"message":'
        + json_quote(message)
        + "}}"
    )


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


def _handle(mut io: LspIo, mut st: LspState, body: String) raises -> Int:
    """Обработать одно сообщение. Вернуть код выхода или -1 (продолжить)."""
    var doc: JDoc
    try:
        doc = json_parse(body)
    except e:
        io.log("lsp: битый JSON: " + String(e))
        io.write_msg(_error_reply("null", -32700, "Parse error"))
        return -1
    if doc.root == -1 or doc.nodes[doc.root].kind != JK_OBJ:
        io.write_msg(_error_reply("null", -32600, "Invalid Request"))
        return -1
    var m_idx = jobject_get(doc, doc.root, "method")
    var id_idx = jobject_get(doc, doc.root, "id")
    var has_id = id_idx != -1
    var p_idx = jobject_get(doc, doc.root, "params")
    if m_idx == -1:
        # ответ/мусор без method: не запрос — молчим (если id был, это
        # всё равно не наш request; не подменяем его result:null).
        if has_id:
            io.write_msg(_error_reply("null", -32600, "Invalid Request"))
        return -1
    if doc.nodes[m_idx].kind != JK_STR:
        if has_id:
            io.write_msg(_error_reply("null", -32600, "Invalid Request"))
        return -1
    var method = jstr(doc, m_idx)
    if has_id and not _valid_id_kind(doc.nodes[id_idx].kind):
        # bool/array/object как id недопустимы: -32600 с id:null, не «эхо».
        io.write_msg(_error_reply("null", -32600, "Invalid Request"))
        return -1
    var id_json = _id_json(doc, id_idx)

    if method == "initialize":
        if not has_id:
            return -1
        var res = (
            '{"capabilities":{"textDocumentSync":1,"hoverProvider":true,'
            '"completionProvider":{}},'
            '"serverInfo":{"name":"bp-lsp","version":"0.1.0"}}'
        )
        io.write_msg(_reply(id_json, res))
        return -1
    if method == "initialized":
        return -1
    if method == "shutdown":
        st.shutdown_seen = True
        if has_id:
            io.write_msg(_reply(id_json, "null"))
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
                var ci = st.find(uri)
                var tmp = String("")
                if ci != -1:
                    tmp = st.docs[ci].tmp
                st.drop(uri)
                _remove_owned(tmp)
                # закрытие документа очищает и его диагностики (стандарт LSP),
                # внешних публикаций у нас нет — чистить больше нечего.
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
        io.write_msg(_reply(id_json, result))
        return -1
    if method == "textDocument/completion":
        if not has_id:
            return -1
        io.write_msg(_reply(id_json, _completion_list()))
        return -1
    # неизвестный метод: запрос -> JSON-RPC -32601; уведомление -> молча
    if has_id:
        io.write_msg(_error_reply(id_json, -32601, "Method not found"))
    return -1


def _cleanup_root(mut io: LspIo, root: String):
    """Удалить ПРИВАТНЫЙ корень процесса (включая файлы и на ошибках)."""
    if root == "":
        return
    try:
        Python.import_module("shutil").rmtree(PythonObject(root))
    except:
        io.log("lsp: не удалось удалить приватный временный каталог")


def cmd_lsp() raises -> Int:
    """LSP-сервер Basic Plus поверх stdio. Возвращает код выхода.

    Временные документы живут в приватном (0700) каталоге процесса,
    созданном stdlib tempfile; путь не фиксирован и не разделяется между
    процессами. Ошибка создания — явный ненулевой выход.
    """
    var io = LspIo()
    var root = String("")
    try:
        var tf = Python.import_module("tempfile")
        var tdir = String(
            Python.import_module("os").environ.get("TMPDIR", "")
        )
        if tdir == "":
            root = String(tf.mkdtemp(prefix="bp-lsp-"))
        else:
            # Явный TMPDIR уважается строго: никакого молчаливого fallback
            # в глобальный /tmp, иначе «сбой tmp» невозможно диагностировать.
            root = String(tf.mkdtemp(prefix="bp-lsp-", dir=tdir))
    except:
        io.log("bp lsp: не удалось создать приватный временный каталог")
        return 2
    io.log("bp lsp: старт (приватный tmp)")
    var st = LspState(root)
    try:
        while True:
            var length = -1
            try:
                length = _read_headers(io)
            except e:
                var em = String(e)
                if em == "lsp: eof":
                    return 0
                io.log(
                    "lsp: фатальная ошибка кадрирования: "
                    + _sanitize(em, root, "")
                )
                return 3
            var body = String("")
            try:
                body = io.read_exact(length)
            except e:
                io.log(
                    "lsp: фатальная ошибка тела сообщения: "
                    + _sanitize(String(e), root, "")
                )
                return 3
            var rc = -1
            try:
                rc = _handle(io, st, body)
            except e:
                io.log(
                    "lsp: ошибка обработки: "
                    + _sanitize(String(e), root, "")
                )
                rc = -1
            if rc >= 0:
                return rc
    finally:
        _cleanup_root(io, root)


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
