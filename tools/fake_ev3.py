#!/usr/bin/env python3
"""Заглушка LEGO EV3 для сквозного теста `bp flash` по Wi-Fi-протоколу.

Слушает TCP на loopback, делает handshake EV3ConnectionWiFi, разбирает кадры
[len u16 LE][пакет], отвечает как кирпич и собирает заливаемый файл.

Ответы повторяют реальный формат (EV3Connection.cs:66-117):
  [счётчик u16][0x03][эхо команды u8][статус u8][данные...]
то есть эхо-команда присутствует обязательно (раньше мок её опускал и был
не совместим с реальным кирпичом). Полезная нагрузка начинается с байта 4.

Запуск:
  python3 tools/fake_ev3.py --port 5555 --upload /tmp/x.rbf [--report /tmp/r.jsonl]
                           [--fail-mode MODE]

  MODE:
    none              — нормальная работа (по умолчанию)
    handshake-close   — закрыть соединение сразу после accept (сбой setup)
    bad-handshake     — ответить неверным handshake
    drop-begin-reply  — принять BEGIN, но НЕ отвечать (потеря ACK);
                        клиент обязан не повторять заливку и упасть
    bad-echo          — на BEGIN ответить с эхом чужой команды
    truncated-begin   — на BEGIN ответить обрезанным пакетом (4 байта)
    bad-ctr           — на BEGIN ответить с чужим счётчиком, затем молчать

Все пути задаются аргументами: никаких фиксированных /tmp-имён, чужие
listener'ы и файлы не трогаются. Порт по умолчанию 5555 — как у клиента
(CLI не имеет опции порта намеренно).
"""
import argparse
import json
import socket
import struct
import sys
import time

HANDSHAKE_REQ = b"GET /target?sn=\r\nProtocol:EV3\r\n\r\n"
HANDSHAKE_RSP = b"Accept:EV340\r\n\r\n"

MSG_SYSTEM = 0x01
MSG_DIRECT = 0x00
RPL_SYS = 0x03
RPL_SYS_ALT = 0x05
RPL_DIRECT = 0x02
SYS_CREATE_DIR = 0x9B
SYS_BEGIN = 0x92
SYS_CONTINUE = 0x93
STATUS_OK = 0x00
STATUS_FILE_EXISTS = 0x07  # EV3Connection.cs:49, каталог уже существует


def recv_exact(conn, n):
    buf = b""
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            raise SystemExit("fake_ev3: клиент оборвал соединение")
        buf += chunk
    return buf


def recv_packet(conn):
    (size,) = struct.unpack("<H", recv_exact(conn, 2))
    if not 3 <= size <= 4096:
        raise SystemExit(f"fake_ev3: плохая длина кадра {size}")
    return recv_exact(conn, size)


def send_packet(conn, payload):
    conn.sendall(struct.pack("<H", len(payload)) + payload)


def sys_reply(ctr, cmd, status=STATUS_OK, payload=b"", msg_type=RPL_SYS):
    """Реальный ответ: ctr + type + ЭХО КОМАНДЫ + статус + данные."""
    return struct.pack("<HBBB", ctr, msg_type, cmd, status) + payload


