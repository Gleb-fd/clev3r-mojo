"""Тест framing/парсинга заливки (без железа).

Запуск из корня репо:
  uv run mojo run src/bp/flash_test.mojo
  BP_FLASH_DRY=1 uv run mojo run src/bp/flash_test.mojo
Печатает FLASH_TEST OK при успехе.
"""

from std.os import getenv, mkdir, listdir, remove, rmdir
from std.ffi import external_call
from bp.util import write_text

from bp.flash import (
    SYS_BEGIN_DOWNLOAD,
    SYS_CONTINUE_DOWNLOAD,
    SYS_CREATE_DIR,
    TRANSPORT_STREAM,
    TRANSPORT_USB,
    WIFI_HANDSHAKE_REQ,
    WIFI_HANDSHAKE_RSP,
    begin_first_len,
    brick_dest_for,
    build_begin_args,
    build_continue_args,
    build_direct_packet,
    build_hid_report,
    build_run_bytecode,
    build_sockaddr_in,
    build_sockaddr_rc,
    build_stream_frame,
    build_system_packet,
    c_close,
    c_read_file,
    c_read_full,
    c_write_all,
    check_create_dir_status,
    check_direct_reply,
    check_download_status,
    check_system_reply,
    classify_target,
    cmd_flash,
    continue_ranges,
    dest_cstr,
    is_retry_safe,
    advance_counter,
    wire_counter,
    sys_cmd,
    direct_cmd,
    open_transport,
    encode_const,
    encode_dc_string,
    encode_globvar,
    hex_of,
    is_ev3_uevent,
    parse_hid_report,
    parse_ipv4,
    parse_mac,
    str_bytes,
)


def check(cond: Bool, what: String) raises:
    if not cond:
        raise Error("FAIL: " + what)
    print("ok: " + what)


def expect_bytes(got: List[UInt8], want: List[UInt8], what: String) raises:
    if len(got) != len(want):
        raise Error(
            "FAIL: " + what + " длина " + String(len(got)) + " вместо " + String(len(want))
        )
    for i in range(len(got)):
        if got[i] != want[i]:
            raise Error("FAIL: " + what + " байт " + String(i))
    print("ok: " + what)


def bytes_of(vals: List[Int]) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(vals)):
        out.append(UInt8(vals[i] & 0xFF))
    return out^


def test_system_packet() raises:
    var args = bytes_of([4, 0, 0, 0, 65, 0, 66, 67])
    var p = build_system_packet(1, SYS_BEGIN_DOWNLOAD, args)
    var want = bytes_of([1, 0, 1, 0x92, 4, 0, 0, 0, 65, 0, 66, 67])
    expect_bytes(p, want, "system-пакет: счётчик/тип/команда/аргументы")


def test_chunk_plan() raises:
    # Синтетический файл 30 байт, dest_cstr = 27 байт
    # ("../prjs/BrkProg_SAVE/T.rbf" — 26 символов + NUL).
    var dest = String("../prjs/BrkProg_SAVE/T.rbf")
    var dc = dest_cstr(dest)
    check(len(dc) == 27, "dest_cstr с NUL = 27 байт")
    check(begin_first_len(30, len(dc), 900) == 30, "chunk=900: всё в первом кадре")
    check(len(continue_ranges(30, 30, 900)) == 0, "chunk=900: без CONTINUE")
    check(begin_first_len(30, len(dc), 20) == 0, "chunk=20: первый кадр пустой")
    var r = continue_ranges(30, 0, 20)
    check(len(r) == 2, "chunk=20: два CONTINUE")
    check(r[0][0] == 0 and r[0][1] == 20, "chunk=20: первый (0,20)")
    check(r[1][0] == 20 and r[1][1] == 10, "chunk=20: второй (20,10)")
    var r2 = continue_ranges(30, 2, 28)
    check(len(r2) == 1, "chunk=28/first=2: один CONTINUE")
    check(r2[0][0] == 2 and r2[0][1] == 28, "chunk=28: (2,28) до конца")


