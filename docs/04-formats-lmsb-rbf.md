# 04. Форматы: развёрнутый исходник `~Name.bp`, ассемблер-листинг `.lmsb`, бинарник `.rbf`

Назначение: исчерпывающая спецификация трёх форматов конвейера Clev3r и алгоритма `.lmsb → .rbf`,
достаточная для побайтовой реализации генератора `.rbf` на Mojo без чтения C#.
Все механизмы проверены на сквозном примере `/home/ssssq/Windows/~Program1/`
(`~Program1.bp` 779 Б → `Program1.lmsb` 5505 Б → `Program1.rbf` 1015 Б); места, проверенные
только чтением кода, помечены «(проверено кодом)», неоднозначные — «(гипотеза)».

Конвейер (Builder.cs:59-140): `Preprocessor` → `Utils.Interpreter` → запись `~Name.bp`
(Builder.cs:450-467, 486-506) → `Compiler` (`.bp`→`.lmsb`, Compiler.cs:170-466) → `Assembler`
(`.lmsb`→`.rbf`, Assembler.cs:70-108, 593-631). Каталог вывода: `<путь>` + `"~" + имя-без-.bp`
(Builder.cs:79; префикс `"~"` захардкожен в InterpreterConsole/Program.cs:35,43).
Файлы в каталоге: `~Name.bp` (префикс `~` + исходное имя, Builder.cs:460), `Name.lmsb`
(Builder.cs:379, WriteAllLines), `Name.rbf` (Builder.cs:425, WriteAllBytes).

---

## 1. Формат развёрнутого исходника `~Name.bp`

### 1.1. Как строится текст

Источник строк — `Data.Project.OutputLines`; каждая строка выводится как `line.NewLine`
(Builder.cs:486-506). `NewLine = string.Join(" ", слова)` — все токены строки разделяются
ровно одним пробелом; пустая строка → `""` (DataTemplates/Line.cs:17-28).
Следствия (видно в `~Program1.bp`): скобки, запятые, операторы — отдельные «слова»:
`LCD.Text ( 1 , 0 , 0 , 2 , gv_d1 )`; регистр ключевых слов и строк сохраняется
(`While "True"`, `if lv_n_1 = 2 Then`); регистр переменных/подпрограмм/меток — теряется
(апперкейс + переименование, см. 1.2); регистр имён встроенных объектов (`LCD.Text`,
`Sensor2.Raw1`) — сохраняется (токен METHOD не переименовывается).

Токенизация строки (LineBuilder.cs:11-292):
- комментарий `'...` до конца строки отбрасывается (LineBuilder.cs:18-31);
- строковые литералы `"..."` — один токен целиком, с кавычками и внутренним регистром
  (LineBuilder.cs:35-93);
- одиночные символы `+ - / * ( ) { } , = < > ! | & [ ] # ; % ^ @` — отдельные токены
  (LineBuilder.cs:108);
- склейка пар: `<` `>` `=` `!` `+` `-` `/` `*` + `=` → `<=`, `>=`, `==`… ; `&&`, `||`,
  `()`, `{}`, `[]`, `++`, `--`(только в конце строки), `<>`, `@`+следующее слово
  (LineBuilder.cs:142-235); `string[`/`number[` не режутся (LineBuilder.cs:112-121);
- слова с токенами VARIABLE/SUBNAME/FUNCNAME/LABELNAME/LABEL приводятся к ВЕРХНЕМУ регистру
  (LineBuilder.cs:244-289).

### 1.2. Переименования (Linker.cs)

Порядок фаз: `Linker.Start()` (Linker.cs:17-78) вызывается из препроцессора; переименование
происходит ДО разбора вызовов в `Utils.Interpreter`. Имена в `~Name.bp` уже конечные.

| Что | Правило | Результат | Ссылка |
|---|---|---|---|
| Глобальная переменная (вне Function) | `"gv_" + ИМЯ` → lowercase; `@` удаляется | `d1` → `gv_d1` | Linker.cs:455, 488-491 |
| Локальная переменная функции №k (счётчик FUNCINIT от 1) | `"lv_" + ИМЯ + "_" + k` → lowercase | `data` в 1-й функции → `lv_data_1` | Linker.cs:459, 492-497 |
| Переменная `@name` внутри функции | как глобальная: `gv_name` | — | Linker.cs:498-501 |
| Метка вне функции | `"gl_" + ИМЯ` → lowercase; токен LABEL получает `:` в конце | `loop` → `gl_loop` / `gl_loop:` | Linker.cs:456, 504-527 |
| Метка внутри функции №k | `"ll_" + ИМЯ + "_" + k` | `ll_loop_1` | Linker.cs:461, 512-515 |
| Свойство модуля `Mod.Prop` | `"pr_" + "mod_prop"` (точка→`_`, lowercase), токен → VARIABLE | `EV3.BatteryLevel` → `pr_ev3_batterylevel` | Linker.cs:457, 528-537 |
| Вызов BP-метода модуля `Mod.Met` | `"m_" + "mod_met" + "_" + N` (N = число параметров) | — | Linker.cs:330, 335-349 |
| Функция/процедура (FUNCINIT/FUNCCALL/SUBCALL/SUBINIT, METHODCALL-`thread.run`) | `"f_" + ИМЯ + "_" + N`, N = число параметров | `map_data(2 пар.)` → `f_map_data_2` | Linker.cs:329, 350-394 |
| Переменные/метки в методах модулей | только `lv_`/`ll_` со своим счётчиком; `gv_` в модулях — ошибка 2008/2009 | — | Linker.cs:560-607 |

Число параметров N (Linker.cs:100-143): считаются запятые на глубине скобок = 1, результат
`запятые + 1`; если первый токен строки `sub` или `thread.run` → N=0; если встречен токен `()`
(DOUBLEBRACKET) → N=0. Для строки `Function map_data ( in number n , out number data )` N=2
(проверено: `.lmsb` содержит `SUB_F_MAP_DATA_2`). Для встроенных вызовов (`LCD.Text`, `Math.Floor`,
`Sensor2.Raw1`, `Program.Delay`) — токен METHOD, а не MODULEMETHOD, переименования нет
(LineBuilder.cs:370-389; проверено на `~Program1.bp`).

