"""Регрессионный тест стадии 4 (ассемблер `.lmsb` -> `.rbf`).

Запуск:  cd /home/ssssq/Projects/clev3r_mojo && uv run mojo run src/bp/asm_test.mojo

Что проверяется (дефект F из отчёта t10):
  * выходной .rbf НЕ создаётся и НЕ перезаписывается при любой ошибке
    ассемблирования — C# Assembler.Start пишет в MemoryStream (Assembler.cs:70-108),
    файл появляется только при пустом errorList (Builder.cs:113-125,
    Builder.StartAssembler 219-232);
  * текст ошибок (errorList) остаётся прежним — это API для CLI;
  * валидный вход по-прежнему даёт побайтово ожидаемый .rbf: заголовок,
    кодирование констант на границах форм (LMSObject.cs:72-93), метки
    назад/вперёд и разность A:B (LMSObject.cs:150-197, 214-262), квирк
    `UI_DRAW TEXTBOX` = `84 81 20` (docs/04 §3.4).

Дополнительно (дефект data-loss при сбое записи ОС): публикация .rbf атомарна
через временный файл рядом с целью; успешная запись сохраняет права
существующего .rbf, при любом сбое (включая read-only каталог) цель побайтно
прежняя, свежий output не появляется, своих временных файлов не остаётся;
symlink-цель и существующая цель без права записи явно отклоняются, ошибка
mkstemp — отдельный текст ("cannot create temporary file"), а не общий
"write failed". RLIMIT_FSIZE/short-write сценарии — отдельно:
`python3 tools/tests/test_asm_write.py`.

ABI: st_mode берётся из stdlib std.os.lstat (без ручного смещения 24 в
struct stat), C-вызовы — типизированные (int -> Int32, mode_t -> UInt32),
поэтому тест не содержит x86-64-специфичных предположений и собирается на
ARM/macOS. Проверка прав не-владельцем (read-only файл/каталог) выполняется
только при ненулевом uid: у root access(W_OK) и open ведут себя иначе, такой
случай в тесте честно пропускается.

Ожидаемые байты выведены из C#-оракула (LMSObject.cs/Assembler.cs) и docs/04,
а не из текущей реализации. Фикстуры пишутся в уникальный каталог /tmp,
репозиторий не пачкается.
"""

from std.ffi import external_call
from std.os import getuid, listdir, lstat, mkdir, symlink
from std.os.path import exists
from std.time import perf_counter_ns

from bp.asm import assemble_file, assemble_lmsb, rbf_path_for
from bp.lexer import _byte_at
from bp.util import write_text


comptime FAILS_LIMIT = 40
comptime HEX_DIGITS = "0123456789ABCDEF"

comptime VALID_MINIMAL = "DATA32 G\nvmthread MAIN\n{\n    MOVE32_32 0 G\n}\n"

comptime S_IFMT = 0xF000
comptime S_IFLNK = 0xA000


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


@fieldwise_init
struct CodecCase(ImplicitlyCopyable):
    """Граница формы кодирования константы -> ожидаемые байты тела объекта."""

    var literal: String
    var body_hex: String


# ---------------------------------------------------------------------------
# Утилиты файлов/байтов (read_text не годится: .rbf содержит не-UTF-8 байты)
# ---------------------------------------------------------------------------


def read_bytes(path: String) raises -> List[UInt8]:
    """Сырые байты файла (без проверки UTF-8)."""
    with open(path, "r") as f:
        var b = f.read_bytes()
        var out = List[UInt8]()
        for i in range(len(b)):
            out.append(UInt8(b[i]))
        return out^