def test_begin_args() raises:
    var data = List[UInt8]()
    for i in range(30):
        data.append(UInt8(i))
    var dest = dest_cstr(String("../prjs/BrkProg_SAVE/T.rbf"))
    var args = build_begin_args(30, dest, data, 2)
    check(len(args) == 4 + 27 + 2, "BEGIN: размер+путь+первые 2 байта")
    check(args[0] == 30 and args[1] == 0 and args[2] == 0 and args[3] == 0, "BEGIN: total u32 LE")
    check(args[4] == UInt8(46) and args[5] == UInt8(46), "BEGIN: путь с ../")
    check(args[4 + 27] == 0 and args[4 + 27 + 1] == 1, "BEGIN: первые байты файла")
    var c = build_continue_args(7, data, 2, 3)
    var want = bytes_of([7, 2, 3, 4])
    expect_bytes(c, want, "CONTINUE: handle + срез")


def test_hid_roundtrip() raises:
    var p = build_system_packet(0x1234, SYS_CREATE_DIR, dest_cstr(String("../prjs/BrkProg_SAVE/")))
    var rep = build_hid_report(p)
    check(len(rep) == 1024, "HID-отчёт ровно 1024")
    check(rep[0] == 0, "HID-отчёт: байт 0 = 0")
    check(Int(rep[1]) | (Int(rep[2]) << 8) == len(p), "HID-отчёт: длина пакета")
    var back = parse_hid_report(rep)
    expect_bytes(back, p, "HID round-trip")


def test_replies() raises:
    # Реальный ответ кирпича: [ctr u16][0x03][эхо команды][статус][данные...]
    # (EV3Connection.cs:66-117: Array.Copy(packet, 4, ...)).
    var begin_ok = bytes_of([0x34, 0x12, 0x03, SYS_BEGIN_DOWNLOAD, 0x00, 0x07])
    var reply = check_system_reply(begin_ok, 0x1234, SYS_BEGIN_DOWNLOAD)
    expect_bytes(reply, bytes_of([0x00, 0x07]), "BEGIN-ответ: статус+handle")
    check(
        check_download_status(reply, "BEGIN_DOWNLOAD") == 7,
        "handle 7 из реалистичного BEGIN-ответа",
    )
    # 0x05 (SYSTEM_REPLY_NO_ERROR) — тоже валидный тип.
    var begin_alt = bytes_of([0x34, 0x12, 0x05, SYS_BEGIN_DOWNLOAD, 0x00, 0x09])
    var reply_alt = check_system_reply(begin_alt, 0x1234, SYS_BEGIN_DOWNLOAD)
    expect_bytes(reply_alt, bytes_of([0x00, 0x09]), "BEGIN-ответ типа 0x05")
    # CONTINUE: эхо 0x93, статус 0x00, handle.
    var cont_ok = bytes_of([0x34, 0x12, 0x03, SYS_CONTINUE_DOWNLOAD, 0x00, 0x07])
    var creply = check_system_reply(cont_ok, 0x1234, SYS_CONTINUE_DOWNLOAD)
    expect_bytes(creply, bytes_of([0x00, 0x07]), "CONTINUE-ответ: статус+handle")
    # END_OF_FILE (0x08) — валидный статус завершения.
    var cont_eof = bytes_of([0x34, 0x12, 0x03, SYS_CONTINUE_DOWNLOAD, 0x08, 0x07])
    var ereply = check_system_reply(cont_eof, 0x1234, SYS_CONTINUE_DOWNLOAD)
    check(
        check_download_status(ereply, "CONTINUE_DOWNLOAD") == 7,
        "END_OF_FILE принимается как успех CONTINUE",
    )
    # CREATE_DIR: эхо 0x9B, только статус (нет payload).
    var mk = bytes_of([0x02, 0x00, 0x03, SYS_CREATE_DIR, 0x00])
    var mreply = check_system_reply(mk, 2, SYS_CREATE_DIR)
    expect_bytes(mreply, bytes_of([0x00]), "CREATE_DIR-ответ: только статус")

    def rejects(packet: List[UInt8], ctr: Int, cmd: Int, what: String) raises:
        var failed = False
        try:
            _ = check_system_reply(packet, ctr, cmd)
        except:
            failed = True
        check(failed, what)

    rejects(
        bytes_of([0x35, 0x12, 0x03, SYS_BEGIN_DOWNLOAD, 0x00, 0x07]),
        0x1234, SYS_BEGIN_DOWNLOAD, "чужой счётчик отклоняется",
    )
    rejects(
        bytes_of([0x34, 0x12, 0x02, SYS_BEGIN_DOWNLOAD, 0x00, 0x07]),
        0x1234, SYS_BEGIN_DOWNLOAD, "неверный тип ответа отклоняется",
    )
    # Эхо чужой команды — ошибка протокола, а не тихий приём.
    rejects(
        bytes_of([0x34, 0x12, 0x03, SYS_CREATE_DIR, 0x00, 0x07]),
        0x1234, SYS_BEGIN_DOWNLOAD, "чужое эхо команды отклоняется",
    )
    # Обрезанный ответ: < 5 байт (нет статуса после эха).
    rejects(
        bytes_of([0x34, 0x12, 0x03, SYS_BEGIN_DOWNLOAD]),
        0x1234, SYS_BEGIN_DOWNLOAD, "оборванный ответ (4 байта) отклоняется",
    )
    rejects(
        bytes_of([0x34, 0x12]), 0x1234, SYS_BEGIN_DOWNLOAD,
        "ответ без типа отклоняется",
    )
    # Неверный статус в BEGIN (не 0x00/0x08) ловится check_download_status,
    # а не молча принимается.
    var bad_status = check_system_reply(
        bytes_of([0x34, 0x12, 0x03, SYS_BEGIN_DOWNLOAD, 0x05, 0x07]),
        0x1234, SYS_BEGIN_DOWNLOAD,
    )
    var status_failed = False
    try:
        _ = check_download_status(bad_status, "BEGIN_DOWNLOAD")
    except:
        status_failed = True
    check(status_failed, "неверный статус BEGIN (0x05) отклоняется")

    var derr = bytes_of([0x01, 0x00, 0x04])
    var failed = False
    try:
        _ = check_direct_reply(derr, 1, 0)
    except:
        failed = True
    check(failed, "ошибка VM (0x04) отклоняется")
    var dok = bytes_of([0x01, 0x00, 0x02, 9, 8, 7])
    var g = check_direct_reply(dok, 1, 3)
    expect_bytes(g, bytes_of([9, 8, 7]), "direct-ответ: global-данные")


