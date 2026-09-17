"""Стадия 4: ассемблер — текстовый листинг `.lmsb` -> бинарный байткод `.rbf`.

Порт C#-оракула (Clev3r-1/Interpreter):
  Assembler/Assembler.cs (1091 строк) — разбор листинга, кодирование операндов, вывод;
  Assembler/LMSObject.cs (459) — объект VM (поток/subcall), back-patching меток;
  Assembler/DataArea.cs — раскладка глобальных/локальных данных с выравниванием;
  Assembler/DataWriter.cs — Write16/Write32 little-endian;
  Assembler/VMCommand.cs + DataType.cs — таблица опкодов и типы операндов;
  Resources/bytecodelist.txt — встроена целиком (BYTECODE_LIST).

Формат .rbf — docs/04 §3 (побайтово сверено с Program1.rbf, 1015 Б):
  заголовок 16 Б: 'LEGO' | размер файла (u32) | версия 0x0068 (u16) | число объектов (u16)
  | байты глобальных данных (u32); оглавление N заголовков по 12 Б (offset тела u32,
  owner=0 u16, trigger 0/1 u16, localBytes u32); тела объектов по возрастанию ID.

Воспроизводимые квирки (docs/04 §3.4, §2.6):
  * back-patching меток: кодирование переменной длины, отсчёт от КОНЦА инструкции
    (LMSObject.cs:150-180); forward-ссылка — всегда заглушка 0x83+4;
  * разность меток A:B — всегда 0x83+4, значение pos(B)-pos(A) без поправок;
  * второй байт двухбайтовых мнемоник кодируется как КОНСТАНТА, поэтому
    UI_DRAW TEXTBOX даёт 84 81 20 (0x20=32 не влезает в короткую форму);
  * параметры IN_/OUT_/IO_ не получают padding и обязаны идти до DATA (DataArea.cs:57-84);
  * FLOAT и I32 кодируются одинаково (0x83 + 4 байта), различие только в дескрипторах.
"""

from std.collections import Dict

from bp.lexer import _byte_at, _bytes_to_string, _sub_bytes
from bp.util import read_lines, dir_name, base_name, strip_ext


# ============================================================================
# Таблица опкодов — Resources/bytecodelist.txt, встроена как есть (470 строк).
# ============================================================================

