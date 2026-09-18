"""Заливка .rbf на LEGO EV3 по USB через /dev/hidraw (`bp flash`).

Порт старого Python-пути (`/home/ssssq/Projects/letovo_projects/ev3tool.py`,
libusb) и C#-пути (`CleverDeploy/EV3Connection.cs`,
`Clever/Brick/Communication/EV3Connection{,USB}.cs`) на чистый Mojo:
транспорт — hidraw вместо libusb, кадры и последовательность 1:1.

Протокол — docs/06-hidraw-usb-notes.md. Железа для проверки нет, поэтому
без кирпича тестируется только framing/парсинг (src/bp/flash_test.mojo)
и сухой режим (`device="dry"` или `BP_FLASH_DRY=1`).

Карта кадра (всё little-endian):
  HID-отчёт (1024 Б): [0x00][длина-пакета u16][пакет][pad 0x00...]
  system-пакет:       [счётчик u16][0x01][команда u8][аргументы...]
  direct-пакет:       [счётчик u16][0x00][globals u8][gb_hi/lb u8][байткод]
"""

from std.ffi import external_call
from std.os import getenv, listdir

from bp.lexer import _byte_at
from bp.util import base_name, strip_ext


# ============================================================================
# Константы протокола (источники — в docs/06-hidraw-usb-notes.md §2-§4)
# ============================================================================

comptime EV3_VID = 0x0694
comptime EV3_PID = 0x0005

comptime REPORT_SIZE = 1024  # размер HID-отчёта EV3 (EV3ConnectionUSB.cs)

comptime MSG_SYSTEM = 0x01  # SYSTEM_COMMAND_REPLY
comptime MSG_DIRECT = 0x00  # DIRECT_COMMAND_REPLY

comptime SYS_BEGIN_DOWNLOAD = 0x92
comptime SYS_CONTINUE_DOWNLOAD = 0x93
comptime SYS_CREATE_DIR = 0x9B
comptime SYS_DELETE_FILE = 0x9C

comptime SYS_SUCCESS = 0x00
comptime SYS_END_OF_FILE = 0x08

comptime RPL_SYS_OK = 0x03  # SYSTEM_REPLY (EV3Connection.cs:101)
comptime RPL_SYS_ALT = 0x05  # SYSTEM_REPLY_NO_ERROR (принимается там же)
comptime RPL_DIRECT_OK = 0x02  # DIRECT_REPLY (DirectCommand)
comptime RPL_DIRECT_ERR = 0x04  # DIRECT_REPLY_ERROR (ошибка VM)

comptime CHUNK_SIZE = 900  # чанк ev3tool.py / CreateEV3File (C#)
comptime REPLY_TIMEOUT_MS = 5000  # таймаут ответа (ev3tool.py)
comptime MAX_ATTEMPTS = 3  # ретраи команды при таймауте

# Куда кладётся файл на кирпиче по умолчанию. Имя каталога — из ТЗ
# (в найденном коде его нет: clever.sh использует ../prjs/test123/,
# Clever GUI — ../prjs/<ПапкаПроекта>/; см. доку §5).
comptime DEFAULT_DEST_DIR = "../prjs/BrkProg_SAVE/"

comptime O_RDONLY = 0
comptime O_RDWR = 2


# ============================================================================
# Кодирование direct-параметров (ByteCodeBuffer.cs; ВНИМАНИЕ: строка здесь —
# 0x84..., а в файле .rbf — 0x80...; docs/04 §3.4 vs дока §4)
# ============================================================================

def encode_const(n: Int) -> List[UInt8]:
    """ByteCodeBuffer.CONST: кратчайшая форма константы."""
    var out = List[UInt8]()
    if -32 <= n <= 31:
        out.append(UInt8(n & 0x3F))
    elif -128 <= n <= 127:
        out.append(UInt8(0x81))
        out.append(UInt8(n & 0xFF))
    elif -32768 <= n <= 32767:
        out.append(UInt8(0x82))
        out.append(UInt8(n & 0xFF))
        out.append(UInt8((n >> 8) & 0xFF))
    else:
        out.append(UInt8(0x83))
        out.append(UInt8(n & 0xFF))
        out.append(UInt8((n >> 8) & 0xFF))
        out.append(UInt8((n >> 16) & 0xFF))
        out.append(UInt8((n >> 24) & 0xFF))
    return out^