Инициализация Function→Sub: строка `Function X (...)` превращается в `Sub X` и
`EndFunction` → `EndSub` (Utils/Interpreter.cs:125-174) — в `~Name.bp` функций уже нет, только `Sub`.

### 1.3. Порядок строк в `~Name.bp`

Формируется `CreateProjectOutputLines` (Utils/Interpreter.cs:345-446), затем `RewriteOutLines`
выбрасывает Sub, которых никто не вызвал (Utils/Interpreter.cs:756-788):

| # | Блок | Содержимое | Ссылка |
|---|---|---|---|
| 1 | `Propertys` | `pr_<имя> = 0` / `pr_<имя> = ""` / `pr_<имя>[0] = 0`/`""` — по одному на используемое свойство, тип из модуля | Linker.cs:788-858 |
| 2 | varInit: параметры функций | `lv_<par>_<k> = 0` / `= ""` / `[0] = ...` — словарь `variables`, порядок вставки (INPUT до OUTPUT в порядке параметров вызова) | Utils/Interpreter.cs:448-487 |
| 3 | varInit: остальные переменные MAIN | `gv_<имя> = 0` / `""` / `[0] = ...` — порядок первого присваивания (Data.Project.Variables) | Utils/Interpreter.cs:606-652 |
| 4 | MAIN | строки main-программы; вызовы с параметрами развёрнуты в `lv_x = <арг>` / `f_name ()` / `<выход> = lv_x` (SUBCALL-строка всегда с пустыми `()`) | Utils/Interpreter.cs:200-343 |
| 5 | Sub'ы | `Sub f_<имя>_<N>` … `EndSub` | Linker.cs:662-698 |
| 6 | (тела Function — уже превращены в Sub и лежат в блоке 5-структуры; методы модулей `m_...` — после Sub) | | Utils/Interpreter.cs:402-445 |

Пример 1:1 — `~Program1.bp` (строки 1-2 = п.2 для параметров `n`,`data`; 3-8 = п.3; 9-30 = MAIN;
31-38 = Sub). Строки 19-21 показывают развёртку вызова `map_data(2, d1)` при
`Function map_data (in number n, out number data)`:
`lv_n_1 = 2` → `f_map_data_2 ()` → `gv_d1 = lv_data_1`.

---

## 2. Формат `.lmsb`

### 2.1. Общая структура (Compiler.cs:302-465)

Текстовый файл; строки собираются `StreamWriter.WriteLine` (на Windows — CRLF; в текущих
копиях — LF; ассемблеру безразлично). Отступы и пустые строки произвольны — игнорируются.
Комментарий — от `//` до конца строки (Assembler.cs:642-645). Секции строго в порядке:

| # | Секция | Шаблоны строк | Ссылка |
|---|---|---|---|
| S1 | Глобальные данные рантайм-модулей | строки `DATA*`/`ARRAY*` из ресурсов `c_*.txt` (всё вне `subcall`/`inline`/`init`), в порядке вызовов `readLibraryModule` (см. 2.5) | Compiler.cs:73-168 |
| S2 | Глобальные данные пользователя | на каждую переменную: Number → `DATAF V<ИМЯ>`; Text → `DATAS V<ИМЯ> 252`; NumberArray/TextArray → `ARRAY16 V<ИМЯ> 2`; порядок = порядок первого присваивания | Compiler.cs:305-330 |
| S3 | Счётчики потоков | `DATA32 RUNCOUNTER_<T>` на каждый `Thread.Run` (в порядке первого использования) | Compiler.cs:331-336 |
| S4 | *пустая строка* | `target.WriteLine()` | Compiler.cs:338 |
| S5 | `vmthread MAIN { … }` | см. 2.2 | Compiler.cs:341-355 |
| S6 | `vmthread T<имя> { … }` на каждый поток | см. 2.3 | Compiler.cs:358-377 |
| S7 | `subcall PROGRAM_MAIN { … }` | см. 2.4 | Compiler.cs:382-454 |
| S8 | Тела библиотечных subcall | текст ресурсов `subcall …//спека { … }` целиком, в порядке множества `references` | Compiler.cs:457-464 |

Имена переменных в `.lmsb` = `V` + ВЕРХНЕЕ имя из `.bp` (`lv_n_1` → `VLV_N_1`; Scanner
приводит ID к верхнему регистру, Scanner.cs:245).

### 2.2. Тело `vmthread MAIN` (Compiler.cs:341-355)

```text
vmthread MAIN
{
<runtimeinit>              ← конкатенация init-блоков ресурсов: "    " + тело без '{' '}' .Trim() + "\n";
                             внутренние \n и табы ресурсов сохраняются; порядок = порядок модулей
<initlist>                 ← на каждую переменную S2:
    MOVEF_F 0.0 V<X> | STRINGS DUPLICATE '' V<X> | CALL ARRAYCREATE_FLOAT V<X> | CALL ARRAYCREATE_STRING V<X>
    MOVE32_32 0 RUNCOUNTER_<T>        (на каждый поток)
    ARRAY CREATE8 1 LOCKS
[блок загрузки native code — только при использовании EV3.NativeCode, Compiler.cs:469-496]
    CALL PROGRAM_MAIN -1
    PROGRAM_STOP -1
}
```

### 2.3. Тело `vmthread T<имя>` (Compiler.cs:358-377)

```text
vmthread T<ИМЯ>
{
    DATA32 tmp
  launch:
    CALL PROGRAM_<ИМЯ> <i>            (i = номер потока, с 0)
    CALL GETANDINC32 RUNCOUNTER_<ИМЯ> -1 RUNCOUNTER_<ИМЯ> tmp
    JR_GT32 tmp 1 launch
}
```

### 2.4. Тело `subcall PROGRAM_MAIN` (Compiler.cs:382-454)

Локальная область (заполняется ассемблером по порядку появления, см. 2.6):