def test_run_bytecode() raises:
    var bc = build_run_bytecode(String("X"))
    # C0 08 01 84 'X' 00 60 64 03 01 60 64 00 (RunEV3File 1:1)
    var want = bytes_of([0xC0, 8, 1, 0x84, 0x58, 0, 0x60, 0x64, 3, 1, 0x60, 0x64, 0])
    expect_bytes(bc, want, "байткод запуска PROGRAM_START")
    var dp = build_direct_packet(5, bc, 10, 0)
    check(dp[0] == 5 and dp[1] == 0 and dp[2] == 0, "direct-пакет: счётчик и тип")
    check(dp[3] == 10 and dp[4] == 0, "direct-пакет: globals=10 locals=0")
    var e1 = encode_const(1)
    expect_bytes(e1, bytes_of([1]), "const короткая форма")
    var e2 = encode_globvar(4)
    expect_bytes(e2, bytes_of([0x64]), "globvar короткая форма")
    var e3 = encode_dc_string(String("AB"))
    expect_bytes(e3, bytes_of([0x84, 65, 66, 0]), "dc-строка 0x84..00")


def test_paths_and_scan() raises:
    check(
        brick_dest_for("a/b/Program1.rbf") == "../prjs/BrkProg_SAVE/Program1.rbf",
        "путь на кирпиче по умолчанию",
    )
    check(
        is_ev3_uevent("DRIVER=x\nHID_ID=0003:00000694:00000005\n"),
        "uevent EV3 опознаётся",
    )
    check(
        not is_ev3_uevent("HID_ID=0018:000004F3:000032A9\n"),
        "чужой HID отбрасывается",
    )
    check(
        not is_ev3_uevent("DRIVER=x\n"),
        "uevent без HID_ID отбрасывается",
    )
    # ВАЖНО: обязательный offline-тест не должен зависеть от наличия живого
    # EV3 на машине. list_ev3_devices() сканирует /sys и здесь НЕ вызывается:
    # проверяется только чистое распознавание uevent-строк выше.