def encode_globvar(v: Int) -> List[UInt8]:
    """ByteCodeBuffer.GLOBVAR: ссылка на глобальную переменную VM."""
    var out = List[UInt8]()
    if v <= 31:
        out.append(UInt8((v & 0x1F) | 0x60))
    elif v <= 255:
        out.append(UInt8(0xE1))
        out.append(UInt8(v & 0xFF))
    elif v <= 65535:
        out.append(UInt8(0xE2))
        out.append(UInt8(v & 0xFF))
        out.append(UInt8((v >> 8) & 0xFF))
    else:
        out.append(UInt8(0xE3))
        out.append(UInt8(v & 0xFF))
        out.append(UInt8((v >> 8) & 0xFF))
        out.append(UInt8((v >> 16) & 0xFF))
        out.append(UInt8((v >> 24) & 0xFF))
    return out^


def encode_dc_string(s: String) -> List[UInt8]:
    """ByteCodeBuffer.STRING: 0x84 + байты + 0x00 (только для direct-команд)."""
    var out = List[UInt8]()
    out.append(UInt8(0x84))
    for i in range(s.byte_length()):
        var b = _byte_at(s, i)
        if b == 0 or Int(b) > 255:
            out.append(UInt8(1))  # как BinaryBuffer: вне 1..255 -> char(1)
        else:
            out.append(b)
    out.append(UInt8(0))
    return out^


def dest_cstr(dest: String) -> List[UInt8]:
    """Путь на кирпиче как C-строка (байты + NUL)."""
    var out = List[UInt8]()
    for i in range(dest.byte_length()):
        out.append(_byte_at(dest, i))
    out.append(UInt8(0))
    return out^


# ============================================================================
# Кадры: system/direct-пакеты и HID-отчёты
# ============================================================================

def build_system_packet(counter: Int, cmd: Int, args: List[UInt8]) -> List[UInt8]:
    """EV3Connection.SystemCommand: [ctr u16][0x01][cmd][args]."""
    var out = List[UInt8]()
    out.append(UInt8(counter & 0xFF))
    out.append(UInt8((counter >> 8) & 0xFF))
    out.append(UInt8(MSG_SYSTEM))
    out.append(UInt8(cmd & 0xFF))
    for i in range(len(args)):
        out.append(args[i])
    return out^


def build_direct_packet(
    counter: Int, bytecode: List[UInt8], global_bytes: Int, local_bytes: Int
) -> List[UInt8]:
    """EV3Connection.DirectCommand: [ctr u16][0x00][globals][gb_hi/lb][bc]."""
    var out = List[UInt8]()
    out.append(UInt8(counter & 0xFF))
    out.append(UInt8((counter >> 8) & 0xFF))
    out.append(UInt8(MSG_DIRECT))
    out.append(UInt8(global_bytes & 0xFF))
    out.append(UInt8(((global_bytes >> 8) & 0x03) + (local_bytes << 2)))
    for i in range(len(bytecode)):
        out.append(bytecode[i])
    return out^


def build_hid_report(packet: List[UInt8]) raises -> List[UInt8]:
    """EV3ConnectionUSB.SendPacket: [0x00][len u16 LE][пакет] + pad до 1024.

    Байт 0 — номер отчёта (в C# _outputReport[0] остаётся 0), байты 1-2 —
    длина пакета, данные с байта 3, хвост — нули до OutputReportByteLength.
    """
    if len(packet) > REPORT_SIZE - 3:
        raise Error("flash: пакет больше HID-отчёта")
    var out = List[UInt8](length=REPORT_SIZE, fill=UInt8(0))
    out[1] = UInt8(len(packet) & 0xFF)
    out[2] = UInt8((len(packet) >> 8) & 0xFF)
    for i in range(len(packet)):
        out[3 + i] = packet[i]
    return out^