| Строки | Комментарий |
|---|---|
| `IN_32 SUBPROGRAM` | селектор подпрограммы |
| `DATA32 INDEX` | адрес возврата |
| `ARRAY8 STACKPOINTER 4` | «4 байта впустую ради выравнивания» (комментарий Compiler.cs:392) |
| `DATAF F<имяФункции>.<переменная>` на каждую числовую локаль каждой функции | порядок: `functiondefinitions.Values` (вставка: `""` первым, затем F.FUNCTION по порядку появления); имена: возврат `F<имя>.`, параметры `F<имя>.<PAR>`, темпы `F<имя>.<0,1,2…>` (FunctionDefinition.cs:96-125,163-184); для функции без имени — `F.0`, `F.1`, … |
| `ARRAY32 RETURNSTACK2 128`, `ARRAY32 RETURNSTACK 128` | стек возвратов, 512+512 Б |
| `DATAS S<имяФункции>.<…> 252` на каждую строковую локаль | аналогично F |
| при рекурсии (Compiler.cs:413-425): `DATA16 NUMBERSTACKHANDLE`, `DATAF NUMBERSTACKSIZE`, `DATA16 STRINGSTACKHANDLE`, `DATAF STRINGSTACKSIZE`, `CALL ARRAYCREATE_FLOAT NUMBERSTACKHANDLE`, `MOVEF_F 0.0 NUMBERSTACKSIZE`, `CALL ARRAYCREATE_STRING STRINGSTACKHANDLE`, `MOVEF_F 0.0 STRINGSTACKSIZE` | |
| `MOVE8_8 0 STACKPOINTER` | инициализация указателя стека |
| диспетчер потоков (Compiler.cs:430-441): на каждый поток `JR_NEQ32 SUBPROGRAM <i> dispatch<l>`, `WRITE32 ENDSUB_<ИМЯ>:ENDTHREAD STACKPOINTER RETURNSTACK`, `ADD8 STACKPOINTER 1 STACKPOINTER`, `JR SUB_<ИМЯ>`, `dispatch<l>:` | l — общий счётчик меток |
| код main-программы | генерация операторов Compiler.cs:576-1112 |
| `ENDTHREAD:` | |
| `ARRAY DELETE NUMBERSTACKHANDLE` / `ARRAY DELETE STRINGSTACKHANDLE` | только при рекурсии |
| `RETURN` | |
| тела всех Sub: `SUB_<ИМЯ>:`, код, `RETSUB_<ИМЯ>:`, `SUB8 STACKPOINTER 1 STACKPOINTER`, `READ32 RETURNSTACK STACKPOINTER INDEX`, `JR_DYNAMIC INDEX`, `ENDSUB_<ИМЯ>:` | Compiler.cs:548-574 |

Управляющие конструкции (метки из общего счётчика `labelcount`, начиная с 0):
- `IF c THEN … (ELSEIF …)* (ELSE …)? ENDIF` → `JR/сравнение … else<l>_1:`; на каждый ELSEIF/ELSE
  `JR endif<l>` + `else<l>_<k>:`; в конце `else<l>_<n+1>:` и `endif<l>:` (Compiler.cs:631-690).
- `WHILE c … ENDWHILE` → `while<l>:`, условие-переход на `endwhile<l>`, `whilebody<l>:`, тело,
  условие-переход (jumpIfTrue) на `whilebody<l>`, `endwhile<l>:` (Compiler.cs:692-714).
- `FOR v = a TO b [STEP s]` → присваивание, `for<l>:`, тест (`CALL LE`/`JR_LTEQF`/`JR_GTF` или
  `CALL GE`/…, при знакопеременном STEP — `CALL LE_STEP`), `forbody<l>:`, тело, инкремент
  `ADDF`, тест на `forbody<l>`, `endfor<l>:` (Compiler.cs:716-792).
- Условия-тексты: `GenerateJumpIfCondition` — `AND8888_32 <tmp> -538976289 <tmp>` (апперкейс),
  `STRINGS COMPARE <tmp> 'TRUE' <tmp>`, `JR_NEQ8/JR_EQ8 <tmp> 0 <label>`;
  константа `'TRUE'`/`'FALSE'` даёт безусловный `JR <label>` (Expression.cs:76-88, 149-160).
- Деление (если не отключено PRAGMA): макрос с уникальным номером `#` (Compiler.cs:1399-1413):
  `DATAF tmpf<#>` / `DATA8 flag<#>` / `DIVF :0 :1 tmpf<#>` / `CP_EQF 0.0 :1 flag<#>` /
  `SELECTF flag<#> 0.0 tmpf<#> :2` + пустая строка после (замечена в `.lmsb`:205,220).
- `Program.Delay(ms)` разворачивается в `DATA32 milliseconds<#>` / `MOVEF_32 <ms>.0 milliseconds<#>`
  / `DATA32 timer<#>` / `TIMER_WAIT milliseconds<#> timer<#>` / `TIMER_READY timer<#>`
  (c_Time.txt; проверено `.lmsb`:185-189).
- Вызов Sub: `WRITE32 ENDSUB_<ИМЯ>:CALLSUB<l> STACKPOINTER RETURNSTACK`,
  `ADD8 STACKPOINTER 1 STACKPOINTER`, `JR SUB_<ИМЯ>`, `CALLSUB<l>:` (Compiler.cs:842-847).
- `GOTO <метка>` → `JR L<метка>`; метка `x:` → `Lx:` (Compiler.cs:794-809, 848-852).

### 2.5. Порядок ресурсов рантайма (влияет на адреса глобальных!)

readLibrary (Compiler.cs:73-107), порядок фиксирован: `c_runtimelibrary, c_Assert, c_Buttons,
c_Byte, c_EV3, c_EV3File, c_LCD, c_Mailbox, c_Math, c_Motor, c_Program, c_Sensor, c_Speaker,
c_Text, c_Thread, c_Vector, c_Sensor1, c_Sensor2, c_Sensor3, c_Sensor4, c_MotorA, c_MotorB,
c_MotorC, c_MotorD, c_MotorAB, c_MotorAC, c_MotorAD, c_MotorBC, c_MotorBD, c_MotorCD, c_Row,
c_Time`. Глобальные данные вне subcall'ов каждого файла дописываются в `runtimeglobals` в
порядке появления (комментарии `//` срезаются, пустые строки пропускаются — Compiler.cs:126-138).
Проверено на Program1: порядок FD_NATIVECODECOMMAND(с_EV3) → STOPLCDUPDATE(c_LCD) →
NUMMAILBOXES(c_Mailbox) → MOTORISINVERTED,FIRSTOF2,LOCKS(c_Motor) → s*out*(c_Sensor1-4) →
newArray1d…(c_Row) → timeMC…(c_Time) = `.lmsb`:1-60.