def test_read_rbf() raises:
    var path = String("tests/corpus/Functions/~Test1/Test1.rbf")
    var data = c_read_file(path)
    check(len(data) > 16, ".rbf читается целиком")
    check(
        data[0] == 76 and data[1] == 69 and data[2] == 71 and data[3] == 79,
        ".rbf начинается с магии LEGO",
    )
    print("info: Test1.rbf = " + String(len(data)) + " байт, hex головы: " + hex_of(data)[byte=0:64])


def test_dry_run() raises:
    var rc = cmd_flash("tests/corpus/Functions/~Test1/Test1.rbf", "dry")
    check(rc == 0, "dry-run cmd_flash возвращает 0")


def test_stream_transports() raises:
    # classify_target: USB
    var c = classify_target("")
    check(c[0] == TRANSPORT_USB and c[1] == "", "classify: '' -> usb-автовыбор")
    c = classify_target("usb")
    check(c[0] == TRANSPORT_USB, "classify: usb")
    c = classify_target("usb:hidraw3")
    check(c[0] == TRANSPORT_USB and c[1] == "hidraw3", "classify: usb:hidraw3")
    c = classify_target("/dev/hidraw1")
    check(c[0] == TRANSPORT_USB and c[1] == "/dev/hidraw1", "classify: /dev/hidraw1")
    # classify_target: Bluetooth
    c = classify_target("bt:00:16:53:AA:BB:CC")
    check(
        c[0] == TRANSPORT_STREAM and c[1] == "00:16:53:AA:BB:CC",
        "classify: bt:MAC",
    )
    c = classify_target("00:16:53:aa:bb:cc")
    check(c[0] == TRANSPORT_STREAM, "classify: голый MAC")
    # classify_target: Wi-Fi
    c = classify_target("wifi:192.168.1.42")
    check(c[0] == TRANSPORT_STREAM and c[1] == "192.168.1.42", "classify: wifi:IP")
    c = classify_target("10.0.0.7")
    check(c[0] == TRANSPORT_STREAM, "classify: голый IP")
    # classify_target: /dev/rfcomm0 — потоковый serial
    c = classify_target("/dev/rfcomm0")
    check(c[0] == TRANSPORT_STREAM and c[1] == "/dev/rfcomm0", "classify: rfcomm")
    # classify_target: мусор
    var failed = False
    try:
        _ = classify_target("garbage")
    except:
        failed = True
    check(failed, "classify: мусор отклоняется")

    # parse_ipv4
    var ip = parse_ipv4(String("192.168.1.42"))
    expect_bytes(ip, bytes_of([192, 168, 1, 42]), "parse_ipv4: байты")
    for bad in ["1.2.3", "1.2.3.256", "a.b.c.d", "1..2.3"]:
        failed = False
        try:
            _ = parse_ipv4(bad)
        except:
            failed = True
        if not failed:
            raise Error("FAIL: parse_ipv4 принял '" + bad + "'")
    print("ok: parse_ipv4 отбрасывает кривые адреса")

    # parse_mac
    var mac = parse_mac(String("00:16:53:AA:0B:FF"))
    expect_bytes(mac, bytes_of([0, 0x16, 0x53, 0xAA, 0x0B, 0xFF]), "parse_mac: байты")
    for bad in ["00:16:53", "00:16:53:AA:BB:ZZ", "0:16:53:AA:BB:CC"]:
        failed = False
        try:
            _ = parse_mac(bad)
        except:
            failed = True
        if not failed:
            raise Error("FAIL: parse_mac принял '" + bad + "'")
    print("ok: parse_mac отбрасывает кривые адреса")

    # sockaddr_in: family 2, порт 5555 BE (0x15B3), адрес BE, 16 байтов
    var sa = build_sockaddr_in(String("192.168.1.42"), 5555)
    expect_bytes(
        sa,
        bytes_of([2, 0, 0x15, 0xB3, 192, 168, 1, 42, 0, 0, 0, 0, 0, 0, 0, 0]),
        "sockaddr_in",
    )
    # sockaddr_rc: family 31, bdaddr наоборот, канал 1, 10 байтов
    var src = build_sockaddr_rc(String("00:16:53:AA:BB:CC"), 1)
    expect_bytes(
        src,
        bytes_of([31, 0, 0xCC, 0xBB, 0xAA, 0x53, 0x16, 0x00, 1, 0]),
        "sockaddr_rc",
    )

    # потоковый кадр [len u16 LE][пакет]
    var pkt = build_system_packet(0x0201, SYS_CREATE_DIR, dest_cstr(String("d")))
    var fr = build_stream_frame(pkt)
    check(len(fr) == len(pkt) + 2, "кадр: +2 байта длины")
    check(fr[0] == UInt8(len(pkt)) and fr[1] == 0, "кадр: длина u16 LE")
    var back = List[UInt8]()
    for i in range(2, len(fr)):
        back.append(fr[i])
    expect_bytes(back, pkt, "кадр round-trip")

    # handshake-строки 1:1 с EV3ConnectionWiFi.cs
    expect_bytes(
        str_bytes(WIFI_HANDSHAKE_REQ),
        bytes_of([71, 69, 84, 32, 47, 116, 97, 114, 103, 101, 116, 63, 115, 110,
                  61, 13, 10, 80, 114, 111, 116, 111, 99, 111, 108, 58, 69, 86,
                  51, 13, 10, 13, 10]),
        "handshake-запрос",
    )
    expect_bytes(
        str_bytes(WIFI_HANDSHAKE_RSP),
        bytes_of([65, 99, 99, 101, 112, 116, 58, 69, 86, 51, 52, 48, 13, 10, 13, 10]),
        "handshake-ответ",
    )