comptime BYTECODE_LIST = """
00 ERROR
01 NOP
02 PROGRAM_STOP        16
03 PROGRAM_START       16 32 32 8
04 OBJECT_STOP         T
05 OBJECT_START        T
06 OBJECT_TRIG         T
07 OBJECT_WAIT         T
08 RETURN
// 09 CALL            
0A OBJECT_END          
0B SLEEP

0C00 PROGRAM_INFO OBJ_STOP       16 16
0C04 PROGRAM_INFO OBJ_START      16 16
0C16 PROGRAM_INFO GET_STATUS     16 8*
0C17 PROGRAM_INFO GET_SPEED      16 32*
0C18 PROGRAM_INFO GET_PRGRESULT  16 8*
// 0C19 PROGRAM_INFO SET_INSTR      

0D LABEL        8
0E PROBE        16 16 32 32
0F DO           16 32 32
10 ADD8         8 8 8*
11 ADD16        16 16 16*
12 ADD32        32 32 32*
13 ADDF         F F F*
14 SUB8         8 8 8*
15 SUB16        16 16 16*
16 SUB32        32 32 32*
17 SUBF         F F F*
18 MUL8         8 8 8*
19 MUL16        16 16 16*
1A MUL32        32 32 32*
1B MULF         F F F*
1C DIV8         8 8 8*
1D DIV16        16 16 16*
1E DIV32        32 32 32*
1F DIVF         F F F*
20 OR8          8 8 8*
21 OR16         16 16 16*
22 OR32         32 32 32*
24 AND8         8 8 8*
25 AND16        16 16 16*
26 AND32        32 32 32*
26 AND8888_32   8+ 32 8*          // special form needed in basic compiler
28 XOR8         8 8 8*
29 XOR16        16 16 16*
2A XOR32        32 32 32*
2C RL8          8 8 8*
2D RL16         16 16 16*
2E RL32         32 32 32*
2F INIT_BYTES   8* P 8         // with number of parameters specified by P
30 MOVE8_8      8 8*        
30 EXTRACTLOWBYTE 32 8*        // special form to allow -128 as byte value
30 INJECTLOWBYTE 8* 32         // special form to translate unsigned byte to integer
31 MOVE8_16     8 16*
32 MOVE8_32     8 32*
33 MOVE8_F      8 F*
34 MOVE16_8     16 8*
35 MOVE16_16    16 16*
36 MOVE16_32    16 32*
37 MOVE16_F     16 F*
38 MOVE32_8     32 8*
39 MOVE32_16    32 16*
3A MOVE32_32    32 32*
3B MOVE32_F     32 F*
3C MOVEF_8      F 8*
3D MOVEF_16     F 16*
3E MOVEF_32     F 32*
3F MOVEF_F      F F*
40 JR           L
40 JR_DYNAMIC   32      // special form needed for basic compiler
41 JR_FALSE     8 L
42 JR_TRUE      8 L
43 JR_NAN       F L
44 CP_LT8       8 8 8*
45 CP_LT16      16 16 8*
46 CP_LT32      16 16 8*
47 CP_LTF       F F 8*
48 CP_GT8       8 8 8*
49 CP_GT16      16 16 8*
4A CP_GT32      32 32 8*
4B CP_GTF       F F 8*
4C CP_EQ8       8 8 8*
4D CP_EQ16      16 16 8*
4E CP_EQ32      32 32 8*
4F CP_EQF       F F 8*
50 CP_NEQ8      8 8 8*
51 CP_NEQ16     16 16 8*
52 CP_NEQ32     32 32 8*
53 CP_NEQF      F F 8*
54 CP_LTEQ8     8 8 8*
55 CP_LTEQ16    16 16 8*
56 CP_LTEQ32    32 32 8*
57 CP_LTEQF     F F 8*
58 CP_GTEQ8     8 8 8*
59 CP_GTEQ16    16 16 8*
5A CP_GTEQ32    32 32 8*
5B CP_GTEQF     F F 8*
5C SELECT8      8 8 8 8*
5D SELECT16     8 16 16 16*
5E SELECT32     8 32 32 32*
5F SELECTF      8 F F F*
60 SYSTEM       8+ 8*
61 PORT_CNV_OUTPUT      32 8* 8* 8* 
62 PORT_CNV_INPUT       32 8* 8*
63 NOTE_TO_FREQ         8 16*
64 JR_LT8        8 8 L    
65 JR_LT16       16 16 L 
66 JR_LT32       32 32 L
67 JR_LTF        F F L
68 JR_GT8        8 8 L
69 JR_GT16       16 16 L
6A JR_GT32       32 32 L
6B JR_GTF        F F L
6C JR_EQ8        8 8 L
6D JR_EQ16       16 16 L
6E JR_EQ32       32 32 L
6F JR_EQF        F F L
70 JR_NEQ8       8 8 L
71 JR_NEQ16      16 16 L
72 JR_NEQ32      32 32 L
73 JR_NEQF       F F L
74 JR_LTEQ8      8 8 L
75 JR_LTEQ16     16 16 L
76 JR_LTEQ32     32 32 L
77 JR_LTEQF      F F L
78 JR_GTEQ8      8 8 L
79 JR_GTEQ16     16 16 L
7A JR_GTEQ32     32 32 L
7B JR_GTEQF      F F L

7C01 INFO SET_ERROR         8
7C02 INFO GET_ERROR         8*
7C03 INFO ERRORTEXT         8 8 8*
7C04 INFO GET_VOLUME        8*
7C05 INFO SET_VOLUME        8
7C06 INFO GET_MINUTES       8*
7C07 INFO SET_MINUTES       8
  
7D01 STRINGS GET_SIZE               8+ 16*
7D02 STRINGS ADD                    8+ 8+ 8*
7D03 STRINGS COMPARE                8+ 8+ 8*
7D05 STRINGS DUPLICATE              8+ 8*
7D06 STRINGS VALUE_TO_STRING        F 8 8 8*
7D07 STRINGS STRING_TO_VALUE        8+ F*
7D08 STRINGS STRIP                  8+ 8*
7D09 STRINGS NUMBER_TO_STRING       16 8 8*
7D0A STRINGS SUB                    8+ 8+ 8*
7D0B STRINGS VALUE_FORMATTED        F 8+ 8 8*
7D0C STRINGS NUMBER_FORMATTED       32 8+ 8 8*

7E MEMORY_WRITE                     16 S 32 32 8+
7F MEMORY_READ                      16 S 32 32 8*
80 UI_FLUSH                         

8101 UI_READ GET_VBATT             F* 
8102 UI_READ GET_IBATT             F*
8103 UI_READ GET_OS_VERS           8 8*
8104 UI_READ GET_EVENT             8*
8105 UI_READ GET_TBATT             F*
8106 UI_READ GET_IINT              F*
8107 UI_READ GET_IMOTOR            F*
8108 UI_READ GET_STRING            8 8*
8109 UI_READ GET_HW_VERS           8 8*
810A UI_READ GET_FW_VERS           8 8*
810B UI_READ GET_FW_BUILD          8 8*
810C UI_READ GET_OS_BUILD          8 8*
810D UI_READ GET_ADDRESS           32*
810E UI_READ GET_CODE              32 32* 32* 8*
810F UI_READ KEY                   8*
8110 UI_READ GET_SHUTDOWN          8*
8111 UI_READ GET_WARNING           8*
8112 UI_READ GET_LBATT             8*
8115 UI_READ TEXTBOX_READ          8+ 32 8 8 16 8*
811A UI_READ GET_VERSION           8 8*
811B UI_READ GET_IP                8 8*
811D UI_READ GET_POWER             F* F* F* F*
811E UI_READ GET_SDCARD            8* 32* 32*
811F UI_READ GET_USBSTICK          8* 32* 32*

8201 UI_WRITE WRITE_FLUSH          
8202 UI_WRITE FLOATVALUE           F 8 8
8203 UI_WRITE STAMP                8+
8208 UI_WRITE PUT_STRING           8+
8209 UI_WRITE VALUE8               8
820A UI_WRITE VALUE16              16
820B UI_WRITE VALUE32              32
820C UI_WRITE VALUEF               F
// 820D UI_WRITE ADDRESS              
// 820E UI_WRITE CODE      
820F UI_WRITE DOWNLOAD_END 
8210 UI_WRITE SCREEN_BLOCK         8
8215 UI_WRITE TEXTBOX_APPEND       8 32 8 8+
8216 UI_WRITE SET_BUSY             8
8218 UI_WRITE SET_TESTPIN          8
8219 UI_WRITE INIT_RUN 
821A UI_WRITE UPDATE_RUN           
821B UI_WRITE LED                  8
821D UI_WRITE POWER                8
821E UI_WRITE GRAPH_SAMPLE         
821F UI_WRITE TERMINAL             8

8301 UI_BUTTON SHORTPRESS          8 8*
8302 UI_BUTTON LONGPRESS           8 8*
8303 UI_BUTTON WAIT_FOR_PRESS
8304 UI_BUTTON FLUSH            
8305 UI_BUTTON PRESS               8
8306 UI_BUTTON RELEASE             8
8307 UI_BUTTON GET_HORZ            16*
8308 UI_BUTTON GET_VERT            16*
8309 UI_BUTTON PRESSED             8 8*
830A UI_BUTTON SET_BACK_BLOCK      8
830B UI_BUTTON GET_BACK_BLOCK      8*
830C UI_BUTTON TESTSHORTPRESS      8 8*
830D UI_BUTTON TESTLONGPRESS       8 8*
830E UI_BUTTON GET_BUMBED          8 8*
830F UI_BUTTON GET_CLICK           8*

8400 UI_DRAW UPDATE                
8401 UI_DRAW CLEAN        
8402 UI_DRAW PIXEL            8 16 16
8403 UI_DRAW LINE             8 16 16 16 16
8404 UI_DRAW CIRCLE           8 16 16 16
8405 UI_DRAW TEXT             8 16 16 8+
8406 UI_DRAW ICON             8 16 16 8 8
8407 UI_DRAW PICTURE          8 16 16 32
8408 UI_DRAW VALUE            8 16 16 F 8 8
8409 UI_DRAW FILLRECT         8 16 16 16 16
840A UI_DRAW RECT             8 16 16 16 16
840B UI_DRAW NOTIFICATION     8 16 16 8 8 8 8+ 8
840C UI_DRAW QUESTION         8 16 16 8 8 8+ 8 8*
840D UI_DRAW KEYBOARD         8 16 16 8 8+ 8 8*
840E UI_DRAW BROWSE           8 16 16 16 16 8 8* 8*
840F UI_DRAW VERTBAR          8 16 16 16 16 16 16 16
8410 UI_DRAW INVERSERECT      16 16 16 16
8411 UI_DRAW SELECT_FONT      8
8412 UI_DRAW TOPLINE          8
8413 UI_DRAW FILLWINDOW       8 16 16
// 8414 UI_DRAW SCROLL       
8415 UI_DRAW DOTLINE          8 16 16 16 16 16 16
8416 UI_DRAW VIEW_VALUE       8 16 16 F 8 8 
8417 UI_DRAW VIEW_UNIT        8 16 16 F 8 8 8 8+
8418 UI_DRAW FILLCIRCLE       8 16 16 16
8419 UI_DRAW STORE            8
841A UI_DRAW RESTORE          8
841B UI_DRAW ICON_QUESTION    8 16 16 8 32
841C UI_DRAW BMPFILE          8 16 16 8+
// 841D UI_DRAW POPUP          
// 841E UI_DRAW GRAPH_SETUP      16 16 8 32 32 32 32 32
841F UI_DRAW GRAPH_DRAW       8
8420 UI_DRAW TEXTBOX          16 16 16 16 8+ 32 8 16*

85 TIMER_WAIT           32 32*
86 TIMER_READY          32
87 TIMER_READ           32*
88 BP0
89 BP1
8A BP2
8B BP3
8C BP_SET               16 8 32

8D01 MATH EXP           F F*
8D02 MATH MOD           F F F*
8D03 MATH FLOOR         F F*
8D04 MATH CEIL          F F*
8D05 MATH ROUND         F F*
8D06 MATH ABS           F F*
8D07 MATH NEGATE        F F*
8D08 MATH SQRT          F F*
8D09 MATH LOG           F F*
8D0A MATH LN            F F*
8D0B MATH SIN           F F*
8D0C MATH COS           F F*
8D0D MATH TAN           F F*
8D0E MATH ASIN          F F*
8D0F MATH ACOS          F F*
8D10 MATH ATAN          F F*
8D11 MATH MOD8          8 8 8*
8D12 MATH MOD16         16 16 16*
8D13 MATH MOD32         32 32 32*
8D14 MATH POW           F F F*
8D15 MATH TRUNC         F 8 F*

8E RANDOM               16 16 16*
8F TIMER_READ_US        32*
90 KEEP_ALIVE           8

910E COM_READ COMMAND   32 32* 32* 8*
920E COM_WRITE REPLY    32* 32*
9400 SOUND BREAK        
9401 SOUND TONE         8 16 16  
9402 SOUND PLAY         8 8+
9403 SOUND REPEAT       8 8+
// 9404 SOUND SERVICE      

95 SOUND_TEST           8*
96 SOUND_READY          
// 97 INPUT_SAMPLE
98 INPUT_DEVICE_LIST    8 8* 8* 

9902 INPUT_DEVICE GET_FORMAT         8 8 8* 8* 8* 8*
9903 INPUT_DEVICE CAL_MINMAX         8 8 32 32
9904 INPUT_DEVICE CAL_DEFAULT        8 8
9905 INPUT_DEVICE GET_TYPEMODE       8 8 8* 8*
9906 INPUT_DEVICE GET_SYMBOL         8 8 8 8*
9907 INPUT_DEVICE CAL_MIN            8 8 32
9908 INPUT_DEVICE CAL_MAX            8 8 32
9909 INPUT_DEVICE SETUP              8 8 8 16 8 8* 8 8*
990A INPUT_DEVICE CLR_ALL            8
990B INPUT_DEVICE GET_RAW            8 8 32*
990C INPUT_DEVICE GET_CONNECTION     8 8 8*
990D INPUT_DEVICE STOP_ALL           8
9915 INPUT_DEVICE GET_NAME           8 8 8 8*
9916 INPUT_DEVICE GET_MODENAME       8 8 8 8 8*
9917 INPUT_DEVICE SET_RAW            8 32
9918 INPUT_DEVICE GET_FIGURES        8 8 8* 8*
9919 INPUT_DEVICE GET_CHANGES        8 8 F*
991A INPUT_DEVICE CLR_CHANGES        8 8 
991B INPUT_DEVICE READY_PCT          8 8 8 8 P 8*    // number of parameters specified by P
991C INPUT_DEVICE READY_RAW          8 8 8 8 P 32*   // number of parameters specified by P
991D INPUT_DEVICE READY_SI           8 8 8 8 P F*    // number of parameters specified by P
991E INPUT_DEVICE GET_MINMAX         8 8 F* F*
991F INPUT_DEVICE GET_BUMPS          8 8 F*
   
9A INPUT_READ              8 8 8 8 8*
9B INPUT_TEST              8 8 8*
9C INPUT_READY             8 8 
9D INPUT_READSI            8 8 8 8 F*
9E INPUT_READEXT           8 8 8 8 8 P ?*     // number of parameters specified by P
9F INPUT_WRITE             8 8 8 8*
// A0 OUTPUT_GET_TYPE         
A1 OUTPUT_SET_TYPE         8 8 8
A2 OUTPUT_RESET            8 8
A3 OUTPUT_STOP             8 8 8 
A4 OUTPUT_POWER            8 8 8 
A5 OUTPUT_SPEED            8 8 8
A6 OUTPUT_START            8 8
A7 OUTPUT_POLARITY         8 8 8
A8 OUTPUT_READ             8 8 8* 32*
A9 OUTPUT_TEST             8 8 8*
AA OUTPUT_READY            8 8
// AB OUTPUT_POSITION
AC OUTPUT_STEP_POWER       8 8 8 32 32 32 8
AD OUTPUT_TIME_POWER       8 8 8 32 32 32 8
AE OUTPUT_STEP_SPEED       8 8 8 32 32 32 8
AF OUTPUT_TIME_SPEED       8 8 8 32 32 32 8
B0 OUTPUT_STEP_SYNC        8 8 8 16 32 8
B1 OUTPUT_TIME_SYNC        8 8 8 16 32 8
B2 OUTPUT_CLR_COUNT        8 8 
B3 OUTPUT_GET_COUNT        8 8 32*
B4 OUTPUT_PRG_STOP        

C000 FILE OPEN_APPEND         8+ 16*   
C001 FILE OPEN_READ           8+ 16* 32*
C002 FILE OPEN_WRITE          8+ 16*
C003 FILE READ_VALUE          16 8 F*
C004 FILE WRITE_VALUE         16 8 F 8 8
C005 FILE READ_TEXT           16 8 16 8*
C006 FILE WRITE_TEXT          16 8 8+
C007 FILE CLOSE               16
C008 FILE LOAD_IMAGE          16 8+ 32* 32*
C009 FILE GET_HANDLE          8+ 16* 8*
C00A FILE MAKE_FOLDER         8+ 8*
C00B FILE GET_POOL            32 16* 32*
C00C FILE SET_LOG_SYNC_TIME   32 32
C00D FILE GET_FOLDERS         8+ 8*
C00E FILE GET_LOG_SYNC_TIME   32* 32*
C00F FILE GET_SUBFOLDER_NAME  8+ 8 8 8*
C010 FILE WRITE_LOG           16 32 8 F*
C011 FILE CLOSE_LOG           16 8+
C012 FILE GET_IMAGE           8+ 16 8 32*
C013 FILE GET_ITEM            8+ 8+ 8*
C014 FILE GET_CACHE_FILES     8*
C015 FILE PUT_CACHE_FILE      8+
C016 FILE GET_CACHE_FILE      8 8 8*
C017 FILE DEL_CACHE_FILE      8 8 8*
C018 FILE DEL_SUBFOLDER       8+ 8+
C019 FILE GET_LOG_NAME        8 8*
C01B FILE OPEN_LOG            8+ 32 32 32 32 32 8 16*
C01C FILE READ_BYTES          16 16 8*
C01D FILE WRITE_BYTES         16 16 8*
C01E FILE REMOVE              16
C01F FILE MOVE                8+ 8+

C100 ARRAY DELETE             16
C101 ARRAY CREATE8            32 16*
C102 ARRAY CREATE16           32 16*
C103 ARRAY CREATE32           32 16*
C104 ARRAY CREATEF            32 16*
C105 ARRAY RESIZE             16 32
C106 ARRAY FILL               16 ?
C107 ARRAY COPY               16 16
C108 ARRAY INIT8              16 32 P 8
C109 ARRAY INIT16             16 32 P 16
C10A ARRAY INIT32             16 32 P 32
C10B ARRAY INITF              16 32 P F
C10C ARRAY SIZE               16 32*
C10D ARRAY READ_CONTENT       16 16 32 32 8*
C10E ARRAY WRITE_CONTENT      16 16 32 32 8*
C10F ARRAY READ_SIZE          16 16 32*

C2 ARRAY_WRITE                16 32 ?
C3 ARRAY_READ                 16 32 ?*
C4 ARRAY_APPEND               16 ?+
C5 MEMORY_USAGE               32* 32*

C610 FILENAME EXIST           8+ 8*
C611 FILENAME TOTALSIZE       8+ 32* 32*
C612 FILENAME SPLIT           8+ 8 8+ 8* 8*
C613 FILENAME MERGE           8+ 8+ 8+ 8 8*
C614 FILENAME CHECK           8+ 8*
C615 FILENAME PACK            8+
C616 FILENAME UNPACK          8+
C617 FILENAME GET_FOLDERNAME  8 8*

C8 READ8               8* 8 8*
C9 READ16              16* 8 16*
CA READ32              32* 8 32*
CB READF               F* 8 F*
CC WRITE8              8 8 8*
CD WRITE16             16 8 16*
CE WRITE32             32 8 32*
CF WRITEF              F 8 F*
D0 COM_READY           8 8*
// D1 COM_READDATA        
// D2 COM_WRITEDATA

D301 COM_GET GET_ON_OFF     8 8*
D302 COM_GET GET_VISIBLE    8 8*
D304 COM_GET GET_RESULT     8 8 8*
D305 COM_GET GET_PIN        8 8 8 8*
D306 COM_GET SEARCH_ITEMS   8 8*
D309 COM_GET SEARCH_ITEM    8 8 8 8* 8* 8* 8* 8*
D30A COM_GET FAVOUR_ITEMS   8 8*
D30B COM_GET FAVOUR_ITEM    8 8 8 8* 8* 8* 8*
D30C COM_GET GET_ID         8 8 8*
D30D COM_GET GET_BRICKNAME  8 8*
D30E COM_GET GET_NETWORK    8 8 8* 8* 8*
D30F COM_GET GET_PRESENT    8 8*
D310 COM_GET GET_ENCRYPT    8 8 8*
D311 COM_GET CONNEC_ITEMS   8 8*
D312 COM_GET CONNEC_ITEM    8 8 8 8*
D313 COM_GET GET_INCOMING   8 8 8*
D314 COM_GET GET_MODE2      8 8*

D401 COM_SET SET_ON_OFF      8 8 
D402 COM_SET SET_VISIBLE     8 8
D403 COM_SET SET_SEARCH      8 8 
D405 COM_SET SET_PIN         8 8 8
D406 COM_SET SET_PASSKEY     8 8
D407 COM_SET SET_CONNECTION  8 8+ 8
D408 COM_SET SET_BRICKNAME   8+
D409 COM_SET SET_MOVEUP      8 8
D40A COM_SET SET_MOVEDOWN    8 8
D40B COM_SET SET_ENCRYPT     8 8 8
D40C COM_SET SET_SSID        8 8+
D40D COM_SET SET_MODE2       8 8

D5 COM_TEST                  8 8+ 8*
D6 COM_REMOVE                8 8+
D7 COM_WRITEFILE             8 8+ 8+ 8
D8 MAILBOX_OPEN              8 8+ 8 8 8
D9 MAILBOX_WRITE             8+ 8 8+ 8 8 ?+
DA MAILBOX_READ              8 16 8 ?*
DB MAILBOX_TEST              8 8*
DC MAILBOX_READY             8
DD MAILBOX_CLOSE             8
// FF TST
"""