### 2.6. Директивы данных (Assembler.cs:160-196, 233-342)

Вне тела объекта — глобальная область (одна на файл); внутри `{…}` — локальная область объекта.
| Директива | size | count | DataType | Примечание |
|---|---|---|---|---|
| `DATA8 <ID>` | 1 | 1 | I8 | ID: `[A-Z_][A-Z0-9_]*` (после uppercase), последний токен (Assembler.cs:712-728) |
| `DATA16 <ID>` | 2 | 1 | I16 | |
| `DATA32 <ID>` | 4 | 1 | I32 | |
| `DATAF <ID>` | 4 | 1 | F | |
| `DATAS <ID> <K>` | 1 | K | I8 | K целое 1..32767 (Assembler.cs:730-751) |
| `ARRAY8 <ID> <K>` | 1 | K | I8 | синоним DATAS (Assembler.cs:176-179) |
| `ARRAY16 <ID> <K>` | 2 | K | I16 | |
| `ARRAY32 <ID> <K>` | 4 | K | I32 | |
| `ARRAYF <ID> <K>` | 4 | K | F | |
| `IN_8/16/32/F <ID>` | 1/2/4/4 | 1 | I8/I16/I32/F | параметр subcall, доступ Read |
| `IN_S <ID> <K>` | 1 | K | I8 | ReadMany; K ≤ 255 (LMSObject.cs:349-353) |
| `OUT_8/16/32/F <ID>` | | | | Write; `OUT_S <ID> <K>` → Write |
| `IO_8/16/32/F <ID>` | | | | ReadWrite; `IO_S <ID> <K>` → ReadWrite |

Выравнивание (DataArea.cs:57-84): перед размещением элемента `endofarea` дополняется байтами
до кратности `size`; для параметров (IN/OUT/IO) паддинг запрещён (ошибка). Параметры обязаны
идти до любых DATA в области (DataArea.cs:64-71). Повторное имя — ошибка. Дубликат директив
`DATA` внутри тела допустим и просто продолжает ту же локальную область (позиции
`milliseconds14`…`flag26` в Program_MAIN идут после S.0 — проверено байтами, §3.4).

### 2.7. Синтаксис инструкций

- Мнемоника — 1 или 2 токена верхнего регистра (весь токенайзер приводит к верхнему регистру
  строки и числа, кроме `'строк'` — Assembler.cs:669-697). Разделители: пробел, таб, `,`, `(`,
  `)`, `{` — пропускаются; `}` — самостоятельный токен-конец тела (Assembler.cs:633-710).
  Поэтому `UI_DRAW(TOPLINE,0)` ≡ `UI_DRAW TOPLINE 0` (проверено `.lmsb`:233 ↔ байты §3.4).
- Операнды (Assembler.cs:521-591):
  | Вид | Распознавание | Кодирование |
  |---|---|---|
  | переменная | первый символ `[A-Z_]` | ссылка на локальную область, иначе глобальную; суффикс `+<смещение>` прибавляется к позиции (Assembler.cs:533-541) |
  | метка-разность | содержит `:` и не начинается с `'` | `A:B` → 32-битная константа `pos(B)−pos(A)` (§3.3) |
  | целое | `[0-9-]…`, парсится Int32 (инвариантная культура) | константа |
  | дробное | иначе double (инвариантная культура) | 0x83 + float32 LE |
  | строка | `'…'` | 0x80 + байты + 0x00; только ASCII 1..255 (LMSObject.cs:122-135) |
- `CALL <имя> <парам…>` — opcode 0x09, затем ID subcall-объекта, число параметров, параметры
  (Assembler.cs:345-380). Имя может быть ещё не объявлено (forward) — объект создаётся сразу
  с очередным ID (это фиксирует порядок ID!).
- Метка: токен, заканчивающийся на `:`, ровно один `:` (Assembler.cs:382-389). Значение —
  текущая длина кода объекта (LMSObject.cs:199-202).
- Спец-типы операндов в таблице опкодов (VMCommand.cs:31-116): `8/16/32/F` — данные,
  `?` — безтиповый (например результат `INPUT_READEXT`), `L` — метка перехода, `T` — имя
  vmthread (кодируется константой-ID), `S` — имя subcall (имя `0` → константа 0),
  `P` — число параметров (расширяет список операндов; Assembler.cs:489-502). Суффиксы доступа:
  `*` = Write, `+` = ReadMany (Assembler.cs:103-114).
- Полная таблица опкодов — `Interpreter/Assembler/Resources/bytecodelist.txt` (470 строк,
  формат: `HEX[HEX] ИМЯ [типы]`), должна быть встроена в Mojo-порт как есть.

---

## 3. Бинарный формат `.rbf`

### 3.1. Заголовок файла (16 байт, всё little-endian, DataWriter.cs:23-36)

| Смещение | Размер | Поле | Значение (Program1) | Ссылка |
|---|---|---|---|---|
| 0 | 4 | магия `'L''E''G''O'` | `4c 45 47 4f` | Assembler.cs:614-617 |
| 4 | 4 | полный размер файла | `f7 03 00 00` = 1015 | Assembler.cs:618 |
| 8 | 2 | версия | `68 00` = 0x0068 (константа) | Assembler.cs:619 |
| 10 | 2 | число объектов N | `04 00` = 4 | Assembler.cs:620 |
| 12 | 4 | байт глобальных данных | `f8 00 00 00` = 248 | Assembler.cs:621 |

Контрольных сумм, таймстампов, имён — НЕТ.

### 3.2. Оглавление: N заголовков объектов по 12 байт (@16 … @16+12N−1)

