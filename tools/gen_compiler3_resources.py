#!/usr/bin/env python3
"""Генератор src/bp/compiler3_resources.mojo — тексты c_*.txt как Mojo-константы.

Источник: src/bp/resources/c_*.txt (байт-в-байт копии
Clev3r-1/Interpreter/Compiler/Resources/c_*.txt).

Файлы читаются с семантикой C# StringReader/ReadLine (разделитель \n,
хвостовой \r у строки срезается), поэтому в константу попадает текст с
переводами строк "\n". UTF-8 BOM срезается (в C# его убирает декодер
ресурсов; на выход компилятора он не влияет).

Запуск:  python3 tools/gen_compiler3_resources.py
"""
from __future__ import annotations

import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
RES_DIR = ROOT / "src" / "bp" / "resources"
OUT = ROOT / "src" / "bp" / "compiler3_resources.mojo"

# Порядок readLibrary (Compiler.cs:73-105); c_BitMask.txt не читается.
MODULES = [
    "c_runtimelibrary",
    "c_Assert",
    "c_Buttons",
    "c_Byte",
    "c_EV3",
    "c_EV3File",
    "c_LCD",
    "c_Mailbox",
    "c_Math",
    "c_Motor",
    "c_Program",
    "c_Sensor",
    "c_Speaker",
    "c_Text",
    "c_Thread",
    "c_Vector",
    "c_Sensor1",
    "c_Sensor2",
    "c_Sensor3",
    "c_Sensor4",
    "c_MotorA",
    "c_MotorB",
    "c_MotorC",
    "c_MotorD",
    "c_MotorAB",
    "c_MotorAC",
    "c_MotorAD",
    "c_MotorBC",
    "c_MotorBD",
    "c_MotorCD",
    "c_Row",
    "c_Time",
]
# c_NativeCode нужен только для EV3.NativeCode (дамп байткода в MAIN).
EXTRA = ["c_NativeCode"]


def escape(line: str) -> str:
    out = line.replace("\\", "\\\\").replace('"', '\\"').replace("\t", "\\t")
    return out


def main() -> None:
    chunks: list[str] = []
    chunks.append('"""Ресурсы компилятора стадии 3 — тексты модулей c_*.txt.\n')
    chunks.append("\n")
    chunks.append("Сгенерировано tools/gen_compiler3_resources.py; НЕ править руками.\n")
    chunks.append('Источники: src/bp/resources/c_*.txt (копии C#-ресурсов).\n')
    chunks.append('"""\n\n')

    for name in MODULES + EXTRA:
        path = RES_DIR / f"{name}.txt"
        raw = path.read_bytes()
        if raw.startswith(b"\xef\xbb\xbf"):
            raw = raw[3:]
        text = raw.decode("utf-8")
        lines = text.split("\n")
        for i, ln in enumerate(lines):
            if ln.endswith("\r"):
                lines[i] = ln[:-1]
        # перечисляемые литералы: соседние строки склеиваются компилятором Mojo
        chunks.append(f"comptime {name.upper()} = (\n")
        for ln in lines:
            chunks.append(f'    "{escape(ln)}\\n"\n')
        chunks.append(")\n\n")

    OUT.write_text("".join(chunks), encoding="utf-8")
    print(f"written {OUT} ({OUT.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