# ============================================================================
# DataType / AccessType (Assembler/DataType.cs:22-42)
# ============================================================================

comptime DT_I8 = 0
comptime DT_I16 = 1
comptime DT_I32 = 2
comptime DT_F = 3
comptime DT_UNSPECIFIED = 4
comptime DT_LABEL = 5
comptime DT_VTHREAD = 6
comptime DT_VSUBCALL = 7
comptime DT_PCOUNT = 8

comptime AT_READ = 0
comptime AT_READMANY = 1
comptime AT_WRITE = 2
comptime AT_READWRITE = 3


# ============================================================================
# Побайтовые хелперы (собственные + из lexer.mojo)
# ============================================================================

def _find_byte(s: String, b: UInt8) -> Int:
    """Индекс первого байта b в s или -1 (аналог C# string.IndexOf(char))."""
    var n = s.byte_length()
    for i in range(n):
        if _byte_at(s, i) == b:
            return i
    return -1


def _find_double_slash(s: String) -> Int:
    """Индекс первого "//" или -1 (аналог C# line.IndexOf("//"))."""
    var n = s.byte_length()
    for i in range(n - 1):
        if _byte_at(s, i) == 0x2F and _byte_at(s, i + 1) == 0x2F:
            return i
    return -1


def _starts_with_digit_or_sign(s: String) -> Bool:
    var c = _byte_at(s, 0)
    return 48 <= Int(c) <= 57 or c == 0x2D  # '0'..'9' или '-'


def _upper_ascii(s: String) -> String:
    """C# ToUpperInvariant; токены ассемблера содержат только ASCII."""
    return s.upper()


def _is_token_start(c: UInt8) -> Bool:
    """[a-zA-Z0-9_-] — начало обычного токена (Assembler.cs:669-672)."""
    var v = Int(c)
    return (97 <= v <= 122) or (65 <= v <= 90) or (48 <= v <= 57) or v == 0x5F or v == 0x2D


def _is_token_cont(c: UInt8) -> Bool:
    """Продолжение токена: += буквы/цифры/_ . : + (Assembler.cs:684-687)."""
    var v = Int(c)
    return (97 <= v <= 122) or (65 <= v <= 90) or (48 <= v <= 57) or v == 0x5F or v == 0x2E or v == 0x3A or v == 0x2B


def _unescape(s: String) raises -> String:
    """Assembler.cs:753-782: \\n, \\t, \\0xx-\\3xx (восьмеричное, старшая цифра 0..3)."""
    var out = List[UInt8]()
    var n = s.byte_length()
    var i = 0
    while i < n:
        var b = _byte_at(s, i)
        if b == 0x5C:  # backslash
            if i + 1 < n and _byte_at(s, i + 1) == 0x6E:  # 'n'
                out.append(0x0A)
                i += 2
                continue
            if i + 1 < n and _byte_at(s, i + 1) == 0x74:  # 't'
                out.append(0x09)
                i += 2
                continue
            if i + 3 < n:
                var b1 = Int(_byte_at(s, i + 1))
                if 0x30 <= b1 <= 0x33:  # '0'..'3'
                    var v = (b1 - 48) * 64 + (Int(_byte_at(s, i + 2)) - 48) * 8 + (Int(_byte_at(s, i + 3)) - 48)
                    if v < 0 or v > 255:
                        # C# получил бы char > 255 и упал в AddStringLiteral
                        raise Error("String literal contains non-ascii character")
                    out.append(UInt8(v))
                    i += 4
                    continue
        out.append(b)
        i += 1
    return _bytes_to_string(out^)