def _socketpair_stream() raises -> Tuple[Int, Int]:
    """Пара соединённых stream-сокетов (AF_UNIX): детерминированный peer для
    sys_cmd/direct_cmd без железа и без потоков."""
    # socketpair пишет два C int (по 4 байта), поэтому буфер — байтовый.
    var sv = List[UInt8](length=8, fill=UInt8(0))
    var rc = Int(external_call["socketpair", Int](1, 1, 0, sv.unsafe_ptr()))
    if rc != 0:
        raise Error("FAIL: socketpair")
    var a = Int(sv[0]) | (Int(sv[1]) << 8) | (Int(sv[2]) << 16) | (Int(sv[3]) << 24)
    var b = Int(sv[4]) | (Int(sv[5]) << 8) | (Int(sv[6]) << 16) | (Int(sv[7]) << 24)
    return (a, b)


def _read_stream_frame(fd: Int) raises -> List[UInt8]:
    var hdr = c_read_full(fd, 2)
    var size = Int(hdr[0]) | (Int(hdr[1]) << 8)
    return c_read_full(fd, size)


def test_counter_wrap() raises:
    """Счётчик на проводе — u16: после 0xFFFF идёт 0, а ответ с ctr=0 обязан
    приниматься при полном Int-счётчике 65536/65535."""
    check(wire_counter(0) == 0, "wire_counter: 0")
    check(wire_counter(65535) == 65535, "wire_counter: 65535 без изменений")
    check(wire_counter(65536) == 0, "wire_counter: 65536 -> 0 (u16)")
    check(wire_counter(65537) == 1, "wire_counter: 65537 -> 1")
    check(advance_counter(0) == 1, "advance_counter: 0 -> 1")
    check(advance_counter(65534) == 65535, "advance_counter: 65534 -> 65535")
    check(advance_counter(65535) == 0, "advance_counter: 65535 -> 0 (wrap)")
    check(advance_counter(65536) == 1, "advance_counter: 65536 -> 1")

    # Wire-кадры строятся из u16-формы.
    var p = build_system_packet(65536, SYS_CREATE_DIR, bytes_of([65, 0]))
    check(p[0] == 0 and p[1] == 0, "packet: ctr 65536 -> байты 0,0")
    p = build_system_packet(65535, SYS_CREATE_DIR, bytes_of([65, 0]))
    check(p[0] == 0xFF and p[1] == 0xFF, "packet: ctr 65535 -> байты ff,ff")
    var d = build_direct_packet(65536, bytes_of([0xC0]), 10, 0)
    check(d[0] == 0 and d[1] == 0, "direct-packet: ctr 65536 -> байты 0,0")

    # Проверка ответа нормализует свой счётчик к u16; чужой ACK по-прежнему
    # отклоняется (никакого «принять всё после wrap»).
    var r0 = bytes_of([0x00, 0x00, 0x03, SYS_CREATE_DIR, 0x00])
    var repl = check_system_reply(r0, 65536, SYS_CREATE_DIR)
    expect_bytes(repl, bytes_of([0x00]), "system-reply: ctr=0 при counter=65536")
    var failed = False
    try:
        _ = check_system_reply(r0, 65535, SYS_CREATE_DIR)
    except:
        failed = True
    check(failed, "system-reply: ctr=0 всё ещё чужой для counter=65535")
    var rff = bytes_of([0xFF, 0xFF, 0x03, SYS_CREATE_DIR, 0x00])
    _ = check_system_reply(rff, 65535, SYS_CREATE_DIR)
    print("ok: system-reply: ctr=65535 при counter=65535")
    var d0 = bytes_of([0x00, 0x00, 0x02]) + bytes_of([1, 2, 3])
    var g = check_direct_reply(d0, 65536, 3)
    expect_bytes(g, bytes_of([1, 2, 3]), "direct-reply: ctr=0 при counter=65536")
    failed = False
    try:
        _ = check_direct_reply(d0, 65535, 3)
    except:
        failed = True
    check(failed, "direct-reply: ctr=0 всё ещё чужой для counter=65535")

    # ACTUAL sys_cmd/direct_cmd: старт с 65535 -> на проводе 0, ответ с
    # ctr=0 принимается (раньше валидный ACK отвергался после 65535 команд).
    var fds = _socketpair_stream()
    var fd = fds[0]
    var peer = fds[1]
    try:
        c_write_all(peer, build_stream_frame(r0))
        var res = sys_cmd(fd, 65535, SYS_CREATE_DIR, bytes_of([65, 0]), 1, TRANSPORT_STREAM)
        check(res[0] == 0, "sys_cmd: 65535 -> возвращён ctr 0 (u16 wrap)")
        expect_bytes(res[1], bytes_of([0x00]), "sys_cmd: ответ после wrap разобран")
        var sent = _read_stream_frame(peer)
        check(
            Int(sent[0]) | (Int(sent[1]) << 8) == 0,
            "sys_cmd: на проводе после 65535 счётчик 0",
        )
        check(sent[2] == UInt8(0x01) and sent[3] == UInt8(SYS_CREATE_DIR),
              "sys_cmd: отправлена именно CREATE_DIR")
    finally:
        c_close(fd)
        c_close(peer)

    var fds2 = _socketpair_stream()
    var fd2 = fds2[0]
    var peer2 = fds2[1]
    try:
        c_write_all(peer2, build_stream_frame(d0))
        var res2 = direct_cmd(fd2, 65535, bytes_of([0xC0, 0x08]), 3, 1, TRANSPORT_STREAM)
        check(res2[0] == 0, "direct_cmd: 65535 -> возвращён ctr 0 (u16 wrap)")
        expect_bytes(res2[1], bytes_of([1, 2, 3]), "direct_cmd: global-данные после wrap")
        var sent2 = _read_stream_frame(peer2)
        check(
            Int(sent2[0]) | (Int(sent2[1]) << 8) == 0,
            "direct_cmd: на проводе после 65535 счётчик 0",
        )
        check(sent2[2] == UInt8(0x00), "direct_cmd: тип direct на проводе")
    finally:
        c_close(fd2)
        c_close(peer2)


