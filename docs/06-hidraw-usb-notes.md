# 06. Заливка на EV3 по USB через hidraw (`bp flash`)

Реализация — `src/bp/flash.mojo`, тесты framing — `src/bp/flash_test.mojo`.
Источники протокола: старый Python-путь (`/home/ssssq/Projects/letovo_projects/ev3tool.py`,
libusb) и C#-путь (`CleverDeploy/EV3Connection.cs`,
`Clever/Brick/Communication/EV3Connection{,USB}.cs`).

> **Статус проверки:** без живого кирпича. Framing/парсинг покрыты тестами
> (`FLASH_TEST OK`), dry-run печатает кадры побайтово. Живой обмен
> (ответы кирпича, тайминги, запуск) **требует проверки на железе** (§7).

## 1. Устройство и транспорт

* Кирпич — USB HID: **VID `0694` / PID `0005`**.
* Вместо libusb — ядро Linux: кирпич виден как `/dev/hidraw*`. Поиск без
  userspace-зависимостей: `/sys/class/hidraw/*/device/uevent`, строка
  `HID_ID=<bus>:<vid>:<pid>` (`is_ev3_uevent`: bus любой, vid/pid — hex,
  регистр любой).
* Права: пользователь должен иметь доступ к `/dev/hidraw*` (группа `plugdev` /
  udev-правило, иначе «EV3 не найден» при физически подключённом кабеле).
* Открытие — `O_RDWR + O_NONBLOCK` (`O_NONBLOCK=2048`); чтение — EAGAIN-цикл
  ~1 мс (`timed_read_full`, лимит — таймаут команды). Причина неблокирующего
  режима: в Mojo 1.1 `poll`/`select` недоступны через FFI без конфликта
  сигнатур со stdlib (см. комментарий «Бинарный ввод-вывод через libc»
  в `flash.mojo`: весь syscall-слой идёт через единственный символ `syscall`
  в форме `(Int, Int, Ptr, Int) -> Int` + единственный `usleep`).
* `.rbf` читается сырыми байтами через `openat/read` (Mojo-`open` в режиме `r`
  валидирует UTF-8 и для бинарного байткода не годится).

## 2. Карта кадра (всё little-endian)

```
HID-отчёт (1024 Б): [0x00][длина-пакета u16][пакет][pad 0x00...]
system-пакет:       [счётчик u16][0x01][команда u8][аргументы...]
direct-пакет:       [счётчик u16][0x00][globals u8][gb_hi/lb u8][байткод]
ответ system:       [счётчик u16][0x03|0x05][статус u8][данные...]
ответ direct:       [счётчик u16][0x02][global-данные...]
```

* `0x03` = SYSTEM_REPLY, `0x05` = SYSTEM_REPLY_NO_ERROR (принимаются оба,
  `EV3Connection.cs:101`); `0x02` = DIRECT_REPLY, `0x04` = DIRECT_REPLY_ERROR
  (ошибка VM — команда отклоняется).
* Ответ со своим счётчиком выбирается из потока (`recv_matching`, чужие
  пропускаются); таймаут ответа — 5 с (`REPLY_TIMEOUT_MS`, как в `ev3tool.py`),
  ретраи — до 3 (`MAX_ATTEMPTS`).

## 3. Команды заливки

| Команда | Код | Аргументы |
|---|---|---|
| `CREATE_DIR` | `0x9B` | путь C-строка (best-effort: каталог может существовать) |
| `BEGIN_DOWNLOAD` | `0x92` | `total u32 LE` + путь C-строка + первый кусок файла; ответ: статус + handle |
| `CONTINUE_DOWNLOAD` | `0x93` | `handle u8` + срез файла; статус `0x00` OK / `0x08` END_OF_FILE |
| direct `PROGRAM_START` | — | байткод `build_run_bytecode` (opFILE LOAD_IMAGE + opPROGRAM_START, globals=10) |