def parse_hid_report(raw: List[UInt8]) raises -> List[UInt8]:
    """EV3ConnectionUSB.ReceivePacket: вырезать пакет из HID-отчёта."""
    if len(raw) < 3:
        raise Error("flash: короткий HID-отчёт")
    var size = Int(raw[1]) | (Int(raw[2]) << 8)
    if size <= 0 or size > len(raw) - 3:
        raise Error("flash: плохая длина в HID-отчёте")
    var out = List[UInt8]()
    for i in range(size):
        out.append(raw[3 + i])
    return out^


def check_system_reply(packet: List[UInt8], counter: Int) raises -> List[UInt8]:
    """Проверка ответа на system-команду; возвращает [статус][данные...].

    EV3Connection.SystemCommand: длина >= 3, счётчик совпадает, тип 0x03/0x05,
    длина >= 5; дальше ответ идёт с позиции 3: [статус][данные...].
    """
    if len(packet) < 3:
        raise Error("flash: ответ без счётчика")
    var ctr = Int(packet[0]) | (Int(packet[1]) << 8)
    if ctr != counter:
        raise Error("flash: чужой счётчик в ответе")
    var t = packet[2]
    if t != UInt8(RPL_SYS_OK) and t != UInt8(RPL_SYS_ALT):
        raise Error("flash: ответ неверного типа")
    if len(packet) < 5:
        raise Error("flash: оборванный ответ")
    var out = List[UInt8]()
    for i in range(3, len(packet)):
        out.append(packet[i])
    return out^


def check_direct_reply(
    packet: List[UInt8], counter: Int, global_bytes: Int
) raises -> List[UInt8]:
    """Проверка ответа на direct-команду; возвращает global-данные."""
    if len(packet) < 3:
        raise Error("flash: ответ без счётчика")
    var ctr = Int(packet[0]) | (Int(packet[1]) << 8)
    if ctr != counter:
        raise Error("flash: чужой счётчик в ответе")
    if packet[2] == UInt8(RPL_DIRECT_ERR):
        raise Error("flash: VM отклонила direct-команду")
    if packet[2] != UInt8(RPL_DIRECT_OK):
        raise Error("flash: ответ неверного типа")
    if len(packet) != global_bytes + 3:
        raise Error("flash: неверный размер ответа")
    var out = List[UInt8]()
    for i in range(3, len(packet)):
        out.append(packet[i])
    return out^


def check_download_status(reply: List[UInt8], what: String) raises -> Int:
    """Статус BEGIN/CONTINUE_DOWNLOAD: reply[0] SUCCESS/END_OF_FILE, handle=reply[1]."""
    if len(reply) < 2:
        raise Error("flash: короткий ответ на " + what)
    if reply[0] != UInt8(SYS_SUCCESS) and reply[0] != UInt8(SYS_END_OF_FILE):
        raise Error("flash: " + what + " статус=" + String(Int(reply[0])))
    return Int(reply[1])


# ============================================================================
# План заливки: BEGIN_DOWNLOAD + CONTINUE_DOWNLOAD* (CreateEV3File 1:1)
# ============================================================================

def begin_first_len(total: Int, dest_cstr_len: Int, chunk: Int) -> Int:
    """Сколько байтов файла уходит в первый кадр (ev3tool.py: upload)."""
    var room = chunk - dest_cstr_len
    if room < 0:
        room = 0
    if total < room:
        return total
    return room


def continue_ranges(total: Int, first: Int, chunk: Int) -> List[Tuple[Int, Int]]:
    """Смещения (pos, len) CONTINUE-кадров после первого."""
    var out = List[Tuple[Int, Int]]()
    var pos = first
    while pos < total:
        var n = total - pos
        if n > chunk:
            n = chunk
        out.append((pos, n))
        pos += n
    return out^


def build_begin_args(
    total: Int, dest: List[UInt8], data: List[UInt8], first: Int
) -> List[UInt8]:
    """Аргументы BEGIN_DOWNLOAD: [размер u32 LE][путь NUL][первые байты]."""
    var out = List[UInt8]()
    out.append(UInt8(total & 0xFF))
    out.append(UInt8((total >> 8) & 0xFF))
    out.append(UInt8((total >> 16) & 0xFF))
    out.append(UInt8((total >> 24) & 0xFF))
    for i in range(len(dest)):
        out.append(dest[i])
    for i in range(first):
        out.append(data[i])
    return out^