| Поле | Размер | Thread (LMSThread) | Subcall (LMSSubCall) | Ссылка |
|---|---|---|---|---|
| offsetToInstructions | 4 | абс. смещение тела | то же; у алиаса — offset реализации | LMSObject.cs:289-295, 370-376 |
| owner | 2 | всегда 0 | всегда 0 | |
| triggerCount | 2 | 0 | 1 | |
| localBytes | 4 | `locals.TotalBytes()` (обычно 0) | размер локальной области (у алиаса — реализации) | |

Program1 (заголовки по 12 Б, Assembler.cs:622-628):
```text
@16 obj1 MAIN:        40 00 00 00 | 00 00 | 00 00 | 00 00 00 00   offset=64,  trigger=0, locals=0
@28 obj2 PROGRAM_MAIN:52 01 00 00 | 00 00 | 01 00 | 2d 05 00 00   offset=338, trigger=1, locals=1325
@40 obj3 LCD.CLEAR:   ad 03 00 00 | 00 00 | 01 00 | 00 00 00 00   offset=941, trigger=1, locals=0
@52 obj4 LCD.TEXT:    bf 03 00 00 | 00 00 | 01 00 | 13 01 00 00   offset=959, trigger=1, locals=275
```
Порядок объектов в файле = порядок их ID; ID = `objects.Count + 1` в момент ПЕРВОГО
упоминания имени в `.lmsb` (определение или forward-ссылка из CALL/OBJECT_START/… —
Assembler.cs:122-158, 345-380, 437-487). totalheadersize = 16 + 12N (Assembler.cs:606).

### 3.3. Тела объектов (одно за другим по возрастанию ID)

- vmthread: байткод + `0x0A` (OBJECT_END). RETURN в конце НЕ дописывается (LMSObject.cs:297-302).
- subcall: `numpar` (1 Б) + описатели параметров + байткод + `0x08` (RETURN) + `0x0A`
  (LMSObject.cs:378-447). Алиас subcall тела не имеет (LMSObject.cs:380-383) (проверено кодом;
  компилятор Clev3r алиасы не создаёт — гипотеза: только ручные .lms).
- Описатель параметра: бит 0x80 = IN, 0x40 = OUT; тип в младших 3 битах: 0=I8, 1=I16, 2=I32,
  3=F, 4=строка (за байтом идёт длина) (Assembler.cs:853-891, LMSObject.cs:405-427).
  Program1: obj2 `01 82` = 1 параметр IN_32; obj4 `05 83 83 83 83 84 fc` = IN_F×4, IN_S 252.

### 3.4. Кодирование операндов (LMSObject.cs:58-148; дизасемблер Assembler.cs:980-1079)

| Форма | Байты | Условие |
|---|---|---|
| короткая константа | 1 Б: `v & 0x3F` | −32 ≤ v ≤ 31 (0x00..0x1F — положительные, 0x20..0x3F — отрицательные −32..−1) |
| константа 8 | `0x81`, s8 | −128..127 |
| константа 16 | `0x82`, i16 LE | −32768..32767 |
| константа 32 / float | `0x83`, i32 LE / IEEE-754 single LE | иначе; float кодируется ТОЙ ЖЕ формой 0x83 (LMSObject.cs:137-148) |
| строка | `0x80`, байты ASCII, `0x00` | |
| переменная короткая | `0x40|idx` локальная, `0x60|idx` глобальная | 0 ≤ idx ≤ 31 |
| переменная 8/16/32 | `0xC1/0xC2/0xC3` + s8/i16/i32 (локальная), `0xE1/0xE2/0xE3` (глобальная) | idx > 31 |
| метка назад (после определения) | кратчайшая из форм: 1 Б `v&0x3F` при dist−1 ≥ −32; `0x81` при dist−2 ≥ −128; `0x82` при dist−3 ≥ −32768; `0x83` при dist−5 | dist = pos(метки) − pos(параметра); значение = dist − K, K = длина кодирования (LMSObject.cs:150-180) — т.е. отсчёт от КОНЦА инструкции |
| метка вперёд | `0x83` + 4 Б-заглушка, патчится | значение = pos(метки) − (i+4), i = позиция первого байта заглушки (LMSObject.cs:182-189, 214-262) |
| разность меток `A:B` | всегда `0x83` + 4 Б, патчится | значение = pos(B) − pos(A) (без поправки на конец инструкции) (LMSObject.cs:192-197, 232-243) |
| CALL | `0x09`, ID, numpar, параметры | ID и numpar — через обычное кодирование констант |

Второй байт двухбайтовой мнемоники прогоняется через кодирование констант: для всех
опкодов таблицы, кроме `UI_DRAW TEXTBOX` (8420), он ≤ 31 и пишется одним байтом; для
TEXTBOX получится `84 81 20` (квирк, воспроизвести обязательно; проверено кодом,
LMSObject.cs:58-65 + 67-93; единственный такой случай в bytecodelist.txt).

### 3.5. Побайтовый разбор Program1.rbf (1015 Б)

Раскладка глобальных (позиции подтверждены ссылками из байткода: G4=STOPLCDUPDATE,
G8=NUMMAILBOXES, G12=MOTORISINVERTED, G16=FIRSTOF2, G32=LOCKS, G36..G80=s*out*,
G84..G130=моторы A-D, G132..G143=новые массивы c_Row, G144..G176=timeMC1-9,
G216..G244=VLV_N_1…VGV_D2_MAX; итого 248 = 0xF8; паддинг по выравниванию на 95, 107, 119,
131, 134-135):