def _scan_int_digits(s: String, start: Int, limit: Int, limit_last: Int) -> Tuple[Int, Int]:
    """Читает десятичные цифры с start; возвращает (значение, позиция-после).

    limit/limit_last — граница накопления без переполнения Int64: если очередная
    цифра её превышает, чтение останавливается НА этой цифре (позиция < конца —
    вызывающий увидит незаконченный разбор и вернёт None, как Int32/64.TryParse
    при переполнении). Для положительного максимума M: limit = M // 10,
    limit_last = M % 10.
    """
    var i = start
    var v = 0
    while i < s.byte_length():
        var c = Int(_byte_at(s, i))
        if not (48 <= c <= 57):
            break
        var d = c - 48
        if v > limit or (v == limit and d > limit_last):
            return (v, i)
        v = v * 10 + d
        i += 1
    return (v, i)


def _scan_i32(s: String) -> Optional[Int]:
    """C# Int32.TryParse(s, NumberStyles.Integer): [ws][+/-]цифры[ws]; иначе None."""
    var n = s.byte_length()
    var i = 0
    while i < n and (_byte_at(s, i) == 0x20 or _byte_at(s, i) == 0x09):
        i += 1
    var neg = False
    if i < n and (_byte_at(s, i) == 0x2B or _byte_at(s, i) == 0x2D):
        neg = _byte_at(s, i) == 0x2D
        i += 1
    var digits_started = i
    var pair = _scan_int_digits(s, i, 214748364, 8)
    var v = pair[0]
    i = pair[1]
    while i < n and (_byte_at(s, i) == 0x20 or _byte_at(s, i) == 0x09):
        i += 1
    if i != n or i == digits_started:
        return None
    var val = -v if neg else v
    if val > 2147483647 or val < -2147483648:
        return None
    return val


def _scan_i64(s: String) -> Optional[Int]:
    """C# Int64.TryParse(s, NumberStyles.Integer)."""
    var n = s.byte_length()
    var i = 0
    while i < n and (_byte_at(s, i) == 0x20 or _byte_at(s, i) == 0x09):
        i += 1
    var neg = False
    if i < n and (_byte_at(s, i) == 0x2B or _byte_at(s, i) == 0x2D):
        neg = _byte_at(s, i) == 0x2D
        i += 1
    var digits_started = i
    var pair = _scan_int_digits(s, i, 922337203685477580, 7)
    var v = pair[0]
    i = pair[1]
    while i < n and (_byte_at(s, i) == 0x20 or _byte_at(s, i) == 0x09):
        i += 1
    if i != n or i == digits_started:
        return None
    var val = -v if neg else v
    if val > 9223372036854775807 or val < -9223372036854775807 - 1:
        return None
    return val


def _pow10_int(k: Int) -> Int:
    """Точная степень десяти 10^k (k >= 0, небольшие k)."""
    var v = 1
    for _ in range(k):
        v *= 10
    return v


def _digits_to_i64(ds: String, take: Int) -> Int:
    """Первые take цифр строки ds как целое (take <= 18: без переполнения Int64)."""
    var v = 0
    for i in range(take):
        v = v * 10 + (Int(_byte_at(ds, i)) - 48)
    return v


def _dec_to_f64(digits: String, exp10: Int, neg: Bool) -> Float64:
    """Значение digits * 10^exp10, корректно округлённое до double.

    Эквивалент правильно-округлённого strtod (как double.TryParse в .NET 6):
    - мантисса <= 18 значащих цифр конвертируется в Int64 точно, затем один раз
      округляется при Float64(...);
    - множитель 10^e при |e| <= 22 точно представим в double, поэтому умножение
      (для e >= 0) или деление (для e < 0) даёт ОДНО округление точного
      произведения/частного — результат совпадает с корректным округлением.
    Для сверхдлинных мантисс (первые 18 цифр + остаток в экспоненту) и
    |e| > 22 допускается второе округление — на корпуса такие значения не влияют.
    """
    var start = 0
    var m_all = digits.byte_length()
    while start < m_all and Int(_byte_at(digits, start)) == 48:
        start += 1
    var end = m_all
    var e = exp10
    while end > start and Int(_byte_at(digits, end - 1)) == 48:
        end -= 1
        e += 1
    var m = end - start
    if m == 0:
        return -0.0 if neg else 0.0

    # значащие цифры в отдельной строке (не более 18 берём в целое)
    var sig = List[UInt8]()
    for i in range(start, end):
        sig.append(_byte_at(digits, i))
    var sig_str = _bytes_to_string(sig^)

    var take = m
    if take > 18:
        take = 18
    var iv = _digits_to_i64(sig_str, take)
    var d64 = Float64(iv)  # один round до double
    e += m - take

    if e >= 0:
        while e > 22:
            d64 *= 10000000000000000000000.0
            e -= 22
        if e > 0:
            d64 *= Float64(_pow10_int(e))
    else:
        while e < -22:
            d64 /= 10000000000000000000000.0
            e += 22
        if e < 0:
            d64 /= Float64(_pow10_int(-e))
    return -d64 if neg else d64


def _scan_f64(s: String) raises -> Optional[Float64]:
    """C# double.TryParse(s, NumberStyles.Float): [ws][sign]цифры[.цифры][e[sign]цифры][ws]."""
    var n = s.byte_length()
    var i = 0
    while i < n and (_byte_at(s, i) == 0x20 or _byte_at(s, i) == 0x09):
        i += 1
    var neg = False
    if i < n and (_byte_at(s, i) == 0x2B or _byte_at(s, i) == 0x2D):
        neg = _byte_at(s, i) == 0x2D
        i += 1
    var digits = List[UInt8]()
    var int_digits = 0
    while i < n and 48 <= Int(_byte_at(s, i)) <= 57:
        digits.append(_byte_at(s, i))
        i += 1
        int_digits += 1
    var exp10 = 0
    var frac_digits = 0
    if i < n and _byte_at(s, i) == 0x2E:  # '.'
        i += 1
        while i < n and 48 <= Int(_byte_at(s, i)) <= 57:
            digits.append(_byte_at(s, i))
            i += 1
            frac_digits += 1
            exp10 -= 1
    if int_digits == 0 and frac_digits == 0:
        return None
    if i < n and (_byte_at(s, i) == 0x45 or _byte_at(s, i) == 0x65):  # 'E'/'e'
        i += 1
        var eneg = False
        if i < n and (_byte_at(s, i) == 0x2B or _byte_at(s, i) == 0x2D):
            eneg = _byte_at(s, i) == 0x2D
            i += 1
        var exp_digits = 0
        var ev = 0
        while i < n and 48 <= Int(_byte_at(s, i)) <= 57:
            ev = ev * 10 + (Int(_byte_at(s, i)) - 48)
            if ev > 100000:
                ev = 100000  # защита от переполнения; всё равно за пределами double
            i += 1
            exp_digits += 1
        if exp_digits == 0:
            return None
        exp10 += -ev if eneg else ev
    while i < n and (_byte_at(s, i) == 0x20 or _byte_at(s, i) == 0x09):
        i += 1
    if i != n:
        return None
    var ds = _bytes_to_string(digits^)
    return _dec_to_f64(ds, exp10, neg)


def _parse_hex2(s: String) raises -> Int:
    """Hex-байт из 2 символов (для таблицы опкодов)."""
    var v = 0
    for k in range(2):
        var c = Int(_byte_at(s, k))
        var d: Int
        if 48 <= c <= 57:
            d = c - 48
        elif 65 <= c <= 70:
            d = c - 55
        elif 97 <= c <= 102:
            d = c - 87
        else:
            raise Error("Can not decode definition list")
        v = v * 16 + d
    return v


def write16(mut stream: List[UInt8], value: Int):
    """DataWriter.Write16: little-endian."""
    stream.append(UInt8(value & 0xFF))
    stream.append(UInt8((value >> 8) & 0xFF))


def write32(mut stream: List[UInt8], value: Int):
    """DataWriter.Write32: little-endian."""
    stream.append(UInt8(value & 0xFF))
    stream.append(UInt8((value >> 8) & 0xFF))
    stream.append(UInt8((value >> 16) & 0xFF))
    stream.append(UInt8((value >> 24) & 0xFF))


def write_bytes_file(path: String, raw: List[UInt8]) raises:
    """Запись сырых байтов: String строится из байтов без перекодировки."""
    var s = _bytes_to_string(raw)
    with open(path, "w") as f:
        _ = f.write(s)


# ============================================================================
# DataArea (Assembler/DataArea.cs) — одна область данных (глобальная или локальная)
# ============================================================================

@fieldwise_init
struct DataElement(ImplicitlyCopyable):
    var name: String
    var position: Int
    var datatype: Int