def build_continue_args(
    handle: Int, data: List[UInt8], pos: Int, n: Int
) -> List[UInt8]:
    """Аргументы CONTINUE_DOWNLOAD: [handle][байты]."""
    var out = List[UInt8]()
    out.append(UInt8(handle & 0xFF))
    for i in range(n):
        out.append(data[pos + i])
    return out^


def build_run_bytecode(dest: String) -> List[UInt8]:
    """Байткод запуска (EV3Brick.xaml.cs: RunEV3File): FILE LOAD_IMAGE в
    слот 1 + opPROGRAM_START слот 1. globals=10, locals=0."""
    var out = List[UInt8]()
    out.append(UInt8(0xC0))  # opFILE
    var c8 = encode_const(0x08)  # LOAD_IMAGE
    for i in range(len(c8)):
        out.append(c8[i])
    var c1 = encode_const(1)  # слот 1
    for i in range(len(c1)):
        out.append(c1[i])
    var path = encode_dc_string(dest)
    for i in range(len(path)):
        out.append(path[i])
    var g0 = encode_globvar(0)
    for i in range(len(g0)):
        out.append(g0[i])
    var g4 = encode_globvar(4)
    for i in range(len(g4)):
        out.append(g4[i])
    out.append(UInt8(0x03))  # opPROGRAM_START
    for i in range(len(c1)):
        out.append(c1[i])
    for i in range(len(g0)):
        out.append(g0[i])
    for i in range(len(g4)):
        out.append(g4[i])
    var c0 = encode_const(0)
    for i in range(len(c0)):
        out.append(c0[i])
    return out^


def brick_dest_for(rbf_path: String) -> String:
    """Путь на кирпиче по умолчанию: каталог + имя .rbf без каталогов."""
    var stem = strip_ext(base_name(rbf_path))
    return DEFAULT_DEST_DIR + stem + ".rbf"


# ============================================================================
# Поиск кирпича: /sys/class/hidraw/*/device/uevent (без libusb)
# ============================================================================

def is_ev3_uevent(text: String) -> Bool:
    """HID_ID=<bus>:<vid>:<pid> с VID 0694 / PID 0005 (hex, регистр любой)."""
    var lines = text.split("\n")
    for i in range(len(lines)):
        var line = String(lines[i])
        if not line.startswith("HID_ID="):
            continue
        var parts = String(line.split("=")[1]).split(":")
        if len(parts) != 3:
            continue
        var vid = String(parts[1]).upper()
        var pid = String(parts[2]).upper()
        if vid.endswith("0694") and pid.endswith("0005"):
            return True
    return False


def list_ev3_devices() raises -> List[String]:
    """Первый подходящий /dev/hidraw* с VID:PID EV3 (пусто — нет кирпича)."""
    var out = List[String]()
    var ents: List[String]
    try:
        var raw = listdir("/sys/class/hidraw")
        ents = List[String]()
        for i in range(len(raw)):
            ents.append(String(raw[i]))
    except:
        return out^
    for i in range(len(ents)):
        var uevent = "/sys/class/hidraw/" + ents[i] + "/device/uevent"
        var text = String("")
        try:
            with open(uevent, "r") as f:
                text = f.read()
        except:
            continue
        if is_ev3_uevent(text):
            out.append("/dev/" + ents[i])
    return out^


# ============================================================================
# Бинарный ввод-вывод через libc (в Mojo 1.1 нет бинарного open: режимы
# только r/w/rw/a со String и UTF-8-валидацией при чтении, а .rbf — бинарный).
#
# Ограничение FFI Mojo 1.1: одно extern-имя — одна сигнатура на всю программу
# (иначе «existing function with conflicting signature», в т.ч. конфликт со
# внутренними open/read/write/close самого stdlib). Поэтому весь syscall-слой
# идёт через ЕДИНСТВЕННЫЙ символ `syscall` в форме (Int, Int, Ptr, Int) -> Int
# и ЕДИНСТВЕННЫЙ `usleep(Int) -> Int`:
#   openat:  syscall(257, AT_FDCWD, path_ptr, flags)   [openat вместо open]
#   read:    syscall(0, fd, buf_ptr, n)
#   write:   syscall(1, fd, buf_ptr, n)
#   close:   syscall(3, fd, dummy_ptr, 0)  (лишние аргументы variadic-функция
#            игнорирует; dummy — живой указатель, не NULL)
#   clock_gettime(CLOCK_MONOTONIC): syscall(228, 1, ts_ptr, 0)
# Номера — x86-64 Linux; O_NONBLOCK=2048.
# ============================================================================