| offs | байты | разбор |
|---|---|---|
| 0 | `4c 45 47 4f f7 03 00 00 68 00 04 00 f8 00 00 00` | заголовок (§3.1) |
| 16..63 | см. §3.2 | 4 заголовка объектов |
| 64 | `3a 00 64` | MOVE32_32 0 →G4 (`MOVE32_32 0 STOPLCDUPDATE`) |
| 67 | `3a 00 68` | MOVE32_32 0 →G8 |
| 70 | `a2 00 0f` | OUTPUT_RESET 0 15 |
| 73..152 | `cc 00 00 6c` ×4; `cc vv ii 70` ×16 | WRITE8 <v> <i> →G12 (MOTORISINVERTED), →G16 (FIRSTOF2; значения v/i из init c_Motor) |
| 153 | `99 0a 3f` | INPUT_DEVICE CLR_ALL −1 (2-б. опкод 990A; −1 → `3f`) |
| 156 | `c1 01 00 e1 20` | ARRAY CREATE8 0 →G32 (`ARRAY CREATE8 0 LOCKS`) |
| 161..253 | `3a 00 e1 24 …`, `3a 00 e2 90 00 …` | MOVE32_32 0 →G36..G80 (12 шт по 4 Б: s1out1..s4out3), →G144..G176 (9 шт по 5 Б: timeMC1-9) |
| 254..325 | `3f 83 00 00 00 00 e2 d8 00` ×8 | MOVEF_F 0.0 →G216..G244 (по 9 Б) |
| 326 | `c1 01 01 e1 20` | ARRAY CREATE8 1 →G32 |
| 331 | `09 02 01 3f` | CALL id=2 (PROGRAM_MAIN), numpar=1, параметр −1 |
| 335 | `02 3f` | PROGRAM_STOP −1 |
| 337 | `0a` | OBJECT_END; длина тела obj1 = 274 = 338−64 ✓ |
| 338 | `01 82` | obj2: numpar=1, дескриптор IN_32 |
| 340 | `30 00 48` | MOVE8_8 0 →L8 (STACKPOINTER) |
| 343..414 | `3f 83 … e2 XX 00` | MOVEF_F 0.0 →G216..G244 (8 × 9 Б) |
| 415 | `3f 83 00 00 f8 41 e2 e8 00` | MOVEF_F 31.0 →G232 (0x41F80000 = 31.0f) |
| 424 | `3f 83 00 00 88 42 e2 ec 00` | MOVEF_F 68.0 →G236 (0x42880000) |
| 433..468 | `3f 83 …` | MOVEF_F 0.0/31.0/68.0 для остальных gv (`.lmsb`:152-157) |
| 469 | `09 03 00` | CALL id=3 (LCD.CLEAR), numpar=0 |
| 472 | `9e 00 01 00 3f 12 01 e1 30` | INPUT_READEXT 0 1 0 −1 18 1 →G48 (s2out1); 18 → короткая форма `12`, −1 → `3f` |
| 481 | `3b e1 30 e2 e0 00` | MOVE32_F G48 →G224 |
| 487 | `7d 0b e2 e0 00 80 25 67 00 81 63 c2 1c 04` | STRINGS VALUE_FORMATTED G224 '%g' 99 →L1052 (S.0; 99 → `81 63`) |
| 501 | `09 04 05 83 00 00 80 3f 83 00 00 00 00 83 00 00 00 00 83 00 00 00 40 c2 1c 04` | CALL id=4 (LCD.TEXT) 1.0 0.0 0.0 2.0 →L1052 |
| 527 | `3f 83 00 00 00 40 e2 d8 00` | MOVEF_F 2.0 →G216 (`lv_n_1 = 2`) |
| 536 | `ce 83 81 fe ff ff 48 c2 1c 02` | WRITE32 −383 →L8 →L540 (разность `ENDSUB_F_MAP_DATA_2:CALLSUB5` = 556−939 = −383) |
| 546 | `10 48 01 48` | ADD8 L8 1 →L8 |
| 550 | `40 83 cb 00 00 00` | JR +203 (SUB_F_MAP_DATA_2 = program-offset 419 = файл 759; 759−556=203) |
| 556 | `3f e2 dc 00 e2 e0 00` | (метка CALLSUB5) MOVEF_F G220 →G224 |
| 563 | `7d 0b e2 e0 00 80 25 67 00 81 63 c2 1c 04` | STRINGS VALUE_FORMATTED G224 '%g' 99 →L1052 |
| 577 | `09 04 05 83 00 00 80 3f 83 00 00 00 00 83 00 00 a0 41 83 00 00 00 40 c2 1c 04` | CALL LCD.TEXT 1.0 0.0 20.0 2.0 S.0 (20.0 = 0x41A00000) |
| 603 | `9e 00 02 00 3f 12 01 e1 3c` | INPUT_READEXT 0 2 0 −1 18 1 →G60 (s3out1) |
| 612 | `3b e1 3c e2 e4 00` | MOVE32_F G60 →G228 |
| 658 | `3f 83 00 00 40 40 e2 d8 00` | MOVEF_F 3.0 →G216 (`lv_n_1 = 3`) |
| 667 | `ce 83 04 ff ff ff 48 c2 1c 02` | WRITE32 −252 (687−939 = −252) |
| 677 | `10 48 01 48` | ADD8 L8 1 →L8 |
| 681 | `40 83 48 00 00 00` | JR +72 (759−687) |
| 687 | (CALLSUB11) … | `gv_d2 = lv_data_1`, LCD.Text, `lv_n_1 = 3`→G216 … |
| 734 | `3e 83 00 00 c8 42 c2 18 05` | MOVEF_32 100.0 →L1304 (milliseconds14; 100.0 = 0x42C80000) |
| 743 | `85 c2 18 05 c2 1c 05` | TIMER_WAIT L1304 L1308 (timer14) |
| 750 | `86 c2 1c 05` | TIMER_READY L1308 |
| 754 | `40 82 df fe` | JR −289, компактная 3-байтовая форма метки (whilebody0 = program 129 = файл 469; 469−758 = −289) |
| 758 | `08` | RETURN (ENDTHREAD) |
| 759 | (метка SUB_F_MAP_DATA_2) | |
| 759 | `73 e2 d8 00 83 00 00 00 40 83 46 00 00 00` | JR_NEQF G216 2.0 →+70 (else15_1 = 843; 843−773=70) |
| 773 | `9e 00 01 00 3f 12 01 e1 30` | INPUT_READEXT 0 1 0 −1 18 1 →G48 |
| 782 | `3b e1 30 58` | MOVE32_F G48 →L24 (F.3 — короткая форма) |
| 786 | `17 58 e2 e8 00 54` | SUBF L24 G232 →L20 (F.2) |
| 792 | `17 e2 ec 00 e2 e8 00 58` | SUBF G236 G232 →L24 |
| 800 | `1f 54 58 c2 20 05` | DIVF L20 L24 →L1312 (tmpf19) |
| 806 | `4f 83 00 00 00 00 58 c2 24 05` | CP_EQF 0.0 L24 →L1316 (flag19; 0.0 — форма 0x83) |
| 816 | `5f c2 24 05 83 00 00 00 00 c2 20 05 50` | SELECTF L1316 0.0 L1312 →L16 (F.1) |
| 830 | `1b 50 83 00 00 c8 42 4c` | MULF L16 100.0 →L12 (F.0) |
| 837 | `8d 03 4c e2 dc 00` | MATH FLOOR L12 →G220 (LV_DATA_1) |
| 843 | `73 e2 d8 00 83 00 00 40 40 83 3e 00 00 00` | JR_NEQF G216 3.0 →+62 (else22_1 = 919; 919−857=62) |
| 919..926 | | else22_1:/endif22: (подряд, 0 байт кода) |
| 927 | `14 48 01 48` | (RETSUB) SUB8 L8 1 →L8 |
| 931 | `ca c2 1c 02 48 44` | READ32 →L540 →L8 →L4 (INDEX) |
| 937 | `40 44` | JR_DYNAMIC INDEX (опкод 0x40 + переменная, не метка!) |
| 939 | `08` | RETURN (дописан ассемблером) |
| 940 | `0a` | OBJECT_END; locals obj2 = 1325 ✓ |
| 941 | `00` | obj3: numpar=0 |
| 942 | `84 12 00` | UI_DRAW TOPLINE 0 |
| 945 | `84 01` | UI_DRAW CLEAN |
| 947 | `72 00 64 83 02 00 00 00` | JR_NEQ32 0 G4 →+2 (skipupdate: program 15; 15−13=2) |
| 955 | `84 00` | (skipupdate) UI_DRAW UPDATE |
| 957 | `08 0a` | RETURN, OBJECT_END |
| 959 | `05 83 83 83 83 84 fc` | obj4: numpar=5: IN_F×4, IN_S 252 |
| 966 | `3c 40 c2 0c 01` | MOVEF_8 L0 →L268 (col_8) |
| 971 | `3d 44 c2 0e 01` | MOVEF_16 L4 →L270 (x_16) |
| 976 | `3d 48 c2 10 01` | MOVEF_16 L8 →L272 (y_16) |
| 981 | `3c 4c c2 12 01` | MOVEF_8 L12 →L274 (font_8) |
| 986 | `84 11 c2 12 01` | UI_DRAW SELECT_FONT →L274 |
| 990 | `84 05 c2 0c 01 c2 0e 01 c2 10 01 50` | UI_DRAW TEXT L268 L270 L272 L16 (text — короткая форма 0x50!) |
| 1002 | `72 00 64 83 02 00 00 00` | JR_NEQ32 0 G4 →+2 |
| 1010 | `84 00` | UI_DRAW UPDATE |
| 1012 | `08 0a` | RETURN, OBJECT_END → 1015 ✓ |