struct DataArea(Copyable, Movable):
    var elements: List[DataElement]
    var index: Dict[String, Int]
    var endofarea: Int
    var have_non_parameters: Bool

    def __init__(out self):
        self.elements = List[DataElement]()
        self.index = Dict[String, Int]()
        self.endofarea = 0
        self.have_non_parameters = False

    def add(mut self, name: String, length: Int, number: Int, datatype: Int, is_parameter: Bool) raises:
        if name in self.index:
            raise Error("Identifier " + name + " already in use")

        if not is_parameter:
            self.have_non_parameters = True
        elif self.have_non_parameters:
            raise Error("Can not place IN,OUT,IO elements after DATA elements")

        while self.endofarea % length != 0:  # выравнивание
            if is_parameter:  # параметрам padding запрещён
                raise Error("Can not insert padding for propper alignment. Try to reorder the IO parameters that no padding is necessary")
            self.endofarea += 1

        self.elements.append(DataElement(name, self.endofarea, datatype))
        self.index[name] = len(self.elements) - 1
        self.endofarea += length * number

    def total_bytes(self) -> Int:
        return self.endofarea

    def get(self, name: String) raises -> Int:
        """Индекс элемента по имени или -1."""
        if name in self.index:
            return self.index[name]
        return -1


# ============================================================================
# Значение параметра для проверки типов (аналог Object в C#:
# DataElement | int | double | string)
# ============================================================================

comptime AV_ELEMENT = 0
comptime AV_INT = 1
comptime AV_DOUBLE = 2
comptime AV_STRING = 3


@fieldwise_init
struct ArgVal(ImplicitlyCopyable):
    var kind: Int
    var name: String
    var dt: Int
    var i: Int
    var f: Float64
    var s: String


def check_datatype(arg: ArgVal, pdt: Int, pat: Int) raises:
    """DataTypeChecker.Check (DataType.cs:47-121) — те же сообщения."""
    if arg.kind == AV_ELEMENT:
        if arg.dt != pdt and pdt != DT_UNSPECIFIED:
            raise Error("Using variable of wrong type for call: " + arg.name)
    elif arg.kind == AV_INT:
        var c = arg.i
        if pat == AT_READMANY and pdt == DT_I8:
            raise Error("Using constant value as parameter where a string value or variable reference is required")
        if pat != AT_READ:
            raise Error("Using constant value as parameter where a variable reference is required")
        if pdt == DT_I8:
            if c < -128 or c > 127:
                raise Error("Constant value " + String(c) + "+ out of range of I8")
        elif pdt == DT_I16 or pdt == DT_VTHREAD:
            if c < -32768 or c > 32767:
                raise Error("Constant value " + String(c) + "+ out of range of I16")
        elif pdt == DT_I32:
            pass  # должен быть в диапазоне по построению
        else:
            raise Error("Constant value " + String(c) + " does not fit the parameter type " + String(pdt))
    elif arg.kind == AV_DOUBLE:
        if pdt != DT_F and pdt != DT_UNSPECIFIED:
            raise Error("Can not use float literal '" + String(arg.f) + "' for this parameter type")
        if pat != AT_READ:
            raise Error("Can not use float literal '" + String(arg.f) + "' for output parameter")
    elif arg.kind == AV_STRING:
        if pdt != DT_I8:
            raise Error("Can not use string literal '" + arg.s + "' for this parameter type")
        if pat != AT_READ and pat != AT_READMANY:
            raise Error("Can not use string literal '" + arg.s + "' for output parameter")


# ============================================================================
# VMCommand (Assembler/VMCommand.cs) — строка таблицы опкодов
# ============================================================================

struct VMCommand(Copyable, Movable):
    var name: String
    var opcode: List[UInt8]
    var parameters: List[Int]
    var access: List[Int]

    def __init__(out self, descriptor: String) raises:
        # C# split по '\t' и ' ' с RemoveEmptyEntries
        var norm = descriptor.replace("\t", " ")
        var parts = norm.split(" ")
        var toks = List[String]()
        for k in range(len(parts)):
            if parts[k].byte_length() > 0:
                toks.append(String(parts[k]))

        self.opcode = List[UInt8]()
        var pstart = 0
        if toks[0].byte_length() == 2 and len(toks) >= 2:
            self.opcode.append(UInt8(_parse_hex2(toks[0])))
            self.name = String(toks[1])
            pstart = 2
        elif toks[0].byte_length() == 4 and len(toks) >= 3:
            self.opcode.append(UInt8(_parse_hex2(String(toks[0][byte=0:2]))))
            self.opcode.append(UInt8(_parse_hex2(String(toks[0][byte=2:4]))))
            self.name = String(toks[1]) + " " + String(toks[2])
            pstart = 3
        else:
            raise Error("Can not decode definition list")

        self.parameters = List[Int]()
        self.access = List[Int]()
        var nump = len(toks) - pstart
        for k in range(nump):
            var t = toks[pstart + k]
            var dt: Int
            if _byte_at(t, 0) == 0x38:  # '8'
                dt = DT_I8
            elif _byte_at(t, 0) == 0x31 and t.startswith("16"):  # '1'
                dt = DT_I16
            elif _byte_at(t, 0) == 0x33 and t.startswith("32"):  # '3'
                dt = DT_I32
            elif _byte_at(t, 0) == 0x46:  # 'F'
                dt = DT_F
            elif _byte_at(t, 0) == 0x3F:  # '?'
                dt = DT_UNSPECIFIED
            elif t == "L":
                dt = DT_LABEL
            elif t == "T":
                dt = DT_VTHREAD
            elif t == "S":
                dt = DT_VSUBCALL
            elif t == "P":
                dt = DT_PCOUNT
            else:
                raise Error("Can not read opcode descriptor: " + descriptor)

            var at = AT_READ
            if t.endswith("*"):
                at = AT_WRITE
            elif t.endswith("+"):
                at = AT_READMANY

            self.parameters.append(dt)
            self.access.append(at)


# ============================================================================
# LMSObject (Assembler/LMSObject.cs) — объединённый объект VM
# (поток LMSThread / subcall LMSSubCall различаются флагом is_thread)
# ============================================================================

