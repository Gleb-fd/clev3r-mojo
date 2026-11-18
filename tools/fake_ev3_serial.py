#!/usr/bin/env python3
"""Заглушка EV3 по serial (для теста пути /dev/rfcommN без железа).

Создаёт pty, линкует его по указанному пути (в имени должно быть "rfcomm",
чтобы classify_target выбрал потоковый транспорт) и обслуживает кадры
[len u16 LE][пакет], как tools/fake_ev3.py, но без TCP-handshake.

Ответы — реальный формат [ctr u16][0x03][эхо команды][статус][данные...]
(EV3Connection.cs:66-117); эхо-команда обязательна.

Все пути — аргументы командной строки; фиксированных /tmp-имён больше нет,
поэтому параллельные тесты не мешают друг другу. Свой symlink удаляется при
завершении (только если он наш); чужие файлы не трогаются.

  python3 tools/fake_ev3_serial.py --link /tmp/xxx/rfcomm_fake0 \
      --upload /tmp/xxx/upload.rbf [--report /tmp/xxx/report.jsonl] \
      [--fail-mode none|drop-begin-reply]
"""
import argparse
import json
import os
import pty
import struct
import sys
import time

MSG_SYSTEM = 0x01
MSG_DIRECT = 0x00
RPL_SYS = 0x03
RPL_DIRECT = 0x02
SYS_CREATE_DIR = 0x9B
SYS_BEGIN = 0x92
SYS_CONTINUE = 0x93
STATUS_OK = 0x00


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


def sys_reply(ctr, cmd, status=STATUS_OK, payload=b""):
    return struct.pack("<HBBB", ctr, RPL_SYS, cmd, status) + payload


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
    ap.add_argument("--link", required=True, help="путь symlink на pty (имя с 'rfcomm')")
    ap.add_argument("--upload", required=True, help="куда сохранить принятый файл")
    ap.add_argument("--report", default=None, help="JSONL-журнал событий")
    ap.add_argument(
        "--fail-mode", default="none", choices=["none", "drop-begin-reply"]
    )
    args = ap.parse_args()

    rep = Report(args.report)
    master, slave = pty.openpty()
    created = False
    if os.path.lexists(args.link):
        rep.add(event="link-exists", link=args.link)
        rep.close()
        os.close(master)
        os.close(slave)
        print(f"fake_ev3_serial: путь {args.link} уже занят", flush=True)
        return 2
    os.symlink(os.ttyname(slave), args.link)
    created = True
    rep.add(event="link", link=args.link, tty=os.ttyname(slave))
    print(f"fake_ev3_serial: pty {os.ttyname(slave)} -> {args.link}", flush=True)

    try:
        upload = None
        handle = 0
        while True:
            pkt = recv_packet(master)
            ctr = struct.unpack("<H", pkt[0:2])[0]
            msg_type = pkt[2]
            rep.add(event="packet", type=msg_type, ctr=ctr, size=len(pkt))
            if msg_type == MSG_SYSTEM:
                cmd = pkt[3]
                cmd_args = pkt[4:]
                rep.add(event="syscmd", cmd=cmd, ctr=ctr)
                if cmd == SYS_CREATE_DIR:
                    print(f"fake_ev3_serial: CREATE_DIR ctr={ctr}", flush=True)
                    send_packet(master, sys_reply(ctr, cmd))
                elif cmd == SYS_BEGIN:
                    size = struct.unpack("<I", cmd_args[0:4])[0]
                    path = cmd_args[4:].split(b"\x00")[0].decode()
                    first = cmd_args[4 + len(path) + 1:]
                    handle = 1
                    upload = [path, size, bytearray(first)]
                    rep.add(
                        event="begin", ctr=ctr, size=size, path=path, first=len(first)
                    )
                    print(
                        f"fake_ev3_serial: BEGIN_DOWNLOAD ctr={ctr} size={size} "
                        f"first={len(first)}",
                        flush=True,
                    )
                    if args.fail_mode == "drop-begin-reply":
                        rep.add(event="dropped-begin-reply", ctr=ctr)
                        print(
                            "fake_ev3_serial: BEGIN принят, ответ потерян",
                            flush=True,
                        )
                        continue
                    send_packet(master, sys_reply(ctr, cmd, payload=bytes([handle])))
                elif cmd == SYS_CONTINUE:
                    cont = cmd_args[1:]
                    upload[2] += cont
                    rep.add(
                        event="continue", ctr=ctr, got=len(cont), total=len(upload[2])
                    )
                    print(
                        f"fake_ev3_serial: CONTINUE_DOWNLOAD ctr={ctr} "
                        f"= {len(upload[2])}/{upload[1]}",
                        flush=True,
                    )
                    send_packet(master, sys_reply(ctr, cmd, payload=bytes([handle])))
                else:
                    rep.add(event="unknown-syscmd", cmd=cmd, ctr=ctr)
                    send_packet(master, sys_reply(ctr, cmd, status=0xFF))
            elif msg_type == MSG_DIRECT:
                bc = pkt[5:]
                rep.add(event="direct", ctr=ctr, bc_head=bc[:2].hex())
                print(f"fake_ev3_serial: PROGRAM_START ctr={ctr}", flush=True)
                send_packet(
                    master, struct.pack("<H", ctr) + bytes([RPL_DIRECT]) + bytes(10)
                )
                # Не закрывать master сразу: закрытие pty может отбросить
                # только что записанный ответ до того, как клиент его прочтёт.
                time.sleep(0.05)
                break
            else:
                rep.add(event="unknown-type", type=msg_type)
                print(f"fake_ev3_serial: неизвестный тип {msg_type:#x}", flush=True)
                return 3

        if upload is None:
            rep.add(event="no-upload")
            print("fake_ev3_serial: файл не передавался", flush=True)
            return 3
        path, size, data = upload
        if len(data) != size:
            rep.add(event="incomplete", got=len(data), want=size)
            print(f"fake_ev3_serial: неполный файл {len(data)}/{size}", flush=True)
            return 3
        with open(args.upload, "wb") as f:
            f.write(data)
        rep.add(event="upload", path=args.upload, size=size, brick_path=path)
        print(
            f"fake_ev3_serial: файл принят целиком ({size} байт) -> {args.upload}",
            flush=True,
        )
        print("fake_ev3_serial: DONE", flush=True)
        return 0
    finally:
        if created:
            try:
                os.unlink(args.link)
            except OSError:
                pass
        os.close(master)
        os.close(slave)
        rep.close()


if __name__ == "__main__":
    sys.exit(main())