Раскладка локали obj2 (1325 Б): SUBPROGRAM@0, INDEX@4, STACKPOINTER@8(4), F.0@12, F.1@16,
F.2@20, F.3@24, RETURNSTACK2@28(512), RETURNSTACK@540(512), S.0@1052(252),
milliseconds14@1304, timer14@1308, tmpf19@1312, flag19@1316, tmpf26@1320, flag26@1324 → 1325.
Локаль obj4 (275 Б): col@0, x@4, y@8, font@12, text@16(252), col_8@268, x_16@270 (паддинг на
269), y_16@272, font_8@274 → 275. Обе подтверждены байтами.

---

## 4. Алгоритм `.lmsb` → `.rbf` (Assembler.cs)

Фаза 1 — разбор (Assembler.cs:70-517, построчно):
1. Токенизация строки (§2.7): uppercase всего, кроме строк; `//`-комментарии; `}` закрывает объект.
2. Вне объекта: `VMTHREAD <имя>` / `SUBCALL <имя>` создают объект (или переиспользуют
   forward-созданный) с ID = objects.Count+1 и открывают тело; директивы данных пополняют
   ГЛОБАЛЬНУЮ область; неизвестное — ошибка (Assembler.cs:122-196).
3. Внутри объекта: `SUBCALL <имя>` — алиас на текущий subcall (та же реализация, свой ID);
   директивы данных — в ЛОКАЛЬНУЮ область; `IN_/OUT_/IO_*` — параметр + запоминание в списки
   ioDataTypes/ioAccessTypes/ioStringSizes; метки — в словарь позиций; `CALL` — opcode 0x09 +
   ID + numpar + параметры (недостающий subcall создаётся сразу с очередным ID); обычные
   инструкции — опкод по имени (1- или 2-словному) + параметры по типам из таблицы, где `L`
   → ссылка на метку, `T`/`S` → константа-ID объекта, `P` → константа + расширение списка,
   остальное → DecodeAndAddParameter (Assembler.cs:390-515).
4. Ссылки на метки: если метка уже определена — сразу компактная форма (§3.4); иначе заглушка
   `0x83 00 00 00 00` и запись в `references[pos+1]` (LMSObject.cs:150-197).

Фаза 2 — вычисление смещений (Assembler.cs:593-631):
1. Объекты сортируются по ID (`oarray[o.id−1]`).
2. `totalheadersize = 16 + 12N`.
3. Тела пишутся в буфер по порядку ID; перед записью каждого объекта ему сообщается
   `offsetToInstructions = totalheadersize + <текущая длина буфера>` (Assembler.cs:608-611).
4. Во время записи тела сканируется буфер программы: по достижении позиции из `references`
   вместо 4 Б заглушки пишется патч (LMSObject.cs:214-262):
   - метка: `Write32(pos(метки) − (i+4))`, i = позиция первого байта заглушки;
   - разность `A:B`: `Write32(pos(B) − pos(A))`.
   Позиции меток — смещения ВНУТРИ тела (без IO-дескрипторов и без учёта абсолютного
   смещения файла).