struct LMSObject(Copyable, Movable):
    var name: String
    var id: Int
    var is_thread: Bool
    var started: Bool
    var program: List[UInt8]
    var locals: DataArea
    var labels: Dict[String, Int]
    var references: Dict[Int, String]
    var offset_to_instructions: Int
    # только для subcall:
    var io_data_types: List[Int]
    var io_access_types: List[Int]
    var io_string_sizes: List[Int]
    var caller_memorization: List[List[ArgVal]]
    var implementation: Int  # индекс объекта-реализации алиаса или -1

    def __init__(out self, obj_name: String, obj_id: Int, thread: Bool):
        self.name = obj_name
        self.id = obj_id
        self.is_thread = thread
        self.started = False
        self.program = List[UInt8]()
        self.locals = DataArea()
        self.labels = Dict[String, Int]()
        self.references = Dict[Int, String]()
        self.offset_to_instructions = 0
        self.io_data_types = List[Int]()
        self.io_access_types = List[Int]()
        self.io_string_sizes = List[Int]()
        self.caller_memorization = List[List[ArgVal]]()
        self.implementation = -1

    def start_code(mut self) raises:
        if self.started or self.implementation != -1:
            raise Error("Duplicate definition of " + self.name)
        self.program = List[UInt8]()
        self.started = True

    def add_opcode(mut self, op0: UInt8, op1: Int) raises:
        """LMSObject.AddOpCode: второй байт мнемоники идёт как КОНСТАНТА.

        op1 = -1 означает однобайтовый опкод (байты таблицы 0..255, поэтому -1
        безопасен как признак отсутствия второго байта).
        """
        self.program.append(op0)
        if op1 != -1:
            self.add_constant(op1)

    def add_constant(mut self, value: Int):
        self.add_constant_min(value, 0)

    def add_constant_min(mut self, value: Int, minimumencodingbytes: Int):
        """LMSObject.AddConstant(value, minimumencodingbytes) (LMSObject.cs:72-93)."""
        if value >= -32 and value <= 31 and minimumencodingbytes <= 1:
            self.program.append(UInt8(value & 0x3F))
        elif value >= -128 and value <= 127 and minimumencodingbytes <= 2:
            self.program.append(0x81)
            self.program.append(UInt8(value & 0xFF))
        elif value >= -32768 and value <= 32767 and minimumencodingbytes <= 3:
            self.program.append(0x82)
            write16(self.program, value)
        else:
            self.program.append(0x83)
            write32(self.program, value)

    def add_variable_reference(mut self, index: Int, local: Bool) raises:
        """LMSObject.AddVariableReference (LMSObject.cs:95-120)."""
        if index < 0:
            raise Error("Negative variable index!")
        if index <= 31:
            self.program.append(UInt8((0x40 if local else 0x60) | index))
        elif index >= -127 and index <= 127:
            self.program.append(UInt8(0xC1 if local else 0xE1))
            self.program.append(UInt8(index & 0xFF))
        elif index >= -32768 and index <= 32767:
            self.program.append(UInt8(0xC2 if local else 0xE2))
            write16(self.program, index)
        else:
            self.program.append(UInt8(0xC3 if local else 0xE3))
            write32(self.program, index)

    def add_string_literal(mut self, s: String) raises:
        """LMSObject.AddStringLiteral (LMSObject.cs:122-135): 0x80 + байты + 0x00."""
        self.program.append(0x80)
        for i in range(s.byte_length()):
            var c = Int(_byte_at(s, i))
            if c <= 0 or c > 255:
                raise Error("String literal contains non-ascii character")
            self.program.append(UInt8(c))
        self.program.append(0)

    def add_float_constant(mut self, fvalue: Float64):
        """LMSObject.AddFloatConstant: 0x83 + IEEE-754 single LE (double->float)."""
        from std.memory import bitcast
        self.program.append(0x83)
        var single = Float32(fvalue)
        var bits = bitcast[DType.uint32](single)
        write32(self.program, Int(bits))

    def add_label_reference(mut self, label: String) raises:
        """LMSObject.AddLabelReference (LMSObject.cs:150-190).

        Метка уже определена -> кратчайшая форма с поправкой от конца инструкции;
        иначе заглушка 0x83+4 и запись позиции для back-patching.
        """
        if label in self.labels:
            var target = self.labels[label]
            var distancefromparameterstart = target - len(self.program)
            if distancefromparameterstart > 0:
                raise Error("Internal error: Forward label already known")
            if distancefromparameterstart - 1 >= -32:
                self.add_constant_min(distancefromparameterstart - 1, 1)
            elif distancefromparameterstart - 2 >= -128:
                self.add_constant_min(distancefromparameterstart - 2, 2)
            elif distancefromparameterstart - 3 >= -32768:
                self.add_constant_min(distancefromparameterstart - 3, 3)
            else:
                self.add_constant_min(distancefromparameterstart - 5, 5)
        else:
            self.references[len(self.program) + 1] = label
            self.add_constant_min(0, 4)  # заглушка 32-бит, заменяется при back-patching

    def add_label_difference(mut self, descriptor: String):
        """LMSObject.AddLabelDifference (LMSObject.cs:192-197)."""
        self.references[len(self.program) + 1] = descriptor
        self.add_constant_min(0, 4)

    def memorize_label(mut self, label: String):
        """LMSObject.MemorizeLabel: позиция = текущая длина кода."""
        self.labels[label] = len(self.program)

    def memorize_io_parameter(mut self, dt: Int, at: Int) raises:
        if self.is_thread:
            raise Error("Can not add IN or OUT data to this object")
        self.io_data_types.append(dt)
        self.io_access_types.append(at)
        self.io_string_sizes.append(0)

    def memorize_string_io_parameter(mut self, size: Int, at: Int) raises:
        if self.is_thread:
            raise Error("Can not add IN or OUT data to this object")
        if size < 1 or size > 255:
            raise Error("Length of IO parameter must not exceed 255 bytes")
        self.io_data_types.append(DT_I8)
        self.io_access_types.append(at)
        self.io_string_sizes.append(size)

    def start_caller_memorization(mut self):
        self.caller_memorization.append(List[ArgVal]())

    def memorize_caller_parameter(mut self, arg: ArgVal):
        self.caller_memorization[len(self.caller_memorization) - 1].append(arg)

    def write_bytecodes(mut self, mut stream: List[UInt8], offset: Int) raises:
        """LMSObject.WriteByteCodes + back-patching (LMSObject.cs:214-262)."""
        self.offset_to_instructions = offset

        if not self.started:
            raise Error("Unresolved subcall: " + self.name)

        var i = 0
        var l = len(self.program)
        while i < l:
            if i in self.references:
                var label = self.references[i]
                var colonidx = _find_byte(label, 0x3A)  # ':'
                if colonidx > 0:
                    # разность меток A:B
                    var firstlabel = _sub_bytes(label, 0, colonidx)
                    var secondlabel = _sub_bytes(label, colonidx + 1, label.byte_length())
                    if firstlabel not in self.labels or secondlabel not in self.labels:
                        raise Error("Unresolved label distance: " + label)
                    write32(stream, self.labels[secondlabel] - self.labels[firstlabel])
                    i += 4
                else:
                    # обычная ссылка на метку
                    if label not in self.labels:
                        raise Error("Unresolved jump target: " + label)
                    write32(stream, self.labels[label] - (i + 4))
                    i += 4
            else:
                stream.append(self.program[i])
                i += 1

    def write_header_bytes(self, mut stream: List[UInt8], objects: List[LMSObject]):
        """LMSThread/LMSSubCall.WriteHeader: 12 байт оглавления (без мутаций)."""
        var off = self.offset_to_instructions
        var lbytes = self.locals.total_bytes()
        if self.implementation != -1:  # алиас берёт данные реализации
            off = objects[self.implementation].offset_to_instructions
            lbytes = objects[self.implementation].locals.total_bytes()
        write32(stream, off)
        write16(stream, 0)  # owner
        write16(stream, 0 if self.is_thread else 1)  # triggerCount
        write32(stream, lbytes)

    def write_body(mut self, mut stream: List[UInt8], offset: Int) raises:
        """LMSThread/LMSSubCall.WriteBody (LMSObject.cs:297-302, 378-447)."""
        if not self.is_thread and self.implementation != -1:
            return  # алиас тела не имеет

        if not self.is_thread:
            var numpar = len(self.io_data_types)
            # описатели IN/OUT/IO перед байткодом
            stream.append(UInt8(numpar))
            for i in range(numpar):
                var ioflags = 0
                var at = self.io_access_types[i]
                if at == AT_READ or at == AT_READMANY:
                    ioflags = 0x80
                elif at == AT_WRITE:
                    ioflags = 0x40
                else:
                    ioflags = 0xC0
                var dt = self.io_data_types[i]
                if dt == DT_I8:
                    if self.io_string_sizes[i] == 0:
                        stream.append(UInt8(ioflags))
                    else:
                        stream.append(UInt8(ioflags | 0x04))
                        stream.append(UInt8(self.io_string_sizes[i] & 0xFF))
                elif dt == DT_I16:
                    stream.append(UInt8(ioflags | 0x01))
                elif dt == DT_I32:
                    stream.append(UInt8(ioflags | 0x02))
                elif dt == DT_F:
                    stream.append(UInt8(ioflags | 0x03))

        self.write_bytecodes(stream, offset)

        if self.is_thread:
            stream.append(0x0A)  # OBJECT_END; RETURN не дописывается
        else:
            stream.append(0x08)  # RETURN дописан ассемблером
            stream.append(0x0A)  # OBJECT_END

            # проверка совместимости всех вызовов с параметрами
            var numpar = len(self.io_data_types)
            for c in range(len(self.caller_memorization)):
                if len(self.caller_memorization[c]) != numpar:
                    raise Error("Detected use of CALL " + self.name + " with " + String(len(self.caller_memorization[c])) + " parameters instead of " + String(numpar))
                for i in range(numpar):
                    check_datatype(self.caller_memorization[c][i], self.io_data_types[i], self.io_access_types[i])


# ============================================================================
# Ассемблер (Assembler/Assembler.cs)
# ============================================================================