comptime SYS_NR_READ = 0
comptime SYS_NR_WRITE = 1
comptime SYS_NR_CLOSE = 3
comptime SYS_NR_OPENAT = 257
comptime SYS_NR_CLOCK_GETTIME = 228
comptime AT_FDCWD = -100
comptime CLOCK_MONOTONIC = 1
comptime O_NONBLOCK = 2048


def sc(fd_or_nr: Int, a: Int, ptr: Pointer[UInt8, ...], b: Int) -> Int:
    # NOTE: единая форма вызова syscall; см. комментарий выше.
    return Int(external_call["syscall", Int](fd_or_nr, a, ptr, b))


def c_open(path: String, flags: Int) raises -> Int:
    var cstr = List[UInt8]()
    for i in range(path.byte_length()):
        cstr.append(_byte_at(path, i))
    cstr.append(UInt8(0))
    var fd = Int(
        external_call["syscall", Int](SYS_NR_OPENAT, AT_FDCWD, cstr.unsafe_ptr(), flags)
    )
    if fd < 0:
        raise Error("flash: не открыть " + path)
    return fd


def c_close(fd: Int):
    var dummy = List[UInt8](length=8, fill=UInt8(0))
    _ = sc(SYS_NR_CLOSE, fd, dummy.unsafe_ptr(), 0)


def c_read_full(fd: Int, n: Int) raises -> List[UInt8]:
    """Читать ровно n байтов (цикл: hidraw может отдать меньше)."""
    var out = List[UInt8]()
    var buf = List[UInt8](length=4096, fill=UInt8(0))
    var want = n
    while want > 0:
        var step = want
        if step > 4096:
            step = 4096
        var got = sc(SYS_NR_READ, fd, buf.unsafe_ptr(), step)
        if got <= 0:
            raise Error("flash: оборванное чтение")
        for i in range(got):
            out.append(buf[i])
        want -= got
    return out^


def c_write_all(fd: Int, data: List[UInt8]) raises:
    var pos = 0
    var buf = List[UInt8](length=4096, fill=UInt8(0))
    while pos < len(data):
        var n = len(data) - pos
        if n > 4096:
            n = 4096
        for i in range(n):
            buf[i] = data[pos + i]
        var got = sc(SYS_NR_WRITE, fd, buf.unsafe_ptr(), n)
        if got <= 0:
            raise Error("flash: оборванная запись")
        pos += got


def c_read_file(path: String) raises -> List[UInt8]:
    """Прочитать файл байтами (для .rbf: read_text падает на не-UTF-8)."""
    var fd = c_open(path, O_RDONLY)
    var out = List[UInt8]()
    var buf = List[UInt8](length=4096, fill=UInt8(0))
    try:
        while True:
            var got = sc(SYS_NR_READ, fd, buf.unsafe_ptr(), 4096)
            if got < 0:
                raise Error("flash: не прочитать " + path)
            if got == 0:
                break
            for i in range(got):
                out.append(buf[i])
    except e:
        c_close(fd)
        raise e
    c_close(fd)
    return out^


def timed_read_full(fd: Int, n: Int, timeout_ms: Int) raises -> List[UInt8]:
    """Читать ровно n байтов с неблокирующего fd.

    EAGAIN (-11) / EINTR (-4) — пауза ~1мс (usleep) и повтор, лимит повторов —
    timeout_ms. Обычный ответ кирпича приходит за миллисекунды; полный таймаут
    означает отсутствие кирпича.
    """
    var out = List[UInt8]()
    var buf = List[UInt8](length=4096, fill=UInt8(0))
    var want = n
    var waited = 0
    while want > 0:
        var step = want
        if step > 4096:
            step = 4096
        var rc = sc(SYS_NR_READ, fd, buf.unsafe_ptr(), step)
        if rc > 0:
            for i in range(rc):
                out.append(buf[i])
            want -= rc
        elif rc == -11 or rc == -4:
            _ = external_call["usleep", Int](1000)
            waited += 1
            if waited >= timeout_ms:
                raise Error("flash: нет ответа от кирпича (таймаут)")
        else:
            raise Error("flash: оборванное чтение")
    return out^