def test_create_dir_status() raises:
    """CREATE_DIR: успех только SUCCESS (0x00) или FILE_EXISTS (0x07,
    EV3Connection.cs:49). Прочие статусы и пустой ответ — ошибка."""
    check(check_create_dir_status(bytes_of([0x00])) == 0, "CREATE_DIR: SUCCESS принят")
    check(
        check_create_dir_status(bytes_of([0x07])) == 0x07,
        "CREATE_DIR: FILE_EXISTS 0x07 принят (каталог уже есть)",
    )
    for st in [0x05, 0x06, 0x08, 0xFF]:
        var failed = False
        try:
            _ = check_create_dir_status(bytes_of([st]))
        except:
            failed = True
        check(failed, "CREATE_DIR: статус " + String(st) + " отклоняется")
    var empty = List[UInt8]()
    var failed_empty = False
    try:
        _ = check_create_dir_status(empty)
    except:
        failed_empty = True
    check(failed_empty, "CREATE_DIR: пустой ответ отклоняется")
    # Эхо/тип/ctr проверяются раньше: битый кадр не доходит до политики.
    var failed_echo = False
    try:
        _ = check_system_reply(
            bytes_of([0x01, 0x00, 0x03, SYS_BEGIN_DOWNLOAD, 0x00]),
            1, SYS_CREATE_DIR,
        )
    except:
        failed_echo = True
    check(failed_echo, "CREATE_DIR: чужое эхо отклоняется до статуса")


