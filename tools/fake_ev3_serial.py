#!/usr/bin/env python3
"""Заглушка EV3 по serial (для теста пути /dev/rfcommN без железа).

Создаёт pty, линкует его в /tmp/rfcomm_fake0 (в имени есть "rfcomm", чтобы
classify_target выбрал потоковый транспорт) и обслуживает те же кадры
[len u16 LE][пакет], что tools/fake_ev3.py, но без TCP-handshake.
Собранный файл кладёт в /tmp/fake_ev3_upload.
"""
import os
import pty
import struct
import sys

LINK = "/tmp/rfcomm_fake0"

MSG_SYSTEM = 0x01
MSG_DIRECT = 0x00
RPL_SYS = 0x03
RPL_DIRECT = 0x02
SYS_CREATE_DIR = 0x9B
SYS_BEGIN = 0x92
SYS_CONTINUE = 0x93


def recv_exact(fd, n):
    buf = b""
    while len(buf) < n:
        chunk = os.read(fd, n - len(buf))
        if not chunk:
            raise SystemExit("fake_ev3_serial: клиент оборвал соединение")
        buf += chunk
    return buf


def recv_packet(fd):
    (size,) = struct.unpack("<H", recv_exact(fd, 2))
    if not 3 <= size <= 4096:
        raise SystemExit(f"fake_ev3_serial: плохая длина кадра {size}")
    return recv_exact(fd, size)


def send_packet(fd, payload):
    os.write(fd, struct.pack("<H", len(payload)) + payload)


def main():
    master, slave = pty.openpty()
    if os.path.exists(LINK):
        os.unlink(LINK)
    os.symlink(os.ttyname(slave), LINK)
    print(f"fake_ev3_serial: pty {os.ttyname(slave)} -> {LINK}", flush=True)

    upload = None
    handle = 0
    while True:
        pkt = recv_packet(master)
        ctr = struct.unpack("<H", pkt[0:2])[0]
        msg_type = pkt[2]
        if msg_type == MSG_SYSTEM:
            cmd = pkt[3]
            args = pkt[4:]
            if cmd == SYS_CREATE_DIR:
                print(f"fake_ev3_serial: CREATE_DIR ctr={ctr}", flush=True)
                send_packet(master, struct.pack("<HBB", ctr, RPL_SYS, 0x00))
            elif cmd == SYS_BEGIN:
                size = struct.unpack("<I", args[0:4])[0]
                path = args[4:].split(b"\x00")[0].decode()
                first = args[4 + len(path) + 1:]
                handle = 1
                upload = [path, size, bytearray(first)]
                print(
                    f"fake_ev3_serial: BEGIN_DOWNLOAD ctr={ctr} size={size} "
                    f"first={len(first)}",
                    flush=True,
                )
                send_packet(master, struct.pack("<HBBB", ctr, RPL_SYS, 0x00, handle))
            elif cmd == SYS_CONTINUE:
                cont = args[1:]
                upload[2] += cont
                print(
                    f"fake_ev3_serial: CONTINUE_DOWNLOAD ctr={ctr} "
                    f"= {len(upload[2])}/{upload[1]}",
                    flush=True,
                )
                send_packet(master, struct.pack("<HBBB", ctr, RPL_SYS, 0x00, handle))
            else:
                raise SystemExit(f"fake_ev3_serial: неизвестная команда {cmd:#x}")
        elif msg_type == MSG_DIRECT:
            print(f"fake_ev3_serial: PROGRAM_START ctr={ctr}", flush=True)
            send_packet(master, struct.pack("<H", ctr) + bytes([RPL_DIRECT]) + bytes(10))
            break
        else:
            raise SystemExit(f"fake_ev3_serial: неизвестный тип {msg_type:#x}")

    path, size, data = upload
    if len(data) != size:
        raise SystemExit(f"fake_ev3_serial: неполный файл {len(data)}/{size}")
    with open("/tmp/fake_ev3_upload", "wb") as f:
        f.write(data)
    print(f"fake_ev3_serial: файл принят целиком ({size} байт)")
    print("fake_ev3_serial: DONE")


if __name__ == "__main__":
    main()