class Report:
    def __init__(self, path):
        self.path = path
        self.fh = open(path, "a", encoding="utf-8") if path else None

    def add(self, **kw):
        kw.setdefault("t", round(time.time(), 3))
        if self.fh:
            self.fh.write(json.dumps(kw, sort_keys=True) + "\n")
            self.fh.flush()

    def close(self):
        if self.fh:
            self.fh.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=5555)
    ap.add_argument("--upload", required=True, help="куда сохранить принятый файл")
    ap.add_argument("--report", default=None, help="JSONL-журнал событий")
    ap.add_argument(
        "--fail-mode",
        default="none",
        choices=[
            "none",
            "handshake-close",
            "bad-handshake",
            "drop-begin-reply",
            "bad-echo",
            "truncated-begin",
            "bad-ctr",
            "drop-continue-reply",
            "create-bad-echo",
            "create-truncated",
            "create-drop-reply",
            "create-exists",
        ],
    )
    args = ap.parse_args()

    rep = Report(args.report)
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        srv.bind(("127.0.0.1", args.port))
    except OSError as e:
        rep.add(event="bind-failed", port=args.port, error=str(e))
        rep.close()
        srv.close()
        print(f"fake_ev3: порт {args.port} занят: {e}", flush=True)
        return 2
    srv.listen(1)
    rep.add(event="listening", port=args.port, mode=args.fail_mode)
    print(f"fake_ev3: слушаю 127.0.0.1:{args.port} mode={args.fail_mode}", flush=True)
    conn, _ = srv.accept()
    rep.add(event="accepted")

    try:
        if args.fail_mode == "handshake-close":
            conn.close()
            rep.add(event="closed-after-accept")
            print("fake_ev3: соединение закрыто до handshake", flush=True)
            return 0

        # Handshake как в EV3ConnectionWiFi.cs: читаем запрос, отвечаем.
        buf = b""
        while not buf.endswith(HANDSHAKE_REQ):
            chunk = conn.recv(1)
            if not chunk:
                raise SystemExit("fake_ev3: handshake оборван")
            buf += chunk
        if args.fail_mode == "bad-handshake":
            conn.sendall(b"Accept:EV999\r\n\r\n")
            rep.add(event="bad-handshake-sent")
            print("fake_ev3: отправлен неверный handshake", flush=True)
            return 0
        conn.sendall(HANDSHAKE_RSP)
        rep.add(event="handshake-ok")
        print("fake_ev3: handshake OK", flush=True)

        upload = None  # [путь, ожидаемый размер, bytearray]
        handle = 0
        while True:
            pkt = recv_packet(conn)
            ctr = struct.unpack("<H", pkt[0:2])[0]
            msg_type = pkt[2]
            rep.add(event="packet", type=msg_type, ctr=ctr, size=len(pkt))
            if msg_type == MSG_SYSTEM:
                cmd = pkt[3]
                cargs = pkt[4:]
                rep.add(event="syscmd", cmd=cmd, ctr=ctr)
                if cmd == SYS_CREATE_DIR:
                    print(f"fake_ev3: CREATE_DIR ctr={ctr}", flush=True)
                    if args.fail_mode == "create-bad-echo":
                        send_packet(conn, sys_reply(ctr, SYS_BEGIN))
                        rep.add(event="create-bad-echo-sent", ctr=ctr)
                        continue
                    if args.fail_mode == "create-truncated":
                        # 4 байта: ctr + type + эхо, без статуса.
                        send_packet(conn, struct.pack("<HBB", ctr, RPL_SYS, cmd))
                        rep.add(event="create-truncated-sent", ctr=ctr)
                        continue
                    if args.fail_mode == "create-drop-reply":
                        rep.add(event="create-dropped-reply", ctr=ctr)
                        print("fake_ev3: CREATE_DIR принят, ответ потерян", flush=True)
                        continue
                    if args.fail_mode == "create-exists":
                        rep.add(event="create-exists-sent", ctr=ctr)
                        send_packet(conn, sys_reply(ctr, cmd, status=STATUS_FILE_EXISTS))
                        continue
                    send_packet(conn, sys_reply(ctr, cmd))
                elif cmd == SYS_BEGIN:
                    size = struct.unpack("<I", cargs[0:4])[0]
                    path = cargs[4:].split(b"\x00")[0].decode()
                    first = cargs[4 + len(path) + 1:]
                    handle = 1
                    upload = [path, size, bytearray(first)]
                    rep.add(event="begin", ctr=ctr, size=size, path=path, first=len(first))
                    print(
                        f"fake_ev3: BEGIN_DOWNLOAD ctr={ctr} size={size} "
                        f"path={path} first={len(first)}",
                        flush=True,
                    )
                    if args.fail_mode == "drop-begin-reply":
                        # Приняли, но ACK потерян: дальше ничего не отвечаем.
                        rep.add(event="dropped-begin-reply", ctr=ctr)
                        print("fake_ev3: BEGIN принят, ответ намеренно потерян", flush=True)
                        continue
                    if args.fail_mode == "truncated-begin":
                        # 4 байта: ctr + type + эхо, без статуса (обрыв).
                        send_packet(conn, struct.pack("<HBB", ctr, RPL_SYS, cmd))
                        rep.add(event="truncated-begin-sent", ctr=ctr)
                        continue
                    if args.fail_mode == "bad-echo":
                        send_packet(conn, sys_reply(ctr, SYS_CREATE_DIR, payload=bytes([handle])))
                        rep.add(event="bad-echo-sent", ctr=ctr)
                        continue
                    if args.fail_mode == "bad-ctr":
                        send_packet(
                            conn,
                            sys_reply((ctr + 1) & 0xFFFF, cmd, payload=bytes([handle])),
                        )
                        rep.add(event="bad-ctr-sent", ctr=ctr)
                        continue
                    send_packet(conn, sys_reply(ctr, cmd, payload=bytes([handle])))
                elif cmd == SYS_CONTINUE:
                    cont = cargs[1:]
                    upload[2] += cont
                    rep.add(event="continue", ctr=ctr, got=len(cont), total=len(upload[2]))
                    print(
                        f"fake_ev3: CONTINUE_DOWNLOAD ctr={ctr} +{len(cont)} "
                        f"= {len(upload[2])}/{upload[1]}",
                        flush=True,
                    )
                    if args.fail_mode == "drop-continue-reply":
                        rep.add(event="dropped-continue-reply", ctr=ctr)
                        print(
                            "fake_ev3: CONTINUE принят, ответ потерян", flush=True
                        )
                        continue
                    send_packet(conn, sys_reply(ctr, cmd, payload=bytes([handle])))
                else:
                    rep.add(event="unknown-syscmd", cmd=cmd, ctr=ctr)
                    send_packet(conn, sys_reply(ctr, cmd, status=0xFF))
            elif msg_type == MSG_DIRECT:
                bc = pkt[5:]
                rep.add(event="direct", ctr=ctr, bc_head=bc[:2].hex())
                if bc[0:2] != b"\xc0\x08":
                    rep.add(event="bad-direct")
                    print("fake_ev3: в direct нет opFILE LOAD_IMAGE", flush=True)
                    return 3
                print(f"fake_ev3: PROGRAM_START ctr={ctr} (запуск)", flush=True)
                send_packet(
                    conn, struct.pack("<H", ctr) + bytes([RPL_DIRECT]) + bytes(10)
                )
                break
            else:
                rep.add(event="unknown-type", type=msg_type)
                print(f"fake_ev3: неизвестный тип пакета {msg_type:#x}", flush=True)
                return 3

        if upload is None:
            rep.add(event="no-upload")
            print("fake_ev3: файл не передавался", flush=True)
            return 3
        path, size, data = upload
        if len(data) != size:
            rep.add(event="incomplete", got=len(data), want=size)
            print(f"fake_ev3: файл неполный: {len(data)} из {size}", flush=True)
            return 3
        with open(args.upload, "wb") as f:
            f.write(data)
        rep.add(event="upload", path=args.upload, size=size, brick_path=path)
        print(
            f"fake_ev3: файл принят целиком ({size} байт) -> {args.upload}", flush=True
        )
        print("fake_ev3: DONE", flush=True)
        return 0
    finally:
        try:
            conn.close()
        except OSError:
            pass
        srv.close()
        rep.close()


if __name__ == "__main__":
    sys.exit(main())
