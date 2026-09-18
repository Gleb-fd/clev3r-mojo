#!/usr/bin/env python3
"""Заглушка LEGO EV3 для сквозного теста `bp flash` по Wi-Fi/BT-протоколу.

Слушает TCP, делает handshake EV3ConnectionWiFi, разбирает кадры
[len u16 LE][пакет], отвечает как кирпич и собирает заливаемый файл.
Собранный файл кладёт в /tmp/fake_ev3_upload, затем выходит.

Запуск: python3 tools/fake_ev3.py [port]
"""
import socket
import struct
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 5555
HANDSHAKE_REQ = b"GET /target?sn=\r\nProtocol:EV3\r\n\r\n"
HANDSHAKE_RSP = b"Accept:EV340\r\n\r\n"

MSG_SYSTEM = 0x01
MSG_DIRECT = 0x00
RPL_SYS = 0x03
RPL_DIRECT = 0x02
SYS_CREATE_DIR = 0x9B
SYS_BEGIN = 0x92
SYS_CONTINUE = 0x93


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


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", PORT))
    srv.listen(1)
    print(f"fake_ev3: слушаю 127.0.0.1:{PORT}", flush=True)
    conn, _ = srv.accept()

    # Handshake как в EV3ConnectionWiFi.cs: читаем запрос, отвечаем Accept:EV340.
    buf = b""
    while not buf.endswith(HANDSHAKE_REQ):
        chunk = conn.recv(1)
        if not chunk:
            raise SystemExit("fake_ev3: handshake оборван")
        buf += chunk
    conn.sendall(HANDSHAKE_RSP)
    print("fake_ev3: handshake OK", flush=True)

    upload = None  # [путь, ожидаемый размер, bytearray]
    handle = 0
    while True:
        pkt = recv_packet(conn)
        ctr = struct.unpack("<H", pkt[0:2])[0]
        msg_type = pkt[2]
        if msg_type == MSG_SYSTEM:
            cmd = pkt[3]
            args = pkt[4:]
            if cmd == SYS_CREATE_DIR:
                print(f"fake_ev3: CREATE_DIR ctr={ctr}", flush=True)
                send_packet(conn, struct.pack("<HBB", ctr, RPL_SYS, 0x00))
            elif cmd == SYS_BEGIN:
                size = struct.unpack("<I", args[0:4])[0]
                path = args[4:].split(b"\x00")[0].decode()
                first = args[4 + len(path) + 1:]
                handle = 1
                upload = [path, size, bytearray(first)]
                print(
                    f"fake_ev3: BEGIN_DOWNLOAD ctr={ctr} size={size} "
                    f"path={path} first={len(first)}",
                    flush=True,
                )
                send_packet(conn, struct.pack("<HBBB", ctr, RPL_SYS, 0x00, handle))
            elif cmd == SYS_CONTINUE:
                cont = args[1:]
                upload[2] += cont
                print(
                    f"fake_ev3: CONTINUE_DOWNLOAD ctr={ctr} +{len(cont)} "
                    f"= {len(upload[2])}/{upload[1]}",
                    flush=True,
                )
                send_packet(conn, struct.pack("<HBBB", ctr, RPL_SYS, 0x00, handle))
            else:
                raise SystemExit(f"fake_ev3: неизвестная system-команда {cmd:#x}")
        elif msg_type == MSG_DIRECT:
            bc = pkt[5:]
            if bc[0:2] != b"\xc0\x08":
                raise SystemExit("fake_ev3: в direct нет opFILE LOAD_IMAGE")
            print(f"fake_ev3: PROGRAM_START ctr={ctr} (запуск)", flush=True)
            send_packet(conn, struct.pack("<H", ctr) + bytes([RPL_DIRECT]) + bytes(10))
            break
        else:
            raise SystemExit(f"fake_ev3: неизвестный тип пакета {msg_type:#x}")

    path, size, data = upload
    if len(data) != size:
        raise SystemExit(
            f"fake_ev3: файл неполный: {len(data)} из {size}"
        )
    with open("/tmp/fake_ev3_upload", "wb") as f:
        f.write(data)
    print(f"fake_ev3: файл принят целиком ({size} байт) -> /tmp/fake_ev3_upload")
    print("fake_ev3: DONE")
    conn.close()
    srv.close()


if __name__ == "__main__":
    main()
