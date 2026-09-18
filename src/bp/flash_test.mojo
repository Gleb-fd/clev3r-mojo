"""Тест framing/парсинга заливки (без железа).

Запуск из корня репо:
  uv run mojo run src/bp/flash_test.mojo
  BP_FLASH_DRY=1 uv run mojo run src/bp/flash_test.mojo
Печатает FLASH_TEST OK при успехе.
"""

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
    c_read_file,
    check_direct_reply,
    check_download_status,
    check_system_reply,
    classify_target,
    cmd_flash,
    continue_ranges,
    dest_cstr,
    encode_const,
    encode_dc_string,
    encode_globvar,
    hex_of,
    is_ev3_uevent,
    list_ev3_devices,
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
    var good = bytes_of([0x34, 0x12, 0x03, 0x00, 0x07, 0xAA])
    var reply = check_system_reply(good, 0x1234)
    expect_bytes(reply, bytes_of([0x00, 0x07, 0xAA]), "system-ответ: статус+данные")
    check(check_download_status(reply, "BEGIN_DOWNLOAD") == 7, "handle из ответа")
    var bad_ctr = bytes_of([0x35, 0x12, 0x03, 0x00, 0x07])
    var failed = False
    try:
        _ = check_system_reply(bad_ctr, 0x1234)
    except:
        failed = True
    check(failed, "чужой счётчик отклоняется")
    var bad_type = bytes_of([0x34, 0x12, 0x02, 0x00, 0x07])
    failed = False
    try:
        _ = check_system_reply(bad_type, 0x1234)
    except:
        failed = True
    check(failed, "неверный тип ответа отклоняется")
    var derr = bytes_of([0x01, 0x00, 0x04])
    failed = False
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
    var devs = list_ev3_devices()
    check(len(devs) == 0, "на этой машине EV3 нет (найдено 0)")


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
    print("FLASH_TEST OK")