# ============================================================================
# Живой обмен: отправка пакетов, ожидание ответа со своим счётчиком, ретраи
# ============================================================================

def hid_send_packet(fd: Int, packet: List[UInt8]) raises:
    var report = build_hid_report(packet)
    c_write_all(fd, report)


def hid_recv_packet(fd: Int, timeout_ms: Int) raises -> List[UInt8]:
    var raw = timed_read_full(fd, REPORT_SIZE, timeout_ms)
    return parse_hid_report(raw)


def recv_matching(
    fd: Int, counter: Int, timeout_ms: Int
) raises -> List[UInt8]:
    """Ждать пакет со своим счётчиком до дедлайна (чужие пропускать)."""
    var left = timeout_ms
    while True:
        var step = left
        if step > 1000:
            step = 1000
        var packet: List[UInt8]
        try:
            packet = hid_recv_packet(fd, step)
        except:
            raise Error("flash: нет ответа от кирпича (таймаут)")
        left -= step
        if len(packet) < 3:
            if left <= 0:
                raise Error("flash: нет ответа от кирпича (таймаут)")
            continue
        var ctr = Int(packet[0]) | (Int(packet[1]) << 8)
        if ctr != counter:
            if left <= 0:
                raise Error("flash: нет ответа от кирпича (таймаут)")
            continue
        return packet^


def sys_cmd(
    fd: Int, counter: Int, cmd: Int, args: List[UInt8], attempts: Int
) raises -> Tuple[Int, List[UInt8]]:
    """System-команда с ретраями при таймауте. Возвращает (счётчик, ответ)."""
    var ctr = counter
    var attempt = 0
    while True:
        ctr += 1
        hid_send_packet(fd, build_system_packet(ctr, cmd, args))
        var packet: List[UInt8]
        try:
            packet = recv_matching(fd, ctr, REPLY_TIMEOUT_MS)
        except:
            attempt += 1
            if attempt >= attempts:
                raise Error("flash: нет ответа от кирпича (таймаут)")
            continue
        return (ctr, check_system_reply(packet, ctr))


def direct_cmd(
    fd: Int,
    counter: Int,
    bytecode: List[UInt8],
    global_bytes: Int,
    attempts: Int,
) raises -> Tuple[Int, List[UInt8]]:
    """Direct-команда с ретраями. Возвращает (счётчик, global-данные)."""
    var ctr = counter
    var attempt = 0
    while True:
        ctr += 1
        hid_send_packet(fd, build_direct_packet(ctr, bytecode, global_bytes, 0))
        var packet: List[UInt8]
        try:
            packet = recv_matching(fd, ctr, REPLY_TIMEOUT_MS)
        except:
            attempt += 1
            if attempt >= attempts:
                raise Error("flash: нет ответа от кирпича (таймаут)")
            continue
        return (ctr, check_direct_reply(packet, ctr, global_bytes))


# ============================================================================
# Печать кадров (сухой режим)
# ============================================================================

def hex_of(data: List[UInt8]) -> String:
    var digits = String("0123456789abcdef")
    var out = String("")
    for i in range(len(data)):
        var b = Int(data[i])
        out += String(digits[byte=(b >> 4) : (b >> 4) + 1])
        out += String(digits[byte=(b & 0xF) : (b & 0xF) + 1])
    return out^


def print_frame(counter: Int, what: String, packet: List[UInt8]) raises:
    var report = build_hid_report(packet)
    print(
        "[" + String(counter) + "] " + what + " пакет=" + String(len(packet))
        + " отчёт=" + String(len(report)) + " " + hex_of(packet)
    )


# ============================================================================
# Точка входа: bp flash <file.rbf> [device]
# ============================================================================