def bytes_of_text(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(s.byte_length()):
        out.append(_byte_at(s, i))
    return out^


def hex_of(raw: List[UInt8]) -> String:
    var parts = List[String]()
    for i in range(len(raw)):
        var v = Int(raw[i])
        var hi = String(HEX_DIGITS[byte=(v >> 4) : (v >> 4) + 1])
        var lo = String(HEX_DIGITS[byte=(v & 15) : (v & 15) + 1])
        parts.append(hi + lo)
    return String(" ").join(parts)


def take(raw: List[UInt8], start: Int, stop: Int) -> List[UInt8]:
    var out = List[UInt8]()
    var e = stop
    if e > len(raw):
        e = len(raw)
    for i in range(start, e):
        out.append(raw[i])
    return out^


def u16le(raw: List[UInt8], at: Int) -> Int:
    return Int(raw[at]) | (Int(raw[at + 1]) << 8)


def u32le(raw: List[UInt8], at: Int) -> Int:
    return (
        Int(raw[at])
        | (Int(raw[at + 1]) << 8)
        | (Int(raw[at + 2]) << 16)
        | (Int(raw[at + 3]) << 24)
    )


def write_fixture(dir: String, name: String, text: String) raises -> String:
    var path = dir + "/" + name + ".lmsb"
    write_text(path, text)
    return path^


# ---------------------------------------------------------------------------
# Проверки
# ---------------------------------------------------------------------------


def check_no_output(
    mut r: Reporter,
    dir: String,
    name: String,
    lmsb_text: String,
    exp_first_error: String,
    exp_error_count: Int,
    label: String,
) raises:
    """Невалидный вход: ошибки непусты, .rbf не создан, текст ошибок прежний."""
    var src = write_fixture(dir, name, lmsb_text)
    var dst = dir + "/" + name + ".rbf"
    if exists(dst):
        r.fail(label + ": тестовый scratch уже содержит " + dst)

    var errors = assemble_file(src, dst)
    if len(errors) == 0:
        r.fail(label + ": assemble_file вернул пустой errorList на невалидном входе")
    if exp_error_count != -1 and len(errors) != exp_error_count:
        var got = String(len(errors)) + " ошибок: " + String("\n    ").join(errors)
        r.fail(
            label + ": ожидалось " + String(exp_error_count) + " ошибок, получено " + got
        )
    if exp_first_error != "" and (len(errors) == 0 or errors[0] != exp_first_error):
        var got = String("(нет)")
        if len(errors) > 0:
            got = errors[0]
        r.fail(label + ": первая ошибка [" + got + "] != [" + exp_first_error + "]")
    if exists(dst):
        r.fail(
            label
            + ": .rbf СОЗДАН при ошибке ("
            + String(len(read_bytes(dst)))
            + " Б)"
        )


def check_sentinel_preserved(
    mut r: Reporter,
    dir: String,
    name: String,
    lmsb_text: String,
    sentinel: String,
    label: String,
) raises:
    """Существующий пользовательский .rbf после ошибки остаётся побайтно прежним."""
    var src = write_fixture(dir, name, lmsb_text)
    var dst = dir + "/" + name + ".rbf"
    write_text(dst, sentinel)
    var before = read_bytes(dst)

    var errors = assemble_file(src, dst)
    if len(errors) == 0:
        r.fail(label + ": assemble_file вернул пустой errorList на невалидном входе")
    if not exists(dst):
        r.fail(label + ": существующий .rbf УДАЛЁН при ошибке")
        return
    var after = read_bytes(dst)
    if hex_of(before) != hex_of(after):
        r.fail(
            label
            + ": существующий .rbf перезаписан при ошибке ["
            + hex_of(before)
            + "] -> ["
            + hex_of(after)
            + "]"
        )


def check_header(mut r: Reporter, raw: List[UInt8], label: String):
    """Общий заголовок .rbf (docs/04 §3.1): LEGO, размер, 0x0068, N объектов."""
    if len(raw) < 16:
        r.fail(label + ": .rbf короче 16 байт (" + String(len(raw)) + ")")
        return
    if hex_of(take(raw, 0, 4)) != "4C 45 47 4F":
        r.fail(label + ": нет магии LEGO: " + hex_of(take(raw, 0, 4)))
    if u32le(raw, 4) != len(raw):
        r.fail(
            label
            + ": размер в заголовке "
            + String(u32le(raw, 4))
            + " != фактического "
            + String(len(raw))
        )
    if u16le(raw, 8) != 0x0068:
        r.fail(label + ": версия " + String(u16le(raw, 8)) + " != 0x0068")


def check_valid_body(
    mut r: Reporter,
    dir: String,
    name: String,
    lmsb_text: String,
    exp_body_hex: String,
    exp_globals: Int,
    label: String,
) raises:
    """Валидный вход: ошибок нет, .rbf записан, тело объекта совпадает с ожиданием."""
    var src = write_fixture(dir, name, lmsb_text)
    var dst = dir + "/" + name + ".rbf"
    if exists(dst):
        r.fail(label + ": тестовый scratch уже содержит " + dst)

    var errors = assemble_file(src, dst)
    if len(errors) > 0:
        r.fail(label + ": ошибки на валидном входе: " + String("\n    ").join(errors))
        return
    if not exists(dst):
        r.fail(label + ": валидный вход не создал .rbf")
        return

    var raw = read_bytes(dst)
    check_header(r, raw, label)
    if len(raw) < 16:
        return
    var n = u16le(raw, 10)
    var body_from = 16 + n * 12
    var got = hex_of(take(raw, body_from, len(raw)))
    if got != exp_body_hex:
        r.fail(label + ": тело [" + got + "] != [" + exp_body_hex + "]")
    if u32le(raw, 12) != exp_globals:
        r.fail(
            label
            + ": байт глобальных данных "
            + String(u32le(raw, 12))
            + " != "
            + String(exp_globals)
        )


# ---------------------------------------------------------------------------
# Тесты
# ---------------------------------------------------------------------------


def test_failure_creates_no_output(mut r: Reporter, dir: String) raises:
    """Дефект F: невалидный/незакрытый/неразрешённый вход не даёт .rbf."""
    check_no_output(
        r,
        dir,
        "badopcode",
        "vmthread MAIN\n{\nBOGUS_OPCODE 1\n}\n",
        "Error at line 3: Unknown opcode BOGUS_OPCODE 1",
        1,
        "badopcode",
    )
    # Фикстура из доказательств t10 (29-байтный rbf до исправления).
    check_no_output(
        r,
        dir,
        "unclosed",
        "vmthread MAIN\n{\n    NOP\n",
        "Unexpected end of file",
        1,
        "unclosed",
    )
    # Фикстура из доказательств t10 (35-байтный rbf до исправления).
    check_no_output(
        r,
        dir,
        "unclosed_bad",
        "vmthread MAIN\n{\n    MOVEF_F 5.0 VGV_X\n",
        "Error at line 3: Unknown identifier VGV_X",
        2,
        "unclosed_bad",
    )
    check_no_output(
        r,
        dir,
        "missinglabel",
        "vmthread MAIN\n{\n    JR MISSING\n}\n",
        "Error at subcall integration: Unresolved jump target: MISSING",
        1,
        "missinglabel",
    )
    check_no_output(
        r,
        dir,
        "unknownvar",
        "vmthread MAIN\n{\n    MOVE32_32 0 NOPE\n}\n",
        "Error at line 3: Unknown identifier NOPE",
        1,
        "unknownvar",
    )
    check_no_output(
        r,
        dir,
        "missing_sub",
        "vmthread MAIN\n{\n    CALL NOSUB\n}\n",
        "Error at subcall integration: Unresolved subcall: NOSUB",
        1,
        "missing_sub",
    )
    check_no_output(
        r,
        dir,
        "baddir",
        "NOPE 1\n",
        "Error at line 1: Unknown command: NOPE",
        1,
        "baddir",
    )


def test_existing_output_preserved(mut r: Reporter, dir: String) raises:
    """Дефект F: устаревший пользовательский .rbf не трогается при ошибке."""
    comptime SENTINEL = "SENTINEL:stale user rbf, do not overwrite"
    check_sentinel_preserved(
        r, dir, "sent_badopcode", "vmthread MAIN\n{\nBOGUS_OPCODE 1\n}\n", SENTINEL, "sentinel/badopcode"
    )
    check_sentinel_preserved(
        r, dir, "sent_unclosed", "vmthread MAIN\n{\n    NOP\n", SENTINEL, "sentinel/unclosed"
    )
    check_sentinel_preserved(
        r, dir, "sent_missinglabel", "vmthread MAIN\n{\n    JR MISSING\n}\n", SENTINEL, "sentinel/missinglabel"
    )

    # Успешная сборка по-прежнему заменяет устаревший файл (как Builder.cs).
    var src = write_fixture(dir, "sent_valid", VALID_MINIMAL)
    var dst = dir + "/sent_valid.rbf"
    write_text(dst, SENTINEL)
    var errors = assemble_file(src, dst)
    if len(errors) > 0:
        r.fail("sentinel/valid: ошибки на валидном входе: " + String("\n    ").join(errors))
        return
    var raw = read_bytes(dst)
    if hex_of(raw) == hex_of(bytes_of_text(SENTINEL)):
        r.fail("sentinel/valid: валидная сборка не заменила старый .rbf")
        return
    check_header(r, raw, "sentinel/valid")


def test_valid_minimal_thread(mut r: Reporter, dir: String) raises:
    """Минимальный валидный поток: 32 байта, тело 3A 00 60 0A (docs/04 §3)."""
    check_valid_body(r, dir, "valid_min", VALID_MINIMAL, "3A 00 60 0A", 4, "valid_min")

    var dst = dir + "/valid_min.rbf"
    if exists(dst):
        var exp = (
            "4C 45 47 4F 20 00 00 00 68 00 01 00 04 00 00 00 "
            + "1C 00 00 00 00 00 00 00 00 00 00 00 3A 00 60 0A"
        )
        var got = hex_of(read_bytes(dst))
        if got != exp:
            r.fail("valid_min: файл [" + got + "] != [" + exp + "]")


def test_codec_thresholds(mut r: Reporter, dir: String) raises:
    """Границы форм констант (LMSObject.cs:72-93; docs/04 §3.4)."""
    var cases = List[CodecCase]()
    # короткая форма: -32..31 -> один байт (v & 0x3F)
    cases.append(CodecCase("-33", "3A 81 DF 60 0A"))  # первая 8-битная
    cases.append(CodecCase("-32", "3A 20 60 0A"))  # последняя короткая снизу
    cases.append(CodecCase("31", "3A 1F 60 0A"))  # последняя короткая сверху
    cases.append(CodecCase("32", "3A 81 20 60 0A"))  # первая 8-битная
    cases.append(CodecCase("-129", "3A 82 7F FF 60 0A"))  # первая 16-битная
    cases.append(CodecCase("-128", "3A 81 80 60 0A"))  # последняя 8-битная снизу
    cases.append(CodecCase("127", "3A 81 7F 60 0A"))  # последняя 8-битная сверху
    cases.append(CodecCase("128", "3A 82 80 00 60 0A"))  # первая 16-битная
    cases.append(CodecCase("-32769", "3A 83 FF 7F FF FF 60 0A"))  # первая 32-битная
    cases.append(CodecCase("-32768", "3A 82 00 80 60 0A"))  # последняя 16-битная снизу
    cases.append(CodecCase("32767", "3A 82 FF 7F 60 0A"))  # последняя 16-битная сверху
    cases.append(CodecCase("32768", "3A 83 00 80 00 00 60 0A"))  # первая 32-битная

    for i in range(len(cases)):
        var text = "DATA32 G\nvmthread MAIN\n{\n    MOVE32_32 " + cases[i].literal + " G\n}\n"
        check_valid_body(
            r,
            dir,
            "codec_" + String(i),
            text,
            cases[i].body_hex,
            4,
            "codec " + cases[i].literal,
        )


def test_label_forms(mut r: Reporter, dir: String) raises:
    """Метка назад/вперёд и разность A:B (LMSObject.cs:150-197, 214-262)."""
    # Метка назад: dist = 0 - 1 = -1 -> короткая форма (dist-1) & 0x3F = 0x3E
    check_valid_body(
        r,
        dir,
        "label_back",
        "vmthread MAIN\n{\nL1:\n    JR L1\n}\n",
        "40 3E 0A",
        0,
        "label_back",
    )
    # Метка вперёд: заглушка 0x83+4, патч = pos(L2) - (i+4) = 6 - 6 = 0
    check_valid_body(
        r,
        dir,
        "label_fwd",
        "vmthread MAIN\n{\n    JR L2\nL2:\n}\n",
        "40 83 00 00 00 00 0A",
        0,
        "label_fwd",
    )
    # Разность A:B: всегда 0x83+4, значение pos(B)-pos(A) = 1 без поправок
    check_valid_body(
        r,
        dir,
        "label_diff",
        "DATA32 G\nvmthread MAIN\n{\nA:\n    NOP\nB:\n    MOVE32_32 A:B G\n}\n",
        "01 3A 83 01 00 00 00 60 0A",
        4,
        "label_diff",
    )


def test_textbox_quirk(mut r: Reporter, dir: String) raises:
    """Второй байт мнемоники кодируется как константа: TEXTBOX = 84 81 20."""
    check_valid_body(
        r,
        dir,
        "textbox",
        "DATA8 T8\nDATA16 T16\nvmthread MAIN\n{\n    UI_DRAW TEXTBOX 0 0 0 0 T8 100 T8 T16\n}\n",
        "84 81 20 00 00 00 00 60 81 64 60 62 0A",
        4,
        "textbox",
    )


def test_assemble_lmsb_output_path(mut r: Reporter, dir: String) raises:
    """assemble_lmsb пишет <Имя>.rbf рядом с .lmsb и молчит на ошибке."""
    var ok_src = write_fixture(dir, "lmsb_ok", VALID_MINIMAL)
    var ok_dst = rbf_path_for(ok_src)
    if ok_dst != dir + "/lmsb_ok.rbf":
        r.fail("lmsb_ok: rbf_path_for = " + ok_dst)
    var errors = assemble_lmsb(ok_src)
    if len(errors) > 0:
        r.fail("lmsb_ok: ошибки на валидном входе: " + String("\n    ").join(errors))
    if not exists(ok_dst):
        r.fail("lmsb_ok: assemble_lmsb не создал " + ok_dst)

    var bad_src = write_fixture(dir, "lmsb_bad", "vmthread MAIN\n{\nBOGUS_OPCODE 1\n}\n")
    var bad_dst = rbf_path_for(bad_src)
    var bad_errors = assemble_lmsb(bad_src)
    if len(bad_errors) == 0:
        r.fail("lmsb_bad: assemble_lmsb вернул пустой errorList на невалидном входе")
    if exists(bad_dst):
        r.fail("lmsb_bad: assemble_lmsb создал .rbf при ошибке")


# ---------------------------------------------------------------------------
# Атомарная публикация .rbf (дефект data-loss при сбое записи)
# ---------------------------------------------------------------------------


def cpath(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(s.byte_length()):
        out.append(_byte_at(s, i))
    out.append(UInt8(0))
    return out^


def lstat_mode(path: String) raises -> Int:
    """st_mode через stdlib lstat (без ручных смещений struct stat); -1 — нет файла."""
    try:
        return Int(lstat(path).st_mode)
    except e:
        return -1


def is_root() -> Bool:
    """uid 0: проверки прав не-владельцем (EACCES) неприменимы — честно пропускаем."""
    return Int(getuid()) == 0


def chmod_path(path: String, mode: Int) raises:
    # chmod(2): int chmod(const char*, mode_t) -> C int/mode_t, точные типы ABI.
    var p = cpath(path)
    if external_call["chmod", Int32](p.unsafe_ptr(), UInt32(mode)) != 0:
        raise Error("test: chmod failed for " + path)


def temp_leftovers(dir: String, base: String) raises -> List[String]:
    """Имена оставшихся временных файлов публикации (*.tmp.*) в каталоге."""
    var out = List[String]()
    for name in listdir(dir):
        var n = String(name)
        if n.startswith("." + base + ".tmp."):
            out.append(n)
    return out^


def test_atomic_publish_preserves_mode(mut r: Reporter, dir: String) raises:
    """Успешная публикация сохраняет права существующего .rbf и не оставляет temp."""
    var src = write_fixture(dir, "atomic_mode", VALID_MINIMAL)
    var dst = dir + "/atomic_mode.rbf"
    write_text(dst, "old image")
    chmod_path(dst, 0o640)
    var errors = assemble_file(src, dst)
    if len(errors) > 0:
        r.fail("atomic_mode: ошибки: " + String("\n    ").join(errors))
        return
    var mode = lstat_mode(dst)
    if (mode & 0o7777) != 0o640:
        r.fail("atomic_mode: права " + String(mode & 0o7777) + " != 640")
    if len(temp_leftovers(dir, "atomic_mode.rbf")) != 0:
        r.fail("atomic_mode: остался временный файл")


def test_atomic_publish_fresh_permissions(mut r: Reporter, dir: String) raises:
    """Новая цель получает обычные права (0666 с umask), не 0600 от mkstemp."""
    var src = write_fixture(dir, "atomic_fresh", VALID_MINIMAL)
    var dst = dir + "/atomic_fresh.rbf"
    if exists(dst):
        r.fail("atomic_fresh: scratch уже содержит " + dst)
        return
    var errors = assemble_file(src, dst)
    if len(errors) > 0:
        r.fail("atomic_fresh: ошибки: " + String("\n    ").join(errors))
        return
    var mode = lstat_mode(dst)
    if (mode & S_IFMT) != 0x8000:
        r.fail("atomic_fresh: не обычный файл, mode=" + String(mode))
    # mkstemp даёт 0600; публикация должна выставить 0666&~umask (минимум rw для owner).
    if (mode & 0o600) != 0o600:
        r.fail("atomic_fresh: нет прав rw для владельца, mode=" + String(mode & 0o7777))
    if len(temp_leftovers(dir, "atomic_fresh.rbf")) != 0:
        r.fail("atomic_fresh: остался временный файл")


def test_symlink_target_refused(mut r: Reporter, dir: String) raises:
    """Символическая ссылка как цель: явная ошибка, ссылка и её цель не тронуты.

    Явное отличие от прежнего open(path, "w") (шёл по ссылке): атомарный rename
    заменил бы саму ссылку, поэтому случай честно отклоняется.
    """
    var src = write_fixture(dir, "symlink_out", VALID_MINIMAL)
    var real = dir + "/symlink_real.rbf"
    var link = dir + "/symlink_out.rbf"
    write_text(real, "REAL TARGET CONTENT")
    var before = hex_of(read_bytes(real))
    var tgt = cpath(real)
    var lnk = cpath(link)
    if external_call["symlink", Int32](tgt.unsafe_ptr(), lnk.unsafe_ptr()) != 0:
        r.fail("symlink_out: не удалось создать ссылку в scratch")
        return

    var errors = assemble_file(src, link)
    if len(errors) == 0:
        r.fail("symlink_out: ожидалась ошибка для symlink-цели")
    elif errors[0].find("symbolic link") == -1:
        r.fail("symlink_out: неожиданный текст ошибки: " + errors[0])
    if lstat_mode(link) & S_IFMT != S_IFLNK:
        r.fail("symlink_out: ссылка заменена/удалена")
    if hex_of(read_bytes(real)) != before:
        r.fail("symlink_out: содержимое цели ссылки изменено")
    if len(temp_leftovers(dir, "symlink_out.rbf")) != 0:
        r.fail("symlink_out: остался временный файл")


def test_failed_write_preserves_existing(mut r: Reporter, dir: String) raises:
    """Сбой записи временного файла (каталог только для чтения) не трогает цель.

    Это in-process симуляция OS-сбоя: mkstemp в каталоге без права записи
    падает до rename, существующий .rbf обязан остаться побайтно прежним.
    Полноценные RLIMIT_FSIZE/short-write сценарии — tools/tests/test_asm_write.py.
    """
    var sub = dir + "/ro_dir"
    mkdir(sub)
    var src = write_fixture(sub, "ro_out", VALID_MINIMAL)
    var dst = sub + "/ro_out.rbf"
    write_text(dst, "SENTINEL: must survive write failure")
    var before = hex_of(read_bytes(dst))
    chmod_path(sub, 0o500)  # r-x: создать новый файл нельзя
    var errors = List[String]()
    try:
        errors = assemble_file(src, dst)
    except e:
        chmod_path(sub, 0o700)
        r.fail("ro_out: assemble_file бросил наружу: " + String(e))
        return
    chmod_path(sub, 0o700)
    if is_root():
        # root обходит права каталога: сбой mkstemp не воспроизводится.
        print("  SKIP ro_out (uid=0): права каталога не действуют для root")
        return
    if len(errors) == 0:
        r.fail("ro_out: ожидалась ошибка записи в read-only каталог")
    elif errors[0].find("cannot create temporary file") == -1:
        # Отрицательный C int от mkstemp не должен выглядеть как валидный fd.
        r.fail("ro_out: неожиданный текст ошибки mkstemp: " + errors[0])
    if not exists(dst):
        r.fail("ro_out: существующий .rbf удалён при сбое записи")
        return
    if hex_of(read_bytes(dst)) != before:
        r.fail("ro_out: существующий .rbf изменён при сбое записи")
    if len(temp_leftovers(sub, "ro_out.rbf")) != 0:
        r.fail("ro_out: остался временный файл после сбоя")


def test_failed_write_creates_no_output(mut r: Reporter, dir: String) raises:
    """Сбой записи при отсутствующей цели не создаёт свежий .rbf."""
    var sub = dir + "/ro_dir2"
    mkdir(sub)
    var src = write_fixture(sub, "ro_new", VALID_MINIMAL)
    var dst = sub + "/ro_new.rbf"
    chmod_path(sub, 0o500)
    var errors = List[String]()
    try:
        errors = assemble_file(src, dst)
    except e:
        chmod_path(sub, 0o700)
        r.fail("ro_new: assemble_file бросил наружу: " + String(e))
        return
    chmod_path(sub, 0o700)
    if is_root():
        print("  SKIP ro_new (uid=0): права каталога не действуют для root")
        return
    if len(errors) == 0:
        r.fail("ro_new: ожидалась ошибка записи в read-only каталог")
    if exists(dst):
        r.fail("ro_new: .rbf создан при сбое записи")
    if len(temp_leftovers(sub, "ro_new.rbf")) != 0:
        r.fail("ro_new: остался временный файл после сбоя")


def test_readonly_target_not_replaced(mut r: Reporter, dir: String) raises:
    """Существующий .rbf без права записи (0444) не подменяется rename-ом.

    Прежний open(path, "w") падал с EACCES; атомарный rename заменил бы файл
    молча. Регрессия: отказ с внятным текстом, содержимое/права не тронуты,
    временных файлов нет. Под root access(W_OK) успешен (как и open) — тогда
    проверяется только сохранение поведения «замена разрешена», без ложных
    утверждений о EACCES.
    """
    var src = write_fixture(dir, "ro_target", VALID_MINIMAL)
    var dst = dir + "/ro_target.rbf"
    write_text(dst, "SENTINEL: readonly target must not be replaced")
    chmod_path(dst, 0o444)
    var before = hex_of(read_bytes(dst))
    var before_mode = lstat_mode(dst) & 0o7777
    var errors = List[String]()
    try:
        errors = assemble_file(src, dst)
    except e:
        chmod_path(dst, 0o644)
        r.fail("ro_target: assemble_file бросил наружу: " + String(e))
        return
    var after_mode = lstat_mode(dst) & 0o7777
    chmod_path(dst, 0o644)
    if is_root():
        print("  SKIP ro_target EACCES (uid=0): root пишет в файл 0444, как и open")
        return
    if len(errors) == 0:
        r.fail("ro_target: read-only файл молча заменён атомарным rename")
    elif errors[0].find("not writable") == -1:
        r.fail("ro_target: неожиданный текст ошибки: " + errors[0])
    if hex_of(read_bytes(dst)) != before:
        r.fail("ro_target: содержимое read-only .rbf изменено")
    if after_mode != before_mode:
        r.fail("ro_target: права read-only .rbf изменены: " + String(after_mode))
    if len(temp_leftovers(dir, "ro_target.rbf")) != 0:
        r.fail("ro_target: остался временный файл после отказа")


# ---------------------------------------------------------------------------
# Точка входа
# ---------------------------------------------------------------------------


def main() raises:
    var r = Reporter()

    var work = "/tmp/bp_asm_test_" + String(Int(perf_counter_ns()))
    mkdir(work)
    print("ASM TEST work dir: " + work)

    test_failure_creates_no_output(r, work)
    test_existing_output_preserved(r, work)
    test_valid_minimal_thread(r, work)
    test_codec_thresholds(r, work)
    test_label_forms(r, work)
    test_textbox_quirk(r, work)
    test_assemble_lmsb_output_path(r, work)
    test_atomic_publish_preserves_mode(r, work)
    test_atomic_publish_fresh_permissions(r, work)
    test_symlink_target_refused(r, work)
    test_readonly_target_not_replaced(r, work)
    test_failed_write_preserves_existing(r, work)
    test_failed_write_creates_no_output(r, work)

    if r.count() > 0:
        print("ASM TESTS FAILED: " + String(r.count()) + " ошибок")
        var n = r.count()
        if n > FAILS_LIMIT:
            n = FAILS_LIMIT
        for i in range(n):
            print("  - " + r.fails[i])
        if r.count() > FAILS_LIMIT:
            print("  ... и ещё " + String(r.count() - FAILS_LIMIT))
        raise Error("ASM TESTS FAILED")

    print("ASM TESTS OK")