struct Assembler(Movable):
    var commands: Dict[String, Int]  # имя -> индекс в cmd_list
    var cmd_list: List[VMCommand]
    var globals: DataArea
    var objects: List[LMSObject]  # индекс = id-1 (id = Count+1 при создании)
    var obj_index: Dict[String, Int]
    var current: Int  # индекс текущего объекта или -1

    def __init__(out self) raises:
        self.commands = Dict[String, Int]()
        self.cmd_list = List[VMCommand]()
        self.globals = DataArea()
        self.objects = List[LMSObject]()
        self.obj_index = Dict[String, Int]()
        self.current = -1
        self._read_bytecode_list()

    def _read_bytecode_list(mut self) raises:
        """Assembler.readByteCodeList: '//'-комментарии, Trim, пропуск пустых."""
        var raw = String(BYTECODE_LIST).split("\n")
        for k in range(len(raw)):
            var line = String(raw[k])
            var idx = _find_double_slash(line)
            if idx != -1:
                line = _sub_bytes(line, 0, idx)
            var stripped = String(line.strip())
            line = stripped^
            if line.byte_length() > 0:
                var c = VMCommand(line)
                self.commands[c.name] = len(self.cmd_list)
                self.cmd_list.append(c^)

    # ---- разбор ----------------------------------------------------------

    def process_line(mut self, line: String) raises:
        """Assembler.ProcessLine."""
        var tokens = tokenize_line(line)
        if len(tokens) < 1:
            return
        var first = tokens[0]
        if self.current == -1:
            self.process_top_level(first, tokens)
        else:
            self.process_in_object(first, tokens)

    def process_top_level(mut self, first: String, tokens: List[String]) raises:
        """Assembler.ProcessLine, ветка top-level (Assembler.cs:122-196)."""
        if first == "VMTHREAD":
            var name = fetch_id(tokens, 1, True)
            if name in self.obj_index:
                var idx = self.obj_index[name]
                if not self.objects[idx].is_thread:
                    raise Error("Trying to start an object that is not defined as a thread")
                self.objects[idx].start_code()
                self.current = idx
            else:
                var idx = len(self.objects)
                self.objects.append(LMSObject(name, idx + 1, True))
                self.obj_index[name] = idx
                self.objects[idx].start_code()
                self.current = idx
        elif first == "SUBCALL":
            var name = fetch_id(tokens, 1, True)
            if name in self.obj_index:
                var idx = self.obj_index[name]
                if self.objects[idx].is_thread:
                    raise Error("Trying to access an object that is not defined as a subcall")
                self.objects[idx].start_code()
                self.current = idx
            else:
                var idx = len(self.objects)
                self.objects.append(LMSObject(name, idx + 1, False))
                self.obj_index[name] = idx
                self.objects[idx].start_code()
                self.current = idx
        elif first == "DATA8":
            self.globals.add(fetch_id(tokens, 1, True), 1, 1, DT_I8, False)
        elif first == "DATA16":
            self.globals.add(fetch_id(tokens, 1, True), 2, 1, DT_I16, False)
        elif first == "DATA32":
            self.globals.add(fetch_id(tokens, 1, True), 4, 1, DT_I32, False)
        elif first == "DATAF":
            self.globals.add(fetch_id(tokens, 1, True), 4, 1, DT_F, False)
        elif first == "DATAS" or first == "ARRAY8":
            self.globals.add(fetch_id(tokens, 1, False), 1, fetch_number(tokens, 2, True), DT_I8, False)
        elif first == "ARRAY16":
            self.globals.add(fetch_id(tokens, 1, False), 2, fetch_number(tokens, 2, True), DT_I16, False)
        elif first == "ARRAY32":
            self.globals.add(fetch_id(tokens, 1, False), 4, fetch_number(tokens, 2, True), DT_I32, False)
        elif first == "ARRAYF":
            self.globals.add(fetch_id(tokens, 1, False), 4, fetch_number(tokens, 2, True), DT_F, False)
        else:
            raise Error("Unknown command: " + first)

    def _new_subcall(mut self, name: String) -> Int:
        """Создаёт forward-subcall с очередным ID; возвращает индекс."""
        var idx = len(self.objects)
        self.objects.append(LMSObject(name, idx + 1, False))
        self.obj_index[name] = idx
        return idx

    def _new_thread(mut self, name: String) -> Int:
        var idx = len(self.objects)
        self.objects.append(LMSObject(name, idx + 1, True))
        self.obj_index[name] = idx
        return idx

    def process_in_object(mut self, first: String, tokens: List[String]) raises:
        """Assembler.ProcessLine, ветка внутри объекта (Assembler.cs:199-516)."""
        if first == "}":
            self.current = -1
            return

        if first == "SUBCALL":
            # алиас: тот же код, другой ID (Assembler.cs:210-232)
            if self.objects[self.current].is_thread:
                raise Error("Can not add subcall alias to non-subcall object")
            var name = fetch_id(tokens, 1, True)
            var aidx = -1
            if name in self.obj_index:
                aidx = self.obj_index[name]
            else:
                aidx = self._new_subcall(name)
            if self.objects[aidx].started or self.objects[aidx].implementation != -1:
                raise Error("Duplicate definition of " + self.objects[aidx].name)
            self.objects[aidx].implementation = self.current
            return

        if first == "DATA8":
            self.objects[self.current].locals.add(fetch_id(tokens, 1, True), 1, 1, DT_I8, False)
        elif first == "DATA16":
            self.objects[self.current].locals.add(fetch_id(tokens, 1, True), 2, 1, DT_I16, False)
        elif first == "DATA32":
            self.objects[self.current].locals.add(fetch_id(tokens, 1, True), 4, 1, DT_I32, False)
        elif first == "DATAF":
            self.objects[self.current].locals.add(fetch_id(tokens, 1, True), 4, 1, DT_F, False)
        elif first == "DATAS" or first == "ARRAY8":
            self.objects[self.current].locals.add(fetch_id(tokens, 1, False), 1, fetch_number(tokens, 2, True), DT_I8, False)
        elif first == "ARRAY16":
            self.objects[self.current].locals.add(fetch_id(tokens, 1, False), 2, fetch_number(tokens, 2, True), DT_I16, False)
        elif first == "ARRAY32":
            self.objects[self.current].locals.add(fetch_id(tokens, 1, False), 4, fetch_number(tokens, 2, True), DT_I32, False)
        elif first == "ARRAYF":
            self.objects[self.current].locals.add(fetch_id(tokens, 1, False), 4, fetch_number(tokens, 2, True), DT_F, False)
        elif first == "IN_8":
            self.objects[self.current].locals.add(fetch_id(tokens, 1, True), 1, 1, DT_I8, True)
            self.objects[self.current].memorize_io_parameter(DT_I8, AT_READ)
        elif first == "IN_16":
            self.objects[self.current].locals.add(fetch_id(tokens, 1, True), 2, 1, DT_I16, True)
            self.objects[self.current].memorize_io_parameter(DT_I16, AT_READ)
        elif first == "IN_32":
            self.objects[self.current].locals.add(fetch_id(tokens, 1, True), 4, 1, DT_I32, True)
            self.objects[self.current].memorize_io_parameter(DT_I32, AT_READ)
        elif first == "IN_F":
            self.objects[self.current].locals.add(fetch_id(tokens, 1, True), 4, 1, DT_F, True)
            self.objects[self.current].memorize_io_parameter(DT_F, AT_READ)
        elif first == "IN_S":
            var n = fetch_number(tokens, 2, True)
            self.objects[self.current].locals.add(fetch_id(tokens, 1, False), 1, n, DT_I8, True)
            self.objects[self.current].memorize_string_io_parameter(n, AT_READMANY)
        elif first == "OUT_8":
            self.objects[self.current].locals.add(fetch_id(tokens, 1, True), 1, 1, DT_I8, True)
            self.objects[self.current].memorize_io_parameter(DT_I8, AT_WRITE)
        elif first == "OUT_16":
            self.objects[self.current].locals.add(fetch_id(tokens, 1, True), 2, 1, DT_I16, True)
            self.objects[self.current].memorize_io_parameter(DT_I16, AT_WRITE)
        elif first == "OUT_32":
            self.objects[self.current].locals.add(fetch_id(tokens, 1, True), 4, 1, DT_I32, True)
            self.objects[self.current].memorize_io_parameter(DT_I32, AT_WRITE)
        elif first == "OUT_F":
            self.objects[self.current].locals.add(fetch_id(tokens, 1, True), 4, 1, DT_F, True)
            self.objects[self.current].memorize_io_parameter(DT_F, AT_WRITE)
        elif first == "OUT_S":
            var n = fetch_number(tokens, 2, True)
            self.objects[self.current].locals.add(fetch_id(tokens, 1, False), 1, n, DT_I8, True)
            self.objects[self.current].memorize_string_io_parameter(n, AT_WRITE)
        elif first == "IO_8":
            self.objects[self.current].locals.add(fetch_id(tokens, 1, True), 1, 1, DT_I8, True)
            self.objects[self.current].memorize_io_parameter(DT_I8, AT_READWRITE)
        elif first == "IO_16":
            self.objects[self.current].locals.add(fetch_id(tokens, 1, True), 2, 1, DT_I16, True)
            self.objects[self.current].memorize_io_parameter(DT_I16, AT_READWRITE)
        elif first == "IO_32":
            self.objects[self.current].locals.add(fetch_id(tokens, 1, True), 4, 1, DT_I32, True)
            self.objects[self.current].memorize_io_parameter(DT_I32, AT_READWRITE)
        elif first == "IO_F":
            self.objects[self.current].locals.add(fetch_id(tokens, 1, True), 4, 1, DT_F, True)
            self.objects[self.current].memorize_io_parameter(DT_F, AT_READWRITE)
        elif first == "IO_S":
            var n = fetch_number(tokens, 2, True)
            self.objects[self.current].locals.add(fetch_id(tokens, 1, False), 1, n, DT_I8, True)
            self.objects[self.current].memorize_string_io_parameter(n, AT_READWRITE)

        elif first == "CALL":
            # вызов subcall-объекта, возможно ещё не объявленного (Assembler.cs:345-380)
            var name = fetch_id(tokens, 1, False)
            var sc_idx = -1
            if name in self.obj_index:
                sc_idx = self.obj_index[name]
                if self.objects[sc_idx].is_thread:
                    raise Error("Trying to call an object that is not defined as a SUBCALL")
            else:
                sc_idx = self._new_subcall(name)

            self.objects[sc_idx].start_caller_memorization()

            var numpar = len(tokens) - 2
            self.objects[self.current].add_opcode(0x09, -1)
            self.objects[self.current].add_constant(self.objects[sc_idx].id)
            self.objects[self.current].add_constant(numpar)
            for i in range(numpar):
                var p = self.decode_and_add_parameter(tokens[2 + i])
                self.objects[sc_idx].memorize_caller_parameter(p)

        elif first.endswith(":"):
            # объявление метки (Assembler.cs:382-389)
            if _find_byte(first, 0x3A) != first.byte_length() - 1:
                raise Error("Label must only have one trailing ':'")
            self.objects[self.current].memorize_label(_sub_bytes(first, 0, first.byte_length() - 1))
        else:
            self.process_vm_command(first, tokens)

    def process_vm_command(mut self, first: String, tokens: List[String]) raises:
        """Обычная инструкция: опкод + параметры по таблице (Assembler.cs:390-515)."""
        var ci = -1
        var paramstart = 0
        if first in self.commands:
            ci = self.commands[first]
            paramstart = 1
        elif len(tokens) < 2:
            raise Error("Unknown opcode " + first)
        else:
            var compound = first + " " + tokens[1]
            if compound in self.commands:
                ci = self.commands[compound]
                paramstart = 2
            else:
                raise Error("Unknown opcode " + compound)

        var paramcount = len(self.cmd_list[ci].parameters)

        # опкод; второй байт двухбайтовой мнемоники кодируется как константа
        var op0 = self.cmd_list[ci].opcode[0]
        var op1 = -1
        if len(self.cmd_list[ci].opcode) > 1:
            op1 = Int(self.cmd_list[ci].opcode[1])
        self.objects[self.current].add_opcode(op0, op1)

        var i = 0
        while i < paramcount:
            if paramstart + i >= len(tokens):
                raise Error("Too few parameters for " + self.cmd_list[ci].name)

            # при большем числе параметров повторяется последний тип
            var pidx = i
            if pidx > len(self.cmd_list[ci].parameters) - 1:
                pidx = len(self.cmd_list[ci].parameters) - 1
            var ptype = self.cmd_list[ci].parameters[pidx]
            var atype = self.cmd_list[ci].access[pidx]
            var tok = tokens[paramstart + i]

            if ptype == DT_LABEL:
                self.objects[self.current].add_label_reference(tok)
            elif ptype == DT_VTHREAD:
                # идентификатор vmthread
                var tidx = -1
                if tok in self.obj_index:
                    tidx = self.obj_index[tok]
                    if not self.objects[tidx].is_thread:
                        raise Error("Trying to start an object that is not defined as a thread")
                else:
                    tidx = self._new_thread(tok)
                self.objects[self.current].add_constant(self.objects[tidx].id)
            elif ptype == DT_VSUBCALL:
                # идентификатор subcall; имя "0" -> константа 0
                if tok == "0":
                    self.objects[self.current].add_constant(0)
                else:
                    var sidx = -1
                    if tok in self.obj_index:
                        sidx = self.obj_index[tok]
                        if self.objects[sidx].is_thread:
                            raise Error("Trying to access an object that is not defined as a subcall")
                    else:
                        sidx = self._new_subcall(tok)
                    self.objects[self.current].add_constant(self.objects[sidx].id)
            elif ptype == DT_PCOUNT:
                # число параметров для опкодов с переменным числом
                var p = _scan_i32(tok)
                if not p:
                    raise Error("Can not decode parameter count specifier")
                var pv = p.value()
                if pv < 0 or pv > 1000000000:
                    raise Error("Parameter count specifier out of range")
                self.objects[self.current].add_constant(pv)
                paramcount = len(self.cmd_list[ci].parameters) - 1 + pv
            else:
                # обычные параметры (числа, строки, переменные)
                var a = self.decode_and_add_parameter(tok)
                check_datatype(a, ptype, atype)
            i += 1

        if paramstart + paramcount != len(tokens):
            raise Error("Invalid number of parameters for " + self.cmd_list[ci].name)

    def decode_and_add_parameter(mut self, p: String) raises -> ArgVal:
        """Assembler.DecodeAndAddParameter (Assembler.cs:521-591)."""
        # разность меток
        if _byte_at(p, 0) != 0x27 and _find_byte(p, 0x3A) != -1:
            self.objects[self.current].add_label_difference(p)
            return ArgVal(AV_INT, "", DT_I32, 999999999, 0.0, "")

        var c0 = _byte_at(p, 0)
        # переменная
        if (65 <= Int(c0) <= 90) or c0 == 0x5F:
            var offset = 0
            var name = p
            var plusidx = _find_byte(p, 0x2B)  # '+'
            if plusidx != -1:
                var rest = _sub_bytes(p, plusidx + 1, p.byte_length())
                var off = _scan_i32(rest)
                if off:
                    offset = off.value()
                    name = _sub_bytes(p, 0, plusidx)

            var e_idx = self.objects[self.current].locals.get(name)
            var local = True
            var area_idx = 0  # 0=locals, 1=globals
            if e_idx == -1:
                e_idx = self.globals.get(name)
                local = False
                area_idx = 1
            if e_idx == -1:
                raise Error("Unknown identifier " + name)

            var element: DataElement
            if area_idx == 0:
                element = self.objects[self.current].locals.elements[e_idx]
            else:
                element = self.globals.elements[e_idx]
            self.objects[self.current].add_variable_reference(element.position + offset, local)
            return ArgVal(AV_ELEMENT, element.name, element.datatype, 0, 0.0, "")

        # числовая константа
        if (48 <= Int(c0) <= 57) or c0 == 0x2D:
            var c = _scan_i32(p)
            if c:
                self.objects[self.current].add_constant(c.value())
                return ArgVal(AV_INT, "", DT_I32, c.value(), 0.0, "")
            var d = _scan_f64(p)
            if d:
                self.objects[self.current].add_float_constant(d.value())
                return ArgVal(AV_DOUBLE, "", DT_F, 0, d.value(), "")
            raise Error("Can not decode number: " + p)

        # строковый литерал
        if c0 == 0x27:
            var lit = _sub_bytes(p, 1, p.byte_length() - 1)
            self.objects[self.current].add_string_literal(lit)
            return ArgVal(AV_STRING, "", DT_I8, 0, 0.0, lit)

        raise Error("Invalid parameter value")

    # ---- вывод -----------------------------------------------------------

    def generate_output(mut self, out_path: String) raises:
        """Assembler.GenerateOutput (Assembler.cs:593-631)."""
        var numobjects = len(self.objects)

        # байткоды во временный буфер (по возрастанию ID = индексу)
        var allbytecodes = List[UInt8]()
        var totalheadersize = 16 + numobjects * 12

        for i in range(numobjects):
            self.objects[i].write_body(allbytecodes, totalheadersize + len(allbytecodes))

        var raw = List[UInt8]()
        raw.append(0x4C)  # 'L'
        raw.append(0x45)  # 'E'
        raw.append(0x47)  # 'G'
        raw.append(0x4F)  # 'O'
        write32(raw, totalheadersize + len(allbytecodes))
        write16(raw, 0x0068)
        write16(raw, numobjects)
        write32(raw, self.globals.total_bytes())

        for i in range(numobjects):
            self.objects[i].write_header_bytes(raw, self.objects)

        for i in range(len(allbytecodes)):
            raw.append(allbytecodes[i])

        write_bytes_file(out_path, raw^)