5. Незакрытая метка/разность/неопределённый subcall — ошибка ("Unresolved jump target",
   "Unresolved subcall").

Фаза 3 — вывод: заголовок файла (§3.1), затем 12-байтные заголовки объектов (offset тела,
owner=0, trigger 0/1, localBytes), затем буфер тел (Assembler.cs:613-631).

Forward-ссылки и выравнивание: величина патча зависит ТОЛЬКО от позиций внутри тела; так как
forward-ссылка всегда резервирует 5 байт (`0x83`+4), смещения последующего кода известны уже
при первом проходе — двухфазного пересчёта размеров не требуется. Выравнивание влияет на
`localBytes`/позиции переменных (и, значит, на кодирование операндов), поэтому порядок
директив DATA обязан воспроизводиться точно.

---

## 5. Инварианты для дифференциального теста (побайтовое совпадение .rbf)

Детерминировано и обязано совпадать байт-в-байт при одинаковом входе:
1. `.rbf` полностью выводится из текста `~Name.bp` + встроенных ресурсов (`bytecodelist.txt`,
   `c_*.txt`) — никаких путей, времени, случайности в формате нет (проверено по коду
   Assembler.cs:593-631 и Compiler.cs:170-466).
2. Порядок вставки словарей .NET: `variables`, `functiondefinitions`, `threadnames`,
   `references` (HashSet), `_propertys` — все обходятся в порядке вставки (в .NET Dictionary/
   HashSet без удалений сохраняют порядок вставки на практике). В Mojo это должен быть
   упорядоченный (insertion-ordered) словарь/множество. (гипотеза о гарантиях .NET, но
   эмпирически подтверждено на Program1: порядок DATAF V* и порядок subcall LCD.CLEAR,
   LCD.TEXT = порядок первых упоминаний)
3. ID объектов и их порядок в файле — по первому упоминанию имён в `.lmsb` (§3.2).
4. Кодирование операндов — строго по §3.4; float — округление double→single (IEEE-754,
   round-to-nearest-even), little-endian.
5. Форматирование чисел в `.lmsb`: `double.ToString(InvariantCulture)` + `".0"` если нет
   точки (Compiler/Expression.cs:111-122). Значения из тестов (целые, короткие дробные)
   форматируются одинаково в .NET и при обычной реализации; пограничные случаи — см. §6.
6. Экранирование строк: `\ooo` (3 восьмеричных цифры, Compiler.cs:1701-1723); обратное
   разворачивание — только `\n`, `\t`, `\0xx`–`\3xx` (Assembler.cs:753-782); символ вне 0..255
   в `.bp`-строке → `char(1)` → `\001` (Compiler.cs:1706-1710).
7. `~Name.bp` и `.lmsb` — текстовые артефакты: сравнивать их надо с нормализацией окончаний
   строк (Windows пишет CRLF через WriteAllLines/WriteLine; данные здесь — LF), содержимое
   строк при этом совпадает. На `.rbf` окончания строк не влияют (Scanner и Assembler читают
   по ReadLine — Scanner.cs:53-59, Assembler.cs:77-79).
8. `Data.Project.Path`, имена проектов и папок попадают в `.bp` только через MediaBuilder
   (LCD.BMPFILE / Speaker.Play / EV3File.Open* / TableLookup — подстановка путей
   `PRJS|SD_Card`, MediaBuilder.cs:201-344): для программ без медиа окружение не влияет;
   с медиа — путь зашивается в строковые литералы (влияние окружения, для тестов фиксировать
   `Folder`/`ProjectName`).

Что НЕ проверять на байты: диагностические сообщения, лог консоли (Builder.cs:81-139),
номера строк ошибок.

Рекомендуемый тест: для каждого из 44 примеров corpus: `.bp` → (порт) → `.lmsb`/`.rbf`,
сравнение с сохранёнными оракулами (`~Test1`, `~Battery`, `~ButtonsAndMotors`, `~Program1`);
плюс сверка glob: имена `~<имя>/<имя>.lmsb|rbf` (Builder.cs:79,379,425).

---

## 6. Открытые вопросы

1. Форматирование `double.ToString(InvariantCulture)`: .NET Framework/Standard 2.0 (G15) vs
   .NET Core 3.0+ (shortest round-trip) могут дать разные строки для «некруглых» дробей;
   какие значения встречаются в корпусе — проверить на всех 44 примерах (риск для
   `.lmsb`-сравнения, на `.rbf` не влияет: байты float однозначны).
2. Экспоненциальная форма `1E-20`: PreparedValue даст `1E-20.0`, а Assembler это не разберёт
   (Assembler.cs:568-578) — поведение на таких константах не определено (гипотеза: ошибка).
3. Поведение при `numobjects > 65535`, `globals > 2^32`, локали > 2^31 — не проверялось;
   практически недостижимо.
4. `JR_DYNAMIC INDEX`: семантика относительного прыжка на EV3 VM — влияет только на рантайм,
   не на байты; для эмулятора нужен отдельный документ (вне зоны этого раздела).
5. Алиасы SUBCALL внутри тела и директива `SUBCALL` вне `{}` — недостижимы из генератора
   компилятора; поддержать в Mojo-ассемблере для совместимости с ручными `.lms` (гипотеза).
6. Максимальные размеры: строки ≤ 251 символов в `.bp` (Compiler.cs:1460-1463), K директив
   1..32767, IO-строки ≤ 255 — проверить соответствие диагностики (зона другого агента).
7. Пустые строки внутри `~Name.bp`: сохраняются ли они из исходника (зависит от
   препроцессора) — на `.lmsb`/`.rbf` не влияют; уточнить у раздела препроцессора.
8. Не найден исходник `Program1.bp` в корпусе (в `tests/corpus/New_Path_Examples/Program1.bp`
   — другая программа); реконструкция вызова `map_data(2, d1)` сделана по `~Program1.bp`
   (проверено согласованностью §1.3, помечено как восстановление).