def main() raises:
    test_system_packet()
    test_chunk_plan()
    test_begin_args()
    test_hid_roundtrip()
    test_replies()
    test_run_bytecode()
    test_paths_and_scan()
    test_read_rbf()
    test_dry_run()
    test_stream_transports()
    test_open_transport_fd_cleanup()
    test_retry_safety()
    test_counter_wrap()
    test_create_dir_status()
    print("FLASH_TEST OK")


def _open_fd_count() raises -> Int:
    """Число открытых fd текущего процесса (чтение /proc/self/fd)."""
    return len(listdir("/proc/self/fd"))


def test_open_transport_fd_cleanup() raises:
    """Сбой setup транспорта не должен утекать fd.

    Детерминированный hardware-free случай: потоковый target с '/' (путь
    rfcomm), но файл — обычный, не tty: open_transport успевает сделать
    c_open, затем serial_make_raw падает на ioctl TCGETS. Раньше fd в этот
    момент терялся; теперь закрывается на любом setup-failure.
    """
    var pid = Int(external_call["getpid", Int]())
    var dir = "/tmp/bp_flash_fdtest_" + String(pid)
    try:
        mkdir(dir)
    except:
        pass
    var path = dir + "/rfcomm_not_a_tty"
    write_text(path, "x")
    var before = _open_fd_count()
    var failed = False
    try:
        _ = open_transport(TRANSPORT_STREAM, path)
    except:
        failed = True
    check(failed, "open_transport: не-tty serial падает (setup failure)")
    var after = _open_fd_count()
    check(after <= before, "open_transport: fd не утёк при сбое setup")
    # Успешный путь не должен закрывать fd дважды: открываем обычный файл
    # напрямую как USB-target (реальный fd возвращается без setup-стадий).
    var usbfd = open_transport(TRANSPORT_USB, path)
    check(usbfd > 2, "open_transport: успешный USB-path вернул живой fd")
    var after_open = _open_fd_count()
    check(after_open == before + 1, "open_transport: успех = ровно один новый fd")
    # Закрыть через syscall-close (тот же слой, что использует flash).
    c_close(usbfd)
    check(_open_fd_count() == before, "open_transport: fd закрывается один раз")
    # Убрать только свой уникальный temp-каталог (pid в имени).
    try:
        remove(path)
    except:
        pass
    try:
        rmdir(dir)
    except:
        pass


def test_retry_safety() raises:
    """Ретраи не должны дублировать неидемпотентную заливку.

    BEGIN/CONTINUE_DOWNLOAD после потери ACK повторять нельзя (кирпич мог
    принять кадр; новый ctr -> дубли байтов). CREATE_DIR идемпотентна.
    """
    check(
        not is_retry_safe(SYS_BEGIN_DOWNLOAD),
        "BEGIN_DOWNLOAD не ретраится автоматически",
    )
    check(
        not is_retry_safe(SYS_CONTINUE_DOWNLOAD),
        "CONTINUE_DOWNLOAD не ретраится автоматически",
    )
    check(is_retry_safe(SYS_CREATE_DIR), "CREATE_DIR идемпотентна (ретрай ок)")