# ============================================================================
# Токенизация строки листинга (Assembler.cs:633-710)
# ============================================================================

def tokenize_line(l: String) raises -> List[String]:
    """Assembler.TokenizeLine: '//' кончает строку; пропуск ' \\t,(){' ; строки в '...';
    '}' — отдельный токен; прочее — токены [A-Za-z0-9_-]+[A-Za-z0-9_.:+]*, uppercase."""
    var tokens = List[String]()

    var pos = 0
    var n = l.byte_length()
    while pos < n:
        var c = _byte_at(l, pos)

        if c == 0x2F:  # '/' — остаток строки комментарий
            break
        elif c == 0x20 or c == 0x09 or c == 0x2C or c == 0x28 or c == 0x29 or c == 0x7B:
            # пробел, таб, ',', '(', ')', '{'
            pos += 1
        elif c == 0x27:  # строка в апострофах
            var start = pos
            pos += 1
            var terminated = False
            while pos < n:
                if _byte_at(l, pos) == 0x27:
                    pos += 1
                    tokens.append(_unescape(_sub_bytes(l, start, pos)))
                    terminated = True
                    break
                pos += 1
            if not terminated:
                raise Error("Nonterminated string")
        elif _is_token_start(c):
            var start = pos
            pos += 1
            while pos < n:
                if _is_token_cont(_byte_at(l, pos)):
                    pos += 1
                else:
                    break
            tokens.append(_upper_ascii(_sub_bytes(l, start, pos)))
        elif c == 0x7D:  # '}'
            pos += 1
            tokens.append(String("}"))
        else:
            raise Error("Unknown letter '" + chr(Int(c)) + "' ")

    return tokens^


def fetch_id(tokens: List[String], position: Int, must_be_last: Bool) raises -> String:
    """Assembler.FetchID."""
    if len(tokens) <= position:
        raise Error("Identifier expected")
    if must_be_last and position + 1 < len(tokens):
        raise Error("Too many elements for command")
    var token = tokens[position]
    var c = Int(_byte_at(token, 0))
    if (65 <= c <= 90) or c == 0x5F:
        return token
    raise Error("Identifer expected instead of " + token)


def fetch_number(tokens: List[String], position: Int, must_be_last: Bool) raises -> Int:
    """Assembler.FetchNumber: целое 1..32767."""
    if len(tokens) <= position:
        raise Error("Number expected")
    if must_be_last and position + 1 < len(tokens):
        raise Error("Too many elements for command")
    var v = _scan_i64(tokens[position])
    if v == None:
        raise Error("Number expected")
    var value = v.value()
    if value < 1 or value > 32767:
        raise Error("Number ouf of range")
    return value


# ============================================================================
# Точка входа стадии 4
# ============================================================================

def rbf_path_for(lmsb_path: String) -> String:
    """<Имя>.rbf в том же каталоге, что и входной .lmsb (как у оракула)."""
    var d = dir_name(lmsb_path)
    var b = strip_ext(base_name(lmsb_path))
    if d == "":
        return b + ".rbf"
    return d + "/" + b + ".rbf"


def assemble_file(in_path: String, out_path: String) raises -> List[String]:
    """Assembler.Start: разбор + вывод; возвращает список ошибок (как errorList)."""
    var errors = List[String]()
    var asm = Assembler()

    var lines = read_lines(in_path)
    for i in range(len(lines)):
        try:
            asm.process_line(lines[i])
        except e:
            errors.append("Error at line " + String(i + 1) + ": " + String(e))
    if asm.current != -1:
        errors.append("Unexpected end of file")

    try:
        asm.generate_output(out_path)
    except e:
        errors.append("Error at subcall integration: " + String(e))

    return errors^


def assemble_lmsb(in_path: String) raises -> List[String]:
    """Собрать .rbf рядом с .lmsb; вернуть ошибки."""
    return assemble_file(in_path, rbf_path_for(in_path))