def cmd_flash(rbf_path: String, device: String) raises -> Int:
    """Залить .rbf на кирпич и запустить.

    device = "" — автовыбор первого EV3 в /dev/hidraw*; "dry" (или env
    BP_FLASH_DRY=1) — только печатать кадры, не открывать устройство.
    Возвращает 0 при успехе, при ошибке — raise.
    """
    var dry = device == "dry" or getenv("BP_FLASH_DRY", "0") == "1"
    var data = c_read_file(rbf_path)
    if len(data) == 0:
        raise Error("flash: пустой файл " + rbf_path)

    var dest = brick_dest_for(rbf_path)
    var dest_b = dest_cstr(dest)
    var total = len(data)
    var first = begin_first_len(total, len(dest_b), CHUNK_SIZE)
    var ranges = continue_ranges(total, first, CHUNK_SIZE)
    var run_bc = build_run_bytecode(dest)

    var counter = 0

    if dry:
        print("flash: dry run")
        print("файл: " + rbf_path + " (" + String(total) + " байт) -> " + dest)
        counter += 1
        var mk = build_system_packet(counter, SYS_CREATE_DIR, dest_cstr(DEFAULT_DEST_DIR))
        print_frame(counter, "CREATE_DIR " + DEFAULT_DEST_DIR, mk)
        counter += 1
        var bargs = build_begin_args(total, dest_b, data, first)
        print_frame(
            counter,
            "BEGIN_DOWNLOAD total=" + String(total) + " first=" + String(first),
            build_system_packet(counter, SYS_BEGIN_DOWNLOAD, bargs),
        )
        for i in range(len(ranges)):
            counter += 1
            var pos = ranges[i][0]
            var n = ranges[i][1]
            var cargs = build_continue_args(0, data, pos, n)
            print_frame(
                counter,
                "CONTINUE_DOWNLOAD pos=" + String(pos) + " n=" + String(n),
                build_system_packet(counter, SYS_CONTINUE_DOWNLOAD, cargs),
            )
        counter += 1
        print_frame(
            counter,
            "direct PROGRAM_START globals=10",
            build_direct_packet(counter, run_bc, 10, 0),
        )
        print("flash: dry run OK")
        return 0

    var dev = device
    if dev == "":
        var found = list_ev3_devices()
        if len(found) == 0:
            raise Error("flash: EV3 не найден (проверь USB-кабель и udev)")
        dev = found[0]
    elif dev.find("/") == -1:
        dev = "/dev/" + dev
    print("flash: " + rbf_path + " (" + String(total) + " байт) -> " + dest + " via " + dev)

    var fd = c_open(dev, O_RDWR + O_NONBLOCK)
    try:
        # Каталог под программу (best-effort: может уже существовать).
        try:
            var r = sys_cmd(fd, counter, SYS_CREATE_DIR, dest_cstr(DEFAULT_DEST_DIR), 1)
            counter = r[0]
        except:
            counter += 1
        # BEGIN_DOWNLOAD: размер + путь + первый кусок; ответ даёт handle.
        var bargs = build_begin_args(total, dest_b, data, first)
        var rb = sys_cmd(fd, counter, SYS_BEGIN_DOWNLOAD, bargs, MAX_ATTEMPTS)
        counter = rb[0]
        var handle = check_download_status(rb[1], "BEGIN_DOWNLOAD")
        # CONTINUE_DOWNLOAD*, пока не уйдёт весь файл.
        for i in range(len(ranges)):
            var pos = ranges[i][0]
            var n = ranges[i][1]
            var rc = sys_cmd(
                fd, counter, SYS_CONTINUE_DOWNLOAD,
                build_continue_args(handle, data, pos, n), MAX_ATTEMPTS,
            )
            counter = rc[0]
            _ = check_download_status(rc[1], "CONTINUE_DOWNLOAD")
            print("flash: " + String(pos + n) + "/" + String(total))
        # Запуск: FILE LOAD_IMAGE + PROGRAM_START (без ретраев, чтобы не
        # стартовать программу дважды).
        var rr = direct_cmd(fd, counter, run_bc, 10, 1)
        counter = rr[0]
        _ = rr[1]
    except e:
        c_close(fd)
        raise e
    c_close(fd)
    print("flash: OK, программа запущена")
    return 0