Чанк — 900 байт (`CHUNK_SIZE`, как `ev3tool.py` / `CreateEV3File` в C#):
первый кадр несёт `900 − len(путь+NUL)` байт файла, остальное — CONTINUE-кадрами.

## 4. Кодирование direct-параметров (ByteCodeBuffer.cs)

Короткие формы: CONST (`0x00–0x3F` / `0x81` / `0x82` / `0x83`), GLOBVAR
(`0x60…` / `0xE1` / `0xE2` / `0xE3`).

**Внимание:** строка в direct-командах — `0x84 … 0x00`, а в файле `.rbf` —
`0x80 …` (docs/04 §3.4). Это разные кодеки, не перепутать.

## 5. Куда кладётся файл

По умолчанию `../prjs/BrkProg_SAVE/<Имя>.rbf` (`brick_dest_for`: каталог +
stem имени `.rbf`). Происхождение имени каталога — из ТЗ; в найденном коде
его нет: `clever.sh` использует `../prjs/test123/`, Clever GUI —
`../prjs/<ПапкаПроекта>/`. Перед заливкой каталог создаётся через CREATE_DIR.

## 6. CLI

```
bp flash <file.rbf> [target]  — залить готовый байткод
bp flash <file.bp>  [target]  — compile (рядом с исходником) + залить
target: "" (usb: автовыбор первого EV3) | usb[:hidrawN|/dev/hidrawN]
      | bt:AA:BB:CC:DD:EE:FF (или голый MAC) — Bluetooth SPP, RFCOMM-канал 1
      | wifi:A.B.C.D (или голый IPv4) — Wi-Fi, TCP :5555
      | /dev/rfcommN — Bluetooth через RFCOMM serial device
      | dry — кадры печатаются hex'ом, устройство не открывается
BP_FLASH_DRY=1 — то же, что dry
```

### 6.1. Bluetooth и Wi-Fi (EV3ConnectionBluetooth/WiFi.cs)

Оба транспорта используют тот же system/direct-пакет, что USB, но без
HID-обёртки — кадр `[длина пакета u16 LE][пакет]` в обе стороны.

* **Wi-Fi** (`EV3ConnectionWiFi.cs`): TCP на порт 5555, затем handshake —
  клиент шлёт дословно `"GET /target?sn=\r\nProtocol:EV3\r\n\r\n"` и ждёт
  точный ответ `"Accept:EV340\r\n\r\n"`; дальше обычные кадры.
* **Bluetooth** (`EV3ConnectionBluetooth.cs`): поток SPP. В Linux два пути:
  RFCOMM-сокет (`bt:MAC`, sockaddr_rc, канал 1, нужен спаренный кирпич) или
  serial-устройство `/dev/rfcommN` (перед открытием порт переводится в
  raw-режим ioctl'ами TCGETS/TCSETS — эквивалент cfmakeraw, иначе line
  discipline портит бинарный поток).
* Неблокирующие сокеты + poll(POLLOUT/POLLIN) дают таймауты без сигналов;
  glibc `syscall()` возвращает -1 и кладёт код в errno, поэтому EAGAIN/
  EINPROGRESS проверяются через `__errno_location`, а не по отрицательному
  коду (в OLD-коде `rc == -11` никогда не срабатывало бы).
* Без железа транспорты проверяются заглушками: `tools/fake_ev3.py`
  (TCP :5555 с handshake) и `tools/fake_ev3_serial.py` (pty, линкуется в
  `/tmp/rfcomm_fake0`); файл на выходе сверяется байт в байт.

Сухой пример (`Test1.rbf`, 560 Б — всё в одном BEGIN-кадре):

```
[1] CREATE_DIR ../prjs/BrkProg_SAVE/ пакет=26 отчёт=1024 0100019b...
[2] BEGIN_DOWNLOAD total=560 first=560 пакет=599 отчёт=1024 02000192...
[3] direct PROGRAM_START globals=10 пакет=47 отчёт=1024 0300000a00...
```

## 7. Что проверить на живом кирпиче

1. Ответы BEGIN/CONTINUE_DOWNLOAD: реальные статус/handle, поведение при
   существующем каталоге (CREATE_DIR может вернуть ошибку — сейчас best-effort).
2. Запуск: хватает ли LOAD_IMAGE + PROGRAM_START, или GUI шлёт что-то ещё
   (сравнить с USB-дампом Clever при «Run»).
3. Тайминги/ретраи на полном файле (~1 КБ — несколько CONTINUE-кадров).
4. `DEFAULT_DEST_DIR`: виден ли `BrkProg_SAVE` в меню кирпича / File Manager.
