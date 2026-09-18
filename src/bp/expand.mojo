"""Развёртка BP-программы: препроцессор + линковка + интерпретация -> `~<Имя>.bp`.

Порт фаз C# (файлы не менялись):
  bp/preproc.mojo                   — include (.bpi) / import (.bpm): IncludeErrorParser,
                                      ImportErrorParser, FirstFindFiles, AddIncludesToMain,
                                      реестры модулей + замыкание вызовов методов
  Interpreter/Utils/Linker.cs        — FuncRename (324-446), VarsAndLabelsRename (448-622),
                                      CreateCallingPropertyLines (788-858),
                                      RemoveMainFunc/RemoveMainSub,
                                      CreateFunctionsDicionary/CreateSubsDicionary
  Interpreter/Utils/Interpreter.cs   — ParseAllCalls (654-754), ParseFuncInitLine (125-174),
                                       ParseCalls/ParseOneCall (176-343), FuncVariablesInit (448-487),
                                       SubVarsInit (538-604), OtherVarsAddToMain (606-652),
                                       CreateProjectOutputLines (345-446), RewriteOutLines (756-788)
  Interpreter/Parsers/LineErrorParser.cs    — ParseJumpOperators/ParseBrakeAndContinue (131-271)
  Interpreter/Parsers/VariableErrorParser.cs — регистрация переменных (60-674), развёртка
                                       x++/x+= (702-954)
  Interpreter/Parsers/ForLineErrorParser.cs  — регистрация счётчика For
  Interpreter/Parsers/ArrayIndexErrorParser.cs — LastIndex индексного выражения
  Interpreter/Parsers/MethodErrorParser.cs   — GetMethodLastIndex (482-549)
  Interpreter/Builder.cs             — GetOutFile/WriteOutFile (444-506)

Структурные проверки (StructErrorParser и т.п.) на валидном корпусе ошибок не дают
и не воспроизводятся; диагностики добавляются только там, где меняется управление.

Квирки, воспроизведённые сознательно (docs/02 §12, docs/notes-expansion-questions.md):
  * нумерация break_N/continue_N: СНАЧАЛА все For-блоки (в порядке появления, снаружи
    внутрь; внутри блока continue раньше break), ЗАТЕМ все While-блоки, ЗАТЕМ return
    по всем SUB-блокам (LineErrorParser.cs:115-118); счётчик сквозной;
  * метка continue/return ставится ПЕРЕД end-строкой, метка break — ПОСЛЕ (205-271);
  * несколько break/continue в одном блоке -> одна метка;
  * порядок секций вывода: init-параметры функций, init остальных переменных (порядок
    регистрации), MAIN, SUB'ы, тела Function (как Sub);
  * переменные-НЕпараметры функций init-строк НЕ получают (SubVarsInit не заходит в
    тела Function — Interpreter.cs:54-56);
  * out-цели вызовов регистрируются в Data.Project.Variables РАНЬШЕ переменных тела
    main (ParseCalls идёт до SubVarsInit);
  * Function X (...) -> `Sub f_x_N`, EndFunction -> `EndSub`; вызов функции остаётся
    SUBCALL-строкой `f_x_N ()`, где N — число аргументов вызова;
  * нулевая арность: вызов `Foo()` НЕ разворачивается (arg_groups даёт [[]] -> 1 != 0);
  * endfunction-строка при переименовании пропускается целиком (Linker.cs:478-482);
  * LABELNAME с `@` внутри функции получает префикс gv_ (баг Linker.cs:518);
  * `--`/`++`/`+=` разворачиваются в `x = x OP ...` в основном тексте (SubVarsInit)
    и в телах Function (повторный проход VariableErrorParser.Start);
  * `thread.run = ИМЯ` — METHODCALL; ИМЯ получает f_<имя>_0 и идёт в callsSub;
  * out-параметр-элемент массива даёт VARARRAYINIT-строку `<var> [ i ] = lv_p_N`;
   * модули (docs/02 §5, §8): тела методов модулей собираются в ModuleMethodsText и
     выводятся ПОСЛЕ функций main, их FUNCINIT -> `Sub m_<модуль>_<имя>_<N>`;
     вызовы методов -> `m_<модуль>_<метод>_<N>`, свойства -> `pr_<модуль>_<свойство>`;
     init-строки использованных свойств идут ПЕРВОЙ секцией вывода; счётчики lv_/ll_
     сквозные через main и методы модулей, но в проходе методов FUNCINIT
     инкрементирует только lv-счётчик (квирк Linker.cs:549-553).
"""

from std.collections import Dict
from std.os import mkdir
from std.sys import exit

from bp.lexer import (
    Line,
    build_line,
    TOK_BRACKETLEFT,
    TOK_BRACKETLEFTARRAY,
    TOK_BRACKETRIGHT,
    TOK_BRACKETRIGHTARRAY,
    TOK_COMMA,
    TOK_DOUBLEBRACKET,
    TOK_EQU,
    TOK_FUNCNAME,
    TOK_KEYWORD,
    TOK_LABEL,
    TOK_LABELNAME,
    TOK_MATHOPERATOR,
    TOK_METHOD,
    TOK_MODULEMETHOD,
    TOK_MODULEPROPERTY,
    TOK_NUMBER,
    TOK_STRING,
    TOK_SUBNAME,
    TOK_VARIABLE,
    LT_EMPTY,
    LT_FOLDER,
    LT_FORINIT,
    LT_FUNCINIT,
    LT_FUNCCALL,
    LT_IMPORT,
    LT_METHODCALL,
    LT_MODULEMETHODCALL,
    LT_MODULEPROPERTY,
    LT_ONEKEYWORD,
    LT_SUBCALL,
    LT_SUBINIT,
    LT_VARARRAYINIT,
    LT_VARDOUBLEMATH,
    LT_VAREQUMATH,
    LT_VARINIT,
    LT_WHILEINIT,
)
from bp.util import base_name, dir_name, lines_to_text, read_lines, strip_ext, write_text
from bp.diag import Diagnostics
from bp.preproc import (
    Preproc,
    add_includes_to_main,
    collect_module_methods,
    first_find_files,
    method_name_of,
    module_name_of,
    param_count_linker,
    parse_module_methods_in_main,
)
from bp.builtins import (
    BuiltinSig,
    OBJ_EVENT,
    OBJ_PROPERTY,
    VT_ANY,
    VT_NON,
    VT_NUMBER,
    VT_NUMBER_ARRAY,
    VT_STRING,
    VT_STRING_ARRAY,
    parse_builtin_table,
)


comptime PT_INPUT = 0
comptime PT_OUTPUT = 1


# ============================================================================
# Изменяемые структуры развёртки (аналоги Word/Line из C#)
# ============================================================================


@fieldwise_init
struct EWord(Copyable, Movable, ImplicitlyCopyable):
    """Слово после линковки: text меняется, origin не трогается."""

    var text: String
    var origin: String
    var token: Int


@fieldwise_init
struct OEntry(Copyable, Movable):
    """Элемент Line.OutLines: сгенерированная под-строка."""

    var words: List[EWord]
    var line_type: Int
    var text: String


@fieldwise_init
struct ELine(Copyable, Movable):
    """Развёртываемая строка (аналог C# Line)."""

    var words: List[EWord]
    var line_type: Int
    var number: Int
    var file_name: String
    var old_line: String
    var new_line: String
    var out_lines: List[OEntry]


def ejoin(words: List[EWord]) -> String:
    """string.Join(" ", Words.Text) — канонический текст строки."""
    var parts = List[String]()
    for i in range(len(words)):
        parts.append(words[i].text)
    if len(parts) == 0:
        return String("")
    return String(" ").join(parts)


def make_eline(line: Line, file_name: String, old_line: String) -> ELine:
    """ELine из результата лексера (Line -> слова/тип/номер)."""
    var words = List[EWord]()
    for i in range(len(line.words)):
        var w = line.words[i].copy()
        words.append(EWord(w.text, w.origin_text, w.token))
    var el = ELine(
        words^,
        line.line_type,
        line.line_number,
        file_name,
        old_line,
        String(""),
        List[OEntry](),
    )
    el.new_line = ejoin(el.words)
    return el^


@fieldwise_init
struct VarInfo(Copyable, Movable, ImplicitlyCopyable):
    """Данные переменной: тип + строка регистрации (C# Variable).

    skip_init — аналог Variable.Line == null (свойства pr_*): в OtherVarsAddToMain
    такие переменные init-строку не получают.
    """

    var var_type: Int
    var line_number: Int
    var file_name: String
    var skip_init: Bool


@fieldwise_init
struct OrderedVars(Copyable, Movable):
    """Словарь с сохранением порядка вставки (C# Dictionary<string, Variable>)."""

    var order: List[String]
    var info: Dict[String, VarInfo]

    def __init__(out self):
        self.order = List[String]()
        self.info = Dict[String, VarInfo]()

    def contains(self, key: String) -> Bool:
        return key in self.info

    def get_type(self, key: String) raises -> Int:
        if key in self.info:
            return self.info[key].var_type
        return VT_NON

    def add(
        mut self,
        key: String,
        var_type: Int,
        line_number: Int,
        file_name: String,
        skip_init: Bool = False,
    ):
        if key in self.info:
            return
        self.order.append(key)
        self.info[key] = VarInfo(var_type, line_number, file_name, skip_init)


@fieldwise_init
struct ParamSig(Copyable, Movable, ImplicitlyCopyable):
    """Параметр функции: ключ (lv_a_1), тип, in/out (C# Function.Parameters)."""

    var key: String
    var var_type: Int
    var param_type: Int


@fieldwise_init
struct FunctionInfo(Copyable, Movable):
    """Функция после линковки: mangled-имя + параметры в порядке объявления."""

    var name: String
    var params: List[ParamSig]


@fieldwise_init
struct UsedProp(Copyable, Movable, ImplicitlyCopyable):
    """Использованное свойство модуля: строка первого использования (для 2020)."""

    var line_number: Int
    var file_name: String


@fieldwise_init
struct UsedProps(Copyable, Movable):
    """Linker._propertys (448-622): использованные свойства в порядке первого использования."""

    var order: List[String]
    var info: Dict[String, UsedProp]

    def __init__(out self):
        self.order = List[String]()
        self.info = Dict[String, UsedProp]()

    def contains(self, key: String) -> Bool:
        return key in self.info

    def add(mut self, key: String, number: Int, file_name: String):
        if key in self.info:
            return
        self.order.append(key)
        self.info[key] = UsedProp(number, file_name)


@fieldwise_init
struct FlatItem(Copyable, Movable):
    """Элемент плоского списка вывода (строка C# OutputLines после RewriteOutLines)."""

    var words: List[EWord]
    var line_type: Int
    var number: Int
    var new_line: String
    var out: List[String]


@fieldwise_init
struct Ctx(Copyable, Movable):
    """Состояние развёртки (Data.Project + локальные наборы Interpreter.Start)."""

    var diags: Diagnostics
    var variables: OrderedVars
    var temp_vars: OrderedVars
    var functions: Dict[String, FunctionInfo]
    var calls_sub: Dict[String, Bool]
    var calls_func: Dict[String, Bool]
    var tmp_sub_calls: Dict[String, Bool]
    var builtins: Dict[String, BuiltinSig]
    var break_point: Int
    # Медиа (MediaBuilder): флаг folder-директивы и её параметры
    var is_folder: Bool
    var folder_name: String
    var project_name: String

    def __init__(out self):
        self.diags = Diagnostics()
        self.variables = OrderedVars()
        self.temp_vars = OrderedVars()
        self.functions = Dict[String, FunctionInfo]()
        self.calls_sub = Dict[String, Bool]()
        self.calls_func = Dict[String, Bool]()
        self.tmp_sub_calls = Dict[String, Bool]()
        self.builtins = parse_builtin_table()
        self.break_point = 0
        self.is_folder = False
        self.folder_name = String("")
        self.project_name = String("")

    def add_error(mut self, line: ELine, code: Int, message: String):
        self.diags.add(line.file_name, line.number, code, message)


# ============================================================================
# Вспомогательные: GetParamCount (Linker.cs:100-143), группы аргументов
# (Interpreter.cs:489-536), GetMethodLastIndex (MethodErrorParser.cs:482-549),
# ArrayIndexErrorParser.LastIndex
# ============================================================================


def param_count(words: List[EWord]) -> Int:
    """Число параметров/аргументов строки (Linker.GetParamCount)."""
    var comma = 0
    if len(words) > 0:
        var first = words[0].text.lower()
        if first == "sub" or first == "thread.run":
            comma = -1
    var bracket = 0
    for i in range(len(words)):
        var tok = words[i].token
        if tok == TOK_DOUBLEBRACKET and bracket == 0:
            comma = -1
            break
        if tok == TOK_BRACKETLEFT:
            bracket += 1
        elif tok == TOK_BRACKETRIGHT:
            bracket -= 1
        if tok == TOK_COMMA and bracket == 1:
            comma += 1
    if comma >= 0:
        return comma + 1
    return 0


def arg_groups(words: List[EWord]) -> List[List[EWord]]:
    """Группы слов аргументов вызова (Interpreter.GetParamCount, 489-536)."""
    var bracket = 0
    var groups = List[List[EWord]]()
    for i in range(len(words)):
        var w = words[i]
        var tok = w.token
        if tok == TOK_BRACKETLEFT:
            if bracket == 0:
                bracket += 1
                groups.append(List[EWord]())
                continue
            else:
                bracket += 1
        elif tok == TOK_BRACKETRIGHT:
            bracket -= 1
        if bracket > 0 and len(groups) > 0:
            if tok == TOK_COMMA:
                if bracket != 1:
                    groups[len(groups) - 1].append(w)
            else:
                groups[len(groups) - 1].append(w)
        if tok == TOK_COMMA and bracket == 1:
            groups.append(List[EWord]())
    return groups^


def method_last_index(
    mut ctx: Ctx, words: List[EWord], start: Int, name_lower: String, line: ELine
) raises -> Int:
    """Индекс конца встроенного вызова (MethodErrorParser.GetMethodLastIndex).

    PROPERTY/EVENT -> сам индекс слова (скобки запрещены); METHOD -> индекс
    закрывающей скобки. -1 = ошибка (диагностика добавлена).
    """
    if name_lower in ctx.builtins:
        var sig = ctx.builtins[name_lower]
        if sig.obj_type == OBJ_PROPERTY or sig.obj_type == OBJ_EVENT:
            if start + 1 < len(words):
                var nt = words[start + 1].token
                if nt == TOK_BRACKETLEFT or nt == TOK_DOUBLEBRACKET:
                    ctx.add_error(line, 1302, "( " + words[start].text + " )")
                    return -1
            return start
        if start + 1 >= len(words):
            ctx.add_error(line, 1303, "( " + words[start].text + " )")
            return -1
        var nt2 = words[start + 1].token
        if nt2 != TOK_BRACKETLEFT and nt2 != TOK_DOUBLEBRACKET:
            ctx.add_error(line, 1303, "( " + words[start].text + " )")
            return -1
    else:
        ctx.add_error(line, 1301, "( " + words[start].text + " )")
        return -1

    var bracket = 0
    var started = False
    for i in range(start, len(words)):
        var tok = words[i].token
        if tok == TOK_BRACKETLEFT:
            bracket += 1
            started = True
        elif tok == TOK_BRACKETRIGHT:
            bracket -= 1
        elif tok == TOK_DOUBLEBRACKET and bracket == 0:
            return i
        if started and bracket == 0:
            return i
    return -1


def array_index_last(words: List[EWord], start: Int) -> Int:
    """Индекс парной `]` (ArrayIndexErrorParser.LastIndex)."""
    var bracket = 0
    for i in range(start, len(words)):
        var tok = words[i].token
        if tok == TOK_BRACKETLEFTARRAY:
            bracket += 1
        elif tok == TOK_BRACKETRIGHTARRAY:
            bracket -= 1
        if bracket == 0:
            return i
    return len(words) - 1


# ============================================================================
# Регистрация переменных: суть VariableErrorParser.ParseInitVarError (60-674)
# ============================================================================


def register_var(
    mut ctx: Ctx,
    name: String,
    var_type: Int,
    array: Bool,
    line_number: Int,
    file_name: String,
):
    """Финальная вставка в Data.Project.Variables (VariableErrorParser.cs:641-666)."""
    if var_type == VT_NON:
        return
    var t = var_type
    if array:
        if t == VT_NUMBER or t == VT_NUMBER_ARRAY:
            t = VT_NUMBER_ARRAY
        elif t == VT_STRING or t == VT_STRING_ARRAY:
            t = VT_STRING_ARRAY
    ctx.variables.add(name, t, line_number, file_name)


def parse_init_var(
    mut ctx: Ctx,
    words: List[EWord],
    line: ELine,
    var_name: String,
    first_type: Int,
    start: Int,
    end: Int,
    array: Bool,
) raises -> Bool:
    """Вывод типа RHS и регистрация (VariableErrorParser.ParseInitVarError).

    Возвращает True при ошибке. Сохранены только управляющие ветки (ранние
    return, флаг bad_string); чисто валидирующие проверки опущены.
    """
    var type = first_type
    var math = True
    var plus = False
    var add_math = False
    var bad_string = False
    var skip_check = False

    var j = start
    while j < end:
        var old_type = type
        var word = words[j]
        var tok = word.token
        skip_check = False

        if tok == TOK_MATHOPERATOR:
            plus = False
            add_math = True
            if word.text == "+":
                plus = True
            if word.text == "-":
                if j == 2:
                    # Квирк C#: особый унарный минус распознаётся только при j == 2.
                    if len(words) >= 4 and words[3].token == TOK_NUMBER:
                        if not ctx.variables.contains(var_name):
                            if type == VT_NON:
                                type = VT_NUMBER
                            elif type != VT_NUMBER:
                                if first_type == VT_NON and type == VT_STRING:
                                    bad_string = True
                                    type = VT_NUMBER
                                if not bad_string:
                                    ctx.add_error(line, 1407, "")
                                    return True
                        else:
                            if ctx.variables.get_type(var_name) != VT_NUMBER:
                                ctx.add_error(line, 1407, "")
                                return True
                            return False
                    else:
                        ctx.add_error(line, 1415, "")
                        return True
                else:
                    if not math:
                        math = True
                    else:
                        if (
                            j + 1 < len(words)
                            and words[j + 1].token == TOK_NUMBER
                            or j + 1 < len(words)
                            and words[j + 1].token == TOK_VARIABLE
                            or j + 1 < len(words)
                            and words[j + 1].token == TOK_METHOD
                        ):
                            skip_check = True
                        else:
                            ctx.add_error(line, 1409, "( " + word.text + " )")
                            return True
            else:
                if not math:
                    math = True
                else:
                    ctx.add_error(line, 1408, "")
                    return True
        elif tok == TOK_NUMBER:
            if not math:
                ctx.add_error(line, 1416, "")
                return True
            else:
                math = False
            if type == VT_NON:
                type = VT_NUMBER
            elif type != VT_NUMBER:
                if first_type == VT_NON:
                    if type == VT_STRING:
                        bad_string = True
                        type = VT_NUMBER
                elif first_type == VT_STRING:
                    bad_string = True
                if not bad_string:
                    ctx.add_error(line, 1407, "")
                    return True
        elif tok == TOK_STRING:
            if not math:
                ctx.add_error(line, 1416, "")
                return True
            else:
                math = False
            if type == VT_NON:
                type = VT_STRING
            elif type != VT_STRING:
                if first_type == VT_NON:
                    if type == VT_NUMBER:
                        bad_string = True
                        type = VT_STRING
                if not bad_string:
                    ctx.add_error(line, 1407, "")
                    return True
        elif tok == TOK_VARIABLE:
            if not ctx.variables.contains(word.text):
                ctx.add_error(line, 1405, "( " + word.origin + " )")
                return True
            var v_type = ctx.variables.get_type(word.text)
            if v_type == VT_NUMBER:
                if not math:
                    ctx.add_error(line, 1416, "")
                    return True
                else:
                    math = False
                if type == VT_NON:
                    type = VT_NUMBER
                elif type != VT_NUMBER:
                    if first_type == VT_NON and type == VT_STRING:
                        bad_string = True
                        type = VT_NUMBER
                    elif first_type == VT_STRING:
                        bad_string = True
                    if not bad_string:
                        ctx.add_error(line, 1407, "")
                        return True
            elif v_type == VT_STRING:
                if not math:
                    ctx.add_error(line, 1416, "")
                    return True
                else:
                    math = False
                if type == VT_NON:
                    type = VT_STRING
                elif type != VT_STRING:
                    if first_type == VT_NON and type == VT_NUMBER:
                        bad_string = True
                        type = VT_STRING
                    if not bad_string:
                        ctx.add_error(line, 1407, "")
                        return True
            elif v_type == VT_NUMBER_ARRAY:
                if j + 1 < len(words) and words[j + 1].text == "[":
                    j = array_index_last(words, j + 1)
                    if not math:
                        ctx.add_error(line, 1416, "")
                        return True
                    else:
                        math = False
                    if type == VT_NON:
                        type = VT_NUMBER
                    elif type != VT_NUMBER:
                        if first_type == VT_NON and type == VT_STRING:
                            bad_string = True
                            type = VT_NUMBER
                        if not bad_string:
                            ctx.add_error(line, 1407, "")
                            return True
                else:
                    if array:
                        ctx.add_error(line, 1425, "")
                        return True
                    if add_math:
                        ctx.add_error(line, 1418, "")
                        return True
                    if type == VT_NON:
                        type = VT_NUMBER_ARRAY
                    elif type != VT_NUMBER_ARRAY:
                        ctx.add_error(line, 1407, "")
                        return True
            elif v_type == VT_STRING_ARRAY:
                if j + 1 < len(words) and words[j + 1].text == "[":
                    j = array_index_last(words, j + 1)
                    if not math:
                        ctx.add_error(line, 1416, "")
                        return True
                    else:
                        math = False
                    if type == VT_NON:
                        type = VT_STRING
                    elif type != VT_STRING:
                        if first_type == VT_NON and type == VT_NUMBER:
                            bad_string = True
                            type = VT_STRING
                        if not bad_string:
                            ctx.add_error(line, 1407, "")
                            return True
                else:
                    if array:
                        ctx.add_error(line, 1425, "")
                        return True
                    if add_math:
                        ctx.add_error(line, 1418, "")
                        return True
                    if type == VT_NON:
                        type = VT_STRING_ARRAY
                    elif type != VT_STRING_ARRAY:
                        ctx.add_error(line, 1407, "")
                        return True
        elif tok == TOK_METHOD:
            var name_lower = word.text.lower()
            var tmp_index = method_last_index(ctx, words, j, name_lower, line)
            if tmp_index == -1:
                return True
            var sig = ctx.builtins[name_lower]
            if sig.out_type == VT_NON:
                ctx.add_error(line, 1306, "")
                return True
            elif sig.out_type == VT_NUMBER:
                if not math:
                    ctx.add_error(line, 1416, "")
                    return True
                else:
                    math = False
                if type == VT_NON:
                    type = VT_NUMBER
                elif type != VT_NUMBER:
                    if first_type == VT_NON and type == VT_STRING:
                        bad_string = True
                        type = VT_NUMBER
                    elif first_type == VT_STRING:
                        bad_string = True
                    if not bad_string:
                        ctx.add_error(line, 1407, "")
                        return True
            elif sig.out_type == VT_NUMBER_ARRAY:
                if array:
                    ctx.add_error(line, 1425, "")
                    return True
                if add_math:
                    ctx.add_error(line, 1418, "")
                    return True
                if type == VT_NON:
                    type = VT_NUMBER_ARRAY
                elif type != VT_NUMBER_ARRAY:
                    ctx.add_error(line, 1407, "")
                    return True
            elif sig.out_type == VT_STRING:
                if not math:
                    ctx.add_error(line, 1416, "")
                    return True
                else:
                    math = False
                if type == VT_NON:
                    type = VT_STRING
                elif type != VT_STRING:
                    if first_type == VT_NON and type == VT_NUMBER:
                        bad_string = True
                        type = VT_STRING
                    if not bad_string:
                        ctx.add_error(line, 1407, "")
                        return True
            elif sig.out_type == VT_STRING_ARRAY:
                if array:
                    ctx.add_error(line, 1425, "")
                    return True
                if add_math:
                    ctx.add_error(line, 1418, "")
                    return True
                if type == VT_NON:
                    type = VT_STRING_ARRAY
                elif type != VT_STRING_ARRAY:
                    ctx.add_error(line, 1407, "")
                    return True
            elif sig.out_type == VT_ANY:
                if name_lower.find("f.call") != -1:
                    type = VT_ANY
            j = tmp_index
        elif (
            tok == TOK_BRACKETLEFT
            or tok == TOK_BRACKETRIGHT
            or tok == TOK_BRACKETLEFTARRAY
            or tok == TOK_BRACKETRIGHTARRAY
        ):
            pass
        else:
            ctx.add_error(line, 1401, word.text + " " + String(tok))
            return True

        if not skip_check and not plus and add_math:
            if old_type != VT_NON and (
                old_type == VT_NUMBER
                and type == VT_STRING
                or old_type == VT_STRING
                and type == VT_NUMBER
                or old_type == VT_STRING
                and type == VT_STRING
            ):
                ctx.add_error(line, 1417, "")
                return True
        j += 1

    if type != VT_NON:
        if bad_string and type == VT_NUMBER:
            type = VT_STRING
        register_var(ctx, var_name, type, array, line.number, line.file_name)
    else:
        ctx.add_error(line, 1401, "")
        return True
    return False


def parse_bracket_left_array(mut ctx: Ctx, line: ELine) raises -> Bool:
    """VARARRAYINIT: тип и регистрация (VariableErrorParser.ParseBracketLeftArray)."""
    var type = VT_NON
    if ctx.variables.contains(line.words[0].text):
        type = ctx.variables.get_type(line.words[0].text)
    if type == VT_NUMBER_ARRAY:
        type = VT_NUMBER
    elif type == VT_STRING_ARRAY:
        type = VT_STRING

    var last = array_index_last(line.words, 1)
    if (
        last + 1 < len(line.words)
        and line.words[last + 1].token == TOK_EQU
        and last + 2 < len(line.words)
    ):
        return parse_init_var(
            ctx, line.words, line, line.words[0].text, type, last + 2, len(line.words), True
        )
    ctx.add_error(line, 1401, "")
    return True


def for_register_var(mut ctx: Ctx, line: ELine) raises -> Bool:
    """FORINIT: регистрация счётчика (ForLineErrorParser.Start, часть с типом)."""
    if line.new_line.lower().find("to") == -1:
        ctx.add_error(line, 1901, "")
        return True
    if len(line.words) < 6:
        ctx.add_error(line, 1902, "")
        return True

    var type = VT_NON
    if ctx.variables.contains(line.words[1].text):
        if ctx.variables.get_type(line.words[1].text) != VT_NUMBER:
            ctx.add_error(line, 1904, "")
            return True
        type = VT_NUMBER

    var last_pos = 0
    for i in range(len(line.words)):
        var lw = line.words[i].text.lower()
        if lw == "to":
            last_pos = i
        elif lw == "step":
            break

    # ParseInitVarError(line, type, false, 3, lastPos, 6) — регистрирует Words[1].
    return parse_init_var(
        ctx, line.words, line, line.words[1].text, type, 3, last_pos, False
    )


# ============================================================================
# Развёртка x++ / x+= (VariableErrorParser.ParseDoubleMathError / ParseEquMathError)
# ============================================================================


def expand_double_math(mut line: ELine):
    """`x++`/`x--` -> OutLines `x = x +/- 1`."""
    line.out_lines.clear()
    var new_words = List[EWord]()
    new_words.append(line.words[0])
    new_words.append(EWord("=", "=", TOK_EQU))
    new_words.append(line.words[0])
    if line.words[1].text == "++":
        new_words.append(EWord("+", "+", TOK_MATHOPERATOR))
    else:
        new_words.append(EWord("-", "-", TOK_MATHOPERATOR))
    new_words.append(EWord("1", "1", TOK_NUMBER))
    var text = ejoin(new_words)
    line.out_lines.append(OEntry(new_words^, LT_VARINIT, text))


def expand_equ_math(mut line: ELine):
    """`x += e` -> OutLines `x = x OP e ...`."""
    line.out_lines.clear()
    var new_words = List[EWord]()
    new_words.append(line.words[0])
    new_words.append(EWord("=", "=", TOK_EQU))
    new_words.append(line.words[0])
    var op = line.words[1].text
    if op == "+=":
        new_words.append(EWord("+", "+", TOK_MATHOPERATOR))
    elif op == "-=":
        new_words.append(EWord("-", "-", TOK_MATHOPERATOR))
    elif op == "*=":
        new_words.append(EWord("*", "*", TOK_MATHOPERATOR))
    else:
        new_words.append(EWord("/", "/", TOK_MATHOPERATOR))
    for i in range(2, len(line.words)):
        new_words.append(line.words[i])
    var text = ejoin(new_words)
    line.out_lines.append(OEntry(new_words^, LT_VARINIT, text))


# ============================================================================
# Фазы линковки (Linker.cs)
# ============================================================================


def func_rename(mut lines: List[ELine], mut methods: List[ELine]):
    """FuncRename (Linker.cs:324-446) — mangled имена вызовов/заголовков.

    lines = MainText, methods = ModuleMethodsText (Linker.cs:398-445).
    """
    for k in range(len(lines)):
        ref line = lines[k]
        var t = line.line_type
        if t == LT_MODULEMETHODCALL:
            var renamed = False
            for i in range(len(line.words)):
                var w = line.words[i]
                if w.token == TOK_MODULEMETHOD:
                    w.text = (
                        "m_" + w.text.replace(".", "_") + "_" + String(param_count(line.words))
                    ).lower()
                    line.words[i] = w
                    renamed = True
            if renamed:
                line.new_line = ejoin(line.words)
        elif (
            t == LT_SUBCALL
            or t == LT_SUBINIT
            or t == LT_FUNCCALL
            or t == LT_METHODCALL
            or t == LT_FUNCINIT
        ):
            var renamed = False
            for i in range(len(line.words)):
                var tok = line.words[i].token
                if tok == TOK_SUBNAME or tok == TOK_FUNCNAME:
                    var w = line.words[i]
                    w.text = (
                        "f_" + w.text + "_" + String(param_count(line.words))
                    ).lower()
                    line.words[i] = w
                    renamed = True
            if renamed:
                line.new_line = ejoin(line.words)

    # --- методы модулей (Linker.cs:398-445) --------------------------------------
    for k in range(len(methods)):
        ref line = methods[k]
        var t = line.line_type
        if t == LT_MODULEMETHODCALL:
            var renamed = False
            for i in range(len(line.words)):
                var w = line.words[i]
                if w.token == TOK_MODULEMETHOD:
                    w.text = (
                        "m_" + w.text.replace(".", "_") + "_" + String(param_count(line.words))
                    ).lower()
                    line.words[i] = w
                    renamed = True
            if renamed:
                line.new_line = ejoin(line.words)
        elif t == LT_FUNCINIT:
            var renamed = False
            for i in range(len(line.words)):
                var w = line.words[i]
                if w.token == TOK_FUNCNAME:
                    # текст уже `<Module.Name>_<имя>` (переименование до линковки)
                    w.text = (
                        "m_" + w.text + "_" + String(param_count(line.words))
                    ).lower()
                    line.words[i] = w
                    renamed = True
            if renamed:
                line.new_line = ejoin(line.words)
        elif t == LT_METHODCALL:
            var renamed = False
            for i in range(len(line.words)):
                var tok = line.words[i].token
                if tok == TOK_SUBNAME:
                    var w = line.words[i]
                    w.text = (
                        "f_" + w.text + "_" + String(param_count(line.words))
                    ).lower()
                    line.words[i] = w
                    renamed = True
            if renamed:
                line.new_line = ejoin(line.words)


def vars_and_labels_rename(
    mut lines: List[ELine],
    mut methods: List[ELine],
    mut used: UsedProps,
    mut ctx: Ctx,
) raises:
    """VarsAndLabelsRename (Linker.cs:448-622) — gv_/lv_/gl_/ll_/pr_ + счётчики.

    lines = MainText (467-541), methods = ModuleMethodsText (544-621). Счётчики
    lv_/ll_ и флаг func ОБЩИЕ для обоих проходов; в проходе модулей FUNCINIT
    инкрементирует только lv-счётчик (квирк cs:549-553), @-глобалы в модулях ->
    2009, переменные/метки вне методов -> 2008.
    """
    var lv_n = 0
    var ll_n = 0
    var func = False

    # --- главная программа (Linker.cs:467-541) ---------------------------------
    for k in range(len(lines)):
        ref line = lines[k]
        if line.line_type == LT_FUNCINIT:
            func = True
            lv_n += 1
            ll_n += 1
        elif (
            line.line_type == LT_ONEKEYWORD
            and ejoin(line.words).lower().strip() == "endfunction"
        ):
            func = False
            continue

        for i in range(len(line.words)):
            var w = line.words[i]
            if w.token == TOK_VARIABLE:
                if not func:
                    w.text = ("gv_" + w.text).lower().replace("@", "")
                else:
                    if w.text.find("@") == -1:
                        w.text = ("lv_" + w.text + "_" + String(lv_n)).lower()
                    else:
                        w.text = ("gv_" + w.text).lower().replace("@", "")
                line.words[i] = w
            elif w.token == TOK_LABEL or w.token == TOK_LABELNAME:
                if not func:
                    w.text = ("gl_" + w.text).lower().replace("@", "")
                else:
                    if w.text.find("@") == -1:
                        w.text = ("ll_" + w.text + "_" + String(ll_n)).lower()
                    else:
                        # Квирк Linker.cs:518 — LABELNAME с @ получает gv_-префикс.
                        w.text = ("gv_" + w.text).lower().replace("@", "")
                if w.token == TOK_LABEL:
                    w.text = w.text.replace(":", "") + ":"
                line.words[i] = w
            elif w.token == TOK_MODULEPROPERTY:
                # Linker.cs:528-537: свойство -> pr_<module>_<prop>, токен VARIABLE
                var name = w.text.lower().replace(".", "_")
                used.add(name, line.number, line.file_name)
                w.token = TOK_VARIABLE
                w.text = "pr_" + name
                line.words[i] = w
        line.new_line = ejoin(line.words)

    # --- методы модулей (Linker.cs:544-621) --------------------------------------
    for k in range(len(methods)):
        ref line = methods[k]
        if line.line_type == LT_FUNCINIT:
            func = True
            lv_n += 1  # ll_n НЕ инкрементируется (квирк cs:549-553)
        elif (
            line.line_type == LT_ONEKEYWORD
            and ejoin(line.words).lower().strip() == "endfunction"
        ):
            func = False
            continue

        for i in range(len(line.words)):
            var w = line.words[i]
            if w.token == TOK_VARIABLE:
                if w.text.find("@") != -1:
                    # Ошибка: в модулях не может быть глобальных переменных (cs:564-569)
                    ctx.add_error(line, 2009, "")
                    return
                if not func:
                    # Ошибка: вне методов модулей переменных нет (cs:571-576)
                    ctx.add_error(line, 2008, "")
                    return
                w.text = ("lv_" + w.text + "_" + String(lv_n)).lower()
                line.words[i] = w
            elif w.token == TOK_LABEL or w.token == TOK_LABELNAME:
                if w.text.find("@") != -1:
                    # Квирк: для меток с @ здесь тоже 2008, а не 2010 (cs:584-589)
                    ctx.add_error(line, 2008, "")
                    return
                if not func:
                    ctx.add_error(line, 2008, "")
                    return
                w.text = ("ll_" + w.text + "_" + String(ll_n)).lower()
                if w.token == TOK_LABEL:
                    w.text = w.text.replace(":", "") + ":"
                line.words[i] = w
            elif w.token == TOK_MODULEPROPERTY:
                var name = w.text.lower().replace(".", "_")
                used.add(name, line.number, line.file_name)
                w.token = TOK_VARIABLE
                w.text = "pr_" + name
                line.words[i] = w
        line.new_line = ejoin(line.words)


def remove_main_func(
    lines: List[ELine], mut rest: List[ELine], mut funcs: List[ELine]
):
    """RemoveMainFunc (Linker.cs:624-660): FUNCINIT..endfunction -> отдельный лист."""
    var func = False
    for k in range(len(lines)):
        ref line = lines[k]
        if line.line_type == LT_FUNCINIT:
            func = True
        elif (
            line.line_type == LT_ONEKEYWORD
            and ejoin(line.words).lower().strip() == "endfunction"
        ):
            func = False
            funcs.append(line.copy())
            continue
        if func:
            funcs.append(line.copy())
        else:
            rest.append(line.copy())


def remove_main_sub(lines: List[ELine], mut rest: List[ELine], mut subs: List[ELine]):
    """RemoveMainSub (Linker.cs:662-698): SUBINIT..endsub -> отдельный лист."""
    var sub = False
    for k in range(len(lines)):
        ref line = lines[k]
        if line.line_type == LT_SUBINIT:
            sub = True
        elif (
            line.line_type == LT_ONEKEYWORD
            and ejoin(line.words).lower().strip() == "endsub"
        ):
            sub = False
            subs.append(line.copy())
            continue
        if sub:
            subs.append(line.copy())
        else:
            rest.append(line.copy())


def parse_private(
    pp: Preproc, main_text: List[ELine], mut ctx: Ctx
) raises:
    """ParsePrivate (Linker.cs:860-960) — доступ к приватным членам модулей.

    MainText: приватное свойство -> 2017, приватный метод -> 2018 (несуществующий
    модуль молча пропускается). Тела модулей: обращение к ЧУЖИМ приватным членам
    -> 2017/2018; к своим — разрешено. Слова свойств/методов СВОЕГО модуля в телах
    уже переименованы без точек (rename до линковки) -> GetModuleName даёт "" ->
    молча пропускаются (квирк).
    """
    for k in range(len(main_text)):
        ref line = main_text[k]
        for i in range(len(line.words)):
            var w = line.words[i]
            if w.token == TOK_MODULEPROPERTY:
                var mod_name = module_name_of(w.text).lower()
                if not pp.module_exists(mod_name):
                    continue
                var key = mod_name + "_" + method_name_of(w.text).lower()
                if pp.module_has_property(mod_name, key):
                    var pr = pp.module_property(mod_name, key)
                    if pr.is_private:
                        ctx.add_error(line, 2017, w.origin)
                        return
            elif w.token == TOK_MODULEMETHOD:
                var mod_name = module_name_of(w.text).lower()
                if not pp.module_exists(mod_name):
                    continue
                var key = (
                    method_name_of(w.text).lower()
                    + "_"
                    + String(param_count(line.words))
                )
                if pp.module_method_exists(mod_name, key):
                    var mm = pp.module_method(mod_name, key)
                    if mm.is_private:
                        ctx.add_error(line, 2018, w.origin)
                        return

    for m in range(len(pp.mod_keys)):
        var tmp_name = pp.mod_keys[m]
        var sp = pp.mod_span[tmp_name]
        for idx in range(sp[0], sp[0] + sp[1]):
            var ln = pp.module_line(idx)
            for wi in range(len(ln.words)):
                var tok = ln.words[wi].token
                if tok == TOK_MODULEPROPERTY:
                    var mod_name = module_name_of(ln.words[wi].text).lower()
                    if not pp.module_exists(mod_name) or mod_name == tmp_name:
                        continue
                    var key = mod_name + "_" + method_name_of(ln.words[wi].text).lower()
                    if pp.module_has_property(mod_name, key):
                        var pr = pp.module_property(mod_name, key)
                        if pr.is_private:
                            ctx.diags.add(
                                pp.module_file(tmp_name), ln.line_number, 2017, ln.words[wi].origin_text
                            )
                            return
                elif tok == TOK_MODULEMETHOD:
                    var mod_name = module_name_of(ln.words[wi].text).lower()
                    if not pp.module_exists(mod_name) or mod_name == tmp_name:
                        continue
                    var key = (
                        method_name_of(ln.words[wi].text).lower()
                        + "_"
                        + String(param_count_linker(ln.words))
                    )
                    if pp.module_method_exists(mod_name, key):
                        var mm = pp.module_method(mod_name, key)
                        if mm.is_private:
                            ctx.diags.add(
                                pp.module_file(tmp_name), ln.line_number, 2018, ln.words[wi].origin_text
                            )
                            return


def create_calling_property_lines(
    pp: Preproc, used: UsedProps, mut ctx: Ctx, mut prop_flat: List[FlatItem]
) raises:
    """CreateCallingPropertyLines (Linker.cs:788-858) — init-строки pr_* свойств.

    Для каждого использованного свойства ищется объявление в реестрах всех модулей
    (Linker.cs:793-802); не найдено -> 2020 (855). Строка инициализации получает
    Number/FileName строки объявления; переменная pr_* регистрируется с
    Init=true и Line=null (в OtherVarsAddToMain пропускается).
    """
    for u in range(len(used.order)):
        var key = used.order[u]
        var found = False
        for m in range(len(pp.mod_keys)):
            var mk = pp.mod_keys[m]
            if not pp.module_has_property(mk, key):
                continue
            var decl = pp.module_property(mk, key)
            var decl_line = pp.module_line(decl.decl_idx)
            var name = "pr_" + decl_line.words[1].text.lower()

            var words = List[EWord]()
            words.append(
                EWord(name, decl_line.words[1].origin_text, TOK_VARIABLE)
            )
            var lt = LT_VARINIT
            var vt = VT_NUMBER
            var w0 = decl_line.words[0].text.lower()
            if w0 == "number":
                words.append(EWord("=", "=", TOK_EQU))
                words.append(EWord("0", "0", TOK_NUMBER))
            elif w0 == "number[]":
                lt = LT_VARARRAYINIT
                vt = VT_NUMBER_ARRAY
                words.append(EWord("[", "[", TOK_BRACKETLEFTARRAY))
                words.append(EWord("0", "0", TOK_NUMBER))
                words.append(EWord("]", "]", TOK_BRACKETRIGHTARRAY))
                words.append(EWord("=", "=", TOK_EQU))
                words.append(EWord("0", "0", TOK_NUMBER))
            elif w0 == "string":
                vt = VT_STRING
                words.append(EWord("=", "=", TOK_EQU))
                words.append(EWord("\"\"", "\"\"", TOK_STRING))
            elif w0 == "string[]":
                lt = LT_VARARRAYINIT
                vt = VT_STRING_ARRAY
                words.append(EWord("[", "[", TOK_BRACKETLEFTARRAY))
                words.append(EWord("0", "0", TOK_NUMBER))
                words.append(EWord("]", "]", TOK_BRACKETRIGHTARRAY))
                words.append(EWord("=", "=", TOK_EQU))
                words.append(EWord("\"\"", "\"\"", TOK_STRING))

            var text = ejoin(words)
            prop_flat.append(
                FlatItem(words^, lt, decl_line.line_number, text, List[String]())
            )
            # Variable("pr_" + key) { Init = true, Line = null } (cs:850-851)
            ctx.variables.add(name, vt, decl_line.line_number, pp.module_file(mk), True)
            found = True
            break
        if not found:
            var info = used.info[key]
            ctx.diags.add(info.file_name, info.line_number, 2020, key)


# ============================================================================
# Фазы Interpreter (Interpreter.cs)
# ============================================================================


def parse_func_init_lines(mut ctx: Ctx, mut funcs: List[ELine]):
    """ParseFuncInitLine (Interpreter.cs:125-174) + ключи параметров
    (FunctionsInitErrorParser.FuncInitLineParse, 16-384)."""
    for k in range(len(funcs)):
        ref line = funcs[k]
        if line.line_type == LT_FUNCINIT:
            # Параметры: конечный автомат по словам после `(`.
            var func_info = FunctionInfo(line.words[1].text, List[ParamSig]())
            if line.words[2].token != TOK_DOUBLEBRACKET:
                var vars_state = 0
                var is_input = False
                var tmp_type = VT_NON
                for i in range(2, len(line.words)):
                    var w = line.words[i]
                    if w.token == TOK_KEYWORD:
                        var lw = w.text.lower()
                        if (lw == "in" or lw == "out") and vars_state == 0:
                            vars_state = 1
                            is_input = lw == "in"
                            tmp_type = VT_NON
                        elif (
                            lw == "number"
                            or lw == "number[]"
                            or lw == "string"
                            or lw == "string[]"
                        ) and vars_state == 1:
                            vars_state = 2
                            if lw == "number":
                                tmp_type = VT_NUMBER
                            elif lw == "number[]":
                                tmp_type = VT_NUMBER_ARRAY
                            elif lw == "string":
                                tmp_type = VT_STRING
                            else:
                                tmp_type = VT_STRING_ARRAY
                    elif w.token == TOK_VARIABLE and vars_state == 2:
                        vars_state = 3
                        func_info.params.append(
                            ParamSig(
                                w.text.lower(),
                                tmp_type,
                                PT_INPUT if is_input else PT_OUTPUT,
                            )
                        )
                    elif w.token == TOK_COMMA and vars_state == 3:
                        vars_state = 0
            var key = func_info.name
            ctx.functions[key] = func_info^

            var new_words = List[EWord]()
            new_words.append(EWord("Sub", line.words[0].origin, line.words[0].token))
            new_words.append(line.words[1])
            var text = ejoin(new_words)
            line.out_lines.append(OEntry(new_words^, LT_SUBINIT, text))
        elif (
            line.line_type == LT_ONEKEYWORD
            and line.words[0].text.lower() == "endfunction"
        ):
            var new_words = List[EWord]()
            new_words.append(EWord("EndSub", line.words[0].origin, line.words[0].token))
            var text = ejoin(new_words)
            line.out_lines.append(OEntry(new_words^, LT_ONEKEYWORD, text))


def parse_calls_list(mut ctx: Ctx, lines: List[ELine]):
    """ParseFirstCall (Interpreter.cs:676-754) — только сбор имён вызовов."""
    for k in range(len(lines)):
        var t = lines[k].line_type
        if t == LT_SUBCALL or t == LT_MODULEMETHODCALL:
            if len(lines[k].words) >= 2:
                var name = lines[k].words[0].text.lower()
                ctx.calls_sub[name] = True
        elif t == LT_METHODCALL:
            if len(lines[k].words) >= 3 and lines[k].words[0].text.lower() == "thread.run":
                var name = lines[k].words[2].text.lower()
                ctx.calls_sub[name] = True


def parse_all_calls(
    mut ctx: Ctx,
    main: List[ELine],
    subs: List[ELine],
    funcs: List[ELine],
    methods: List[ELine],
):
    """ParseAllCalls (Interpreter.cs:654-677): main -> subs -> funcs -> методы модулей."""
    parse_calls_list(ctx, main)
    parse_calls_list(ctx, subs)
    parse_calls_list(ctx, funcs)
    parse_calls_list(ctx, methods)


def parse_one_call(mut ctx: Ctx, mut lines: List[ELine]) raises:
    """ParseOneCall (Interpreter.cs:200-343) — развёртка вызовов функций."""
    for k in range(len(lines)):
        ref line = lines[k]
        var t = line.line_type
        if t != LT_SUBCALL and t != LT_MODULEMETHODCALL:
            continue
        if len(line.words) < 2:
            continue
        var name = line.words[0].text.lower()
        if not (name in ctx.functions):
            continue
        var func = ctx.functions[name].copy()
        var args = arg_groups(line.words)
        if not (len(func.params) == len(args) and len(func.params) > 0):
            continue

        var body = False
        var arg_i = 0
        for p in range(len(func.params)):
            var param = func.params[p]
            if param.param_type == PT_INPUT:
                if not ctx.temp_vars.contains(param.key):
                    ctx.temp_vars.add(
                        param.key, param.var_type, line.number, line.file_name
                    )
                var new_words = List[EWord]()
                new_words.append(EWord(param.key, param.key, TOK_VARIABLE))
                new_words.append(EWord("=", "=", TOK_EQU))
                for g in range(len(args[arg_i])):
                    new_words.append(args[arg_i][g])
                arg_i += 1
                var text = ejoin(new_words)
                line.out_lines.append(OEntry(new_words^, LT_VARINIT, text))
            else:
                if not body:
                    var new_words = List[EWord]()
                    var fw = line.words[0]
                    if fw.token == TOK_MODULEMETHOD or fw.token == TOK_FUNCNAME:
                        fw.token = TOK_SUBNAME
                    new_words.append(fw)
                    new_words.append(EWord("()", "()", TOK_DOUBLEBRACKET))
                    var text = ejoin(new_words)
                    line.out_lines.append(OEntry(new_words^, LT_SUBCALL, text))
                    body = True
                if len(args[arg_i]) == 1:
                    if args[arg_i][0].token != TOK_VARIABLE:
                        ctx.add_error(line, 1405, "( " + line.old_line + " )")
                        return
                    var new_words = List[EWord]()
                    new_words.append(args[arg_i][0])
                    new_words.append(EWord("=", "=", TOK_EQU))
                    new_words.append(EWord(param.key, param.key, TOK_VARIABLE))
                    if not ctx.temp_vars.contains(param.key):
                        ctx.temp_vars.add(
                            param.key, param.var_type, line.number, line.file_name
                        )
                    # out-цель регистрируется в Data.Project.Variables (278-281)
                    ctx.variables.add(
                        args[arg_i][0].text.lower(),
                        param.var_type,
                        line.number,
                        line.file_name,
                    )
                    var text = ejoin(new_words)
                    line.out_lines.append(OEntry(new_words^, LT_VARINIT, text))
                elif len(args[arg_i]) > 1:
                    if (
                        args[arg_i][0].token == TOK_VARIABLE
                        and String(args[arg_i][0].text.lower().strip()) != "gv_"
                        and args[arg_i][1].token == TOK_BRACKETLEFTARRAY
                        and args[arg_i][len(args[arg_i]) - 1].token
                        == TOK_BRACKETRIGHTARRAY
                    ):
                        var new_words = List[EWord]()
                        for g in range(len(args[arg_i])):
                            new_words.append(args[arg_i][g])
                        new_words.append(EWord("=", "=", TOK_EQU))
                        new_words.append(EWord(param.key, param.key, TOK_VARIABLE))
                        if not ctx.temp_vars.contains(param.key):
                            ctx.temp_vars.add(
                                param.key, param.var_type, line.number, line.file_name
                            )
                        var text = ejoin(new_words)
                        line.out_lines.append(
                            OEntry(new_words^, LT_VARARRAYINIT, text)
                        )
                    else:
                        ctx.add_error(line, 1405, "( " + line.old_line + " )")
                        return
                arg_i += 1
        if not body:
            var new_words = List[EWord]()
            var fw = line.words[0]
            if fw.token == TOK_MODULEMETHOD or fw.token == TOK_FUNCNAME:
                fw.token = TOK_SUBNAME
            new_words.append(fw)
            new_words.append(EWord("()", "()", TOK_DOUBLEBRACKET))
            var text = ejoin(new_words)
            line.out_lines.append(OEntry(new_words^, LT_SUBCALL, text))
            body = True


def init_line_text(name: String, var_type: Int) -> String:
    """Текст init-строки (Interpreter.cs:448-487 / 606-652)."""
    var words = List[EWord]()
    words.append(EWord(name, name, TOK_VARIABLE))
    if var_type == VT_NUMBER:
        words.append(EWord("=", "=", TOK_EQU))
        words.append(EWord("0", "0", TOK_NUMBER))
    elif var_type == VT_NUMBER_ARRAY:
        words.append(EWord("[", "[", TOK_BRACKETLEFTARRAY))
        words.append(EWord("0", "0", TOK_NUMBER))
        words.append(EWord("]", "]", TOK_BRACKETRIGHTARRAY))
        words.append(EWord("=", "=", TOK_EQU))
        words.append(EWord("0", "0", TOK_NUMBER))
    elif var_type == VT_STRING:
        words.append(EWord("=", "=", TOK_EQU))
        words.append(EWord("\"\"", "\"\"", TOK_STRING))
    elif var_type == VT_STRING_ARRAY:
        words.append(EWord("[", "[", TOK_BRACKETLEFTARRAY))
        words.append(EWord("0", "0", TOK_NUMBER))
        words.append(EWord("]", "]", TOK_BRACKETRIGHTARRAY))
        words.append(EWord("=", "=", TOK_EQU))
        words.append(EWord("\"\"", "\"\"", TOK_STRING))
    else:
        return String("")
    return ejoin(words)


def handle_var_line(mut ctx: Ctx, mut line: ELine) raises -> Int:
    """Одна строка SubVarsInit (Interpreter.cs:538-604).

    Возврат: 0 — строка обработана; 1 — ошибка (диагностика добавлена, стоп);
    2 — строка является SUBCALL (нужна рекурсия в тело sub).
    """
    var t = line.line_type
    if t == LT_VARINIT:
        if parse_init_var(
            ctx, line.words, line, line.words[0].text, VT_NON, 2, len(line.words), False
        ):
            return 1
    elif t == LT_VARARRAYINIT:
        if parse_bracket_left_array(ctx, line):
            return 1
    elif t == LT_VARDOUBLEMATH:
        expand_double_math(line)
    elif t == LT_VAREQUMATH:
        expand_equ_math(line)
    elif t == LT_FORINIT:
        if for_register_var(ctx, line):
            return 1
    elif t == LT_SUBCALL:
        return 2
    return 0


def find_sub_body(subs: List[ELine], name: String) -> Tuple[Int, Int]:
    """Диапазон тела sub [SUBINIT, endsub) в MainSubText (Interpreter.cs:578-598).

    (-1, -1) — sub с таким именем нет.
    """
    var body = False
    var body_start = -1
    for s in range(len(subs)):
        if subs[s].line_type == LT_SUBINIT:
            if subs[s].words[1].text.lower() == name:
                body = True
                body_start = s
        elif (
            subs[s].line_type == LT_ONEKEYWORD
            and subs[s].words[0].text.lower() == "endsub"
            and body
        ):
            return (body_start, s)
    return (-1, -1)


def build_sub_order(
    subs: List[ELine],
    start: Int,
    stop: Int,
    mut order: List[Tuple[Int, Int]],
    mut visited: Dict[String, Bool],
):
    """Порядок обработки строк тела sub: глубина-first, как рекурсия SubVarsInit.

    order — пары (kind, index): kind 1 = строка subs[index]; SUBCALL-строки
    раскрываются на месте в порядке первого вызова.
    """
    for k in range(start, stop):
        var t = subs[k].line_type
        if t == LT_SUBCALL and len(subs[k].words) >= 1:
            var name = subs[k].words[0].text.lower()
            if not (name in visited):
                visited[name] = True
                var rng = find_sub_body(subs, name)
                if rng[0] != -1:
                    build_sub_order(subs, rng[0], rng[1], order, visited)
        else:
            order.append((1, k))


def process_var_lines(
    mut ctx: Ctx,
    mut lines: List[ELine],
    mut subs: List[ELine],
    start: Int,
    stop: Int,
) raises:
    """SubVarsInit (Interpreter.cs:538-604) — регистрация переменных main и
    рекурсивно вызванных sub (в порядке первого вызова, глубина-first)."""
    var order = List[Tuple[Int, Int]]()
    var visited = Dict[String, Bool]()
    for k in range(start, stop):
        var t = lines[k].line_type
        if t == LT_SUBCALL and len(lines[k].words) >= 1:
            var name = lines[k].words[0].text.lower()
            if not (name in visited):
                visited[name] = True
                var rng = find_sub_body(subs, name)
                if rng[0] != -1:
                    build_sub_order(subs, rng[0], rng[1], order, visited)
        else:
            order.append((0, k))

    for i in range(len(order)):
        var kind = order[i][0]
        var idx = order[i][1]
        if kind == 0:
            var r = handle_var_line(ctx, lines[idx])
            if r == 1:
                return
        else:
            var r2 = handle_var_line(ctx, subs[idx])
            if r2 == 1:
                return


def other_vars_add_to_main(mut ctx: Ctx, mut var_init: List[String]) raises:
    """OtherVarsAddToMain (Interpreter.cs:606-652) — init-строки остальных переменных."""
    for i in range(len(ctx.variables.order)):
        var name = ctx.variables.order[i]
        var info = ctx.variables.info[name]
        # Свойства pr_* (Line == null в C#) пропускаются (Interpreter.cs:613-616).
        if info.skip_init:
            continue
        var text = init_line_text(name, info.var_type)
        if text != "":
            var_init.append(text)


def rewrite_out_lines(
    flat: List[FlatItem], calls_sub: Dict[String, Bool], calls_func: Dict[String, Bool]
) -> List[FlatItem]:
    """RewriteOutLines (Interpreter.cs:756-788) — удаление неиспользуемых SUB."""
    var result = List[FlatItem]()
    var write = True
    for i in range(len(flat)):
        if flat[i].line_type == LT_SUBINIT and len(flat[i].words) > 1:
            var name = flat[i].words[1].text.lower()
            if not (name in calls_sub) and not (name in calls_func):
                write = False
        elif (
            flat[i].line_type == LT_ONEKEYWORD
            and len(flat[i].words) > 0
            and flat[i].words[0].text.lower() == "endsub"
        ):
            if not write:
                write = True
                continue
        if write:
            result.append(flat[i].copy())
    return result^


# ============================================================================
# break/continue/return (LineErrorParser.cs:131-271)
# ============================================================================


def parse_brake_and_continue(
    mut flat: List[FlatItem], mut ctx: Ctx, start: Int, stop: Int, jump_word: String
):
    var flag_loop = 0
    var flag_label = False
    var label = String("")

    for i in range(start + 1, stop):
        if flat[i].line_type == LT_FORINIT or flat[i].line_type == LT_WHILEINIT:
            flag_loop += 1
        if flag_loop == 0 or jump_word == "return":
            if (
                flat[i].line_type == LT_ONEKEYWORD
                and len(flat[i].words) > 0
                and flat[i].words[0].text.lower() == jump_word
            ):
                if not flag_label:
                    ctx.break_point += 1
                    label = jump_word + "_" + String(ctx.break_point)
                    flag_label = True
                flat[i].out.append("Goto " + label)
        if (
            flat[i].line_type == LT_ONEKEYWORD
            and len(flat[i].words) > 0
            and (
                flat[i].words[0].text.lower() == "endfor"
                or flat[i].words[0].text.lower() == "endwhile"
            )
        ):
            flag_loop -= 1

    if flag_label:
        if jump_word == "continue" or jump_word == "return":
            flat[stop].out.append(label + ":")
            flat[stop].out.append(flat[stop].new_line)
        elif jump_word == "break":
            if len(flat[stop].out) == 0:
                flat[stop].out.append(flat[stop].new_line)
            flat[stop].out.append(label + ":")


def parse_jump_operators(
    mut flat: List[FlatItem], mut ctx: Ctx, ltype: Int, last_word: String
):
    """ParseJumpOperators (LineErrorParser.cs:131-203) — по одному типу блоков."""
    for i in range(len(flat)):
        if flat[i].line_type != ltype:
            continue
        var flag_loop = 1
        var j = i + 1
        while j < len(flat):
            if flat[j].line_type == ltype:
                flag_loop += 1
            elif (
                flat[j].line_type == LT_ONEKEYWORD
                and len(flat[j].words) > 0
                and flat[j].words[0].text.lower() == last_word
            ):
                if flag_loop == 1:
                    if ltype == LT_SUBINIT:
                        parse_brake_and_continue(flat, ctx, i, j, "return")
                    else:
                        parse_brake_and_continue(flat, ctx, i, j, "continue")
                        parse_brake_and_continue(flat, ctx, i, j, "break")
                    break
                flag_loop -= 1
            j += 1


# ============================================================================
# Медиа-пути (MediaBuilder.cs:14-344, вызов из MethodErrorParser.cs:412-422)
# ============================================================================


def media_add_prefix(ctx: Ctx, kind_files: Bool, name: String) -> String:
    """Префикс медиа-файла: prjs -> "<Проект>/Media/" (или /Files/), sd ->
    "SD_Card/<Проект>/Media/" (AddPathMedia/AddPathFile, 201-344)."""
    var sub = "/Media/"
    if kind_files:
        sub = "/Files/"
    var f = ctx.folder_name.upper()
    if f == "PRJS":
        if ctx.project_name != "":
            return ctx.project_name + sub
    elif f == "SD":
        if ctx.project_name != "":
            return "SD_Card/" + ctx.project_name + sub
    return String("")


def media_rewrite_line(ctx: Ctx, mut item: FlatItem) -> Bool:
    """ParseMedia (MediaBuilder.cs:14-124) для одной строки-вызова метода.

    Возвращает True, если строка переписана. Строка после подмены полностью
    переразбирается лексером (LineBuilder.GetWords), как в C#.
    """
    var text = item.new_line
    var lower = text.lower()

    var pattern = String("")
    var is_table = False
    var is_files = False
    if lower.find("lcd.bmpfile") != -1:
        pattern = "lcd.bmpfile"
    elif lower.find("speaker.play") != -1:
        pattern = "speaker.play"
    elif lower.find("ev3file.openwrite") != -1:
        pattern = "ev3file.openwrite"
        is_files = True
    elif lower.find("ev3file.openappend") != -1:
        pattern = "ev3file.openappend"
        is_files = True
    elif lower.find("ev3file.openread") != -1:
        pattern = "ev3file.openread"
        is_files = True
    elif lower.find("ev3file.tablelookup") != -1:
        pattern = "ev3file.tablelookup"
        is_files = True
        is_table = True
    else:
        return False

    # Квирк: метод должен идти ДО апострофа-комментария (в каноническом тексте
    # комментариев уже нет, проверка сохранена для соответствия).
    var q1 = text.find('"')
    if q1 == -1:
        return False
    var q2 = text.rfind('"')
    if q2 == -1 or q2 <= q1:
        return False

    var start = q1 + 1
    var end = q2
    var name = String(text[byte=start:end])
    var play = String(text[byte=0:q1])
    var prefix = media_add_prefix(ctx, is_files, name)

    var new_text = String("")
    if is_table:
        var other = String(text[byte=end + 1 : text.byte_length()])
        new_text = play + '"' + prefix + name + '"' + other + ")"
    else:
        new_text = play + '"' + prefix + name + '")'

    var bl = build_line(new_text, item.number)
    var words = List[EWord]()
    for i in range(len(bl.words)):
        var w = bl.words[i].copy()
        words.append(EWord(w.text, w.origin_text, w.token))
    item.words = words^
    item.new_line = ejoin(item.words)
    return True


def media_pass(mut flat: List[FlatItem], ctx: Ctx):
    """Переписывание медиа-строк (ветка METHODCALL финального прохода
    LineErrorParser -> MethodErrorParser -> MediaBuilder.ParseMedia)."""
    if not ctx.is_folder:
        return
    for i in range(len(flat)):
        if flat[i].line_type == LT_METHODCALL:
            _ = media_rewrite_line(ctx, flat[i])


# ============================================================================
# Сборка плоского списка и вывод (Interpreter.cs:345-446, Builder.cs:486-506)
# ============================================================================


def emit_line(mut flat: List[FlatItem], line: ELine):
    """Строка -> элементы плоского списка (её OutLines либо она сама)."""
    if len(line.out_lines) > 0:
        for e in range(len(line.out_lines)):
            flat.append(
                FlatItem(
                    line.out_lines[e].words.copy(),
                    line.out_lines[e].line_type,
                    line.number,
                    line.out_lines[e].text,
                    List[String](),
                )
            )
    else:
        flat.append(
            FlatItem(line.words.copy(), line.line_type, line.number, line.new_line, List[String]())
        )


def final_var_pass(mut lines: List[FlatItem]):
    """Повторный VariableErrorParser.Start (Interpreter.cs:91): тела Function —
    развёртка x++/x+= для строк, которых SubVarsInit не видел."""
    for i in range(len(lines)):
        var t = lines[i].line_type
        if (t == LT_VARDOUBLEMATH or t == LT_VAREQUMATH) and len(lines[i].out) == 0:
            var tmp = ELine(
                lines[i].words.copy(),
                t,
                0,
                String(""),
                String(""),
                String(""),
                List[OEntry](),
            )
            if t == LT_VARDOUBLEMATH:
                expand_double_math(tmp)
            else:
                expand_equ_math(tmp)
            var texts = List[String]()
            for e in range(len(tmp.out_lines)):
                texts.append(tmp.out_lines[e].text)
            lines[i].out = texts^


# ============================================================================
# Конвейер команды expand
# ============================================================================


def run_expansion(path: String, outdir: String, mut ctx: Ctx) raises -> List[String]:
    """Полный конвейер: исходник -> строки развёртки (диагностики в ctx.diags)."""
    var raw = read_lines(path)
    var file_name = path

    # --- разметка (Program ctor, Program.cs:29-35) ----------------------------
    var all_lines = List[Line]()
    for i in range(len(raw)):
        var bl = build_line(raw[i], i + 1)
        all_lines.append(bl^)

    # --- FirstFindFiles (Preprocessor.cs:48-81): include/import ----------------
    # ModuleLibPath = arg2 + separator (Builder.cs:75; пустой arg2 -> "")
    var lib_path = String("")
    if outdir != "":
        lib_path = outdir + "/"
    var pp = Preproc(dir_name(path) + "/", lib_path)
    first_find_files(pp, all_lines, file_name)
    for i in range(len(pp.diags.items)):
        ctx.diags.items.append(pp.diags.items[i].copy())
    if ctx.diags.has_errors():
        return List[String]()

    # --- folder-директива (Preprocessor.cs:71-79) --------------------------------
    for i in range(len(all_lines)):
        if all_lines[i].line_type == LT_FOLDER and len(all_lines[i].words) >= 3:
            # FolderErrorParser.Start на валидном корпусе успешен -> IsFolder = true.
            ctx.is_folder = True
            ctx.folder_name = all_lines[i].words[1].origin_text.replace('"', "")
            ctx.project_name = all_lines[i].words[2].origin_text.replace('"', "")

    # --- AddIncludesToMain (Linker.cs:283-308) ------------------------------------
    var merged_lines = List[Line]()
    var merged_olds = List[String]()
    var merged_files = List[String]()
    add_includes_to_main(pp, all_lines, raw, file_name, merged_lines, merged_olds, merged_files)
    var maintext = List[ELine]()
    for i in range(len(merged_lines)):
        maintext.append(make_eline(merged_lines[i], merged_files[i], merged_olds[i]))

    # --- ParseModuleMethodsInMain + ParseModuleMethodsInModules (Linker.cs) --------
    var main_calls = parse_module_methods_in_main(merged_lines)
    var collected = List[Tuple[String, Int]]()
    collect_module_methods(pp, main_calls, collected)
    var methods_text = List[ELine]()
    for c in range(len(collected)):
        var mod_key = collected[c][0]
        var idx = collected[c][1]
        var mline = pp.module_line(idx)
        methods_text.append(
            make_eline(
                mline,
                pp.module_file(mod_key),
                pp.module_old(idx),
            )
        )

    # --- FuncRename + VarsAndLabelsRename --------------------------------------
    # ParsePrivate (Linker.cs:860-960) — до сбора вызовов, как в C#
    parse_private(pp, maintext, ctx)
    func_rename(maintext, methods_text)
    var used_props = UsedProps()
    vars_and_labels_rename(maintext, methods_text, used_props, ctx)
    if ctx.diags.has_errors():
        return List[String]()

    # --- RemoveMainFunc / RemoveMainSub -----------------------------------------
    var after_funcs = List[ELine]()
    var funcs = List[ELine]()
    remove_main_func(maintext, after_funcs, funcs)
    var main2 = List[ELine]()
    var subs = List[ELine]()
    remove_main_sub(after_funcs, main2, subs)

    # --- CreateCallingPropertyLines (Linker.cs:788-858) ----------------------------
    var prop_flat = List[FlatItem]()
    create_calling_property_lines(pp, used_props, ctx, prop_flat)
    if ctx.diags.has_errors():
        return List[String]()

    # --- ParseFuncInitLine: Sub/EndSub + параметры ----------------------------------
    parse_func_init_lines(ctx, funcs)
    parse_func_init_lines(ctx, methods_text)

    # --- ParseAllCalls ------------------------------------------------------------
    parse_all_calls(ctx, main2, subs, funcs, methods_text)

    # --- ParseCalls: main -> subs -> funcs -> методы модулей ------------------------
    parse_one_call(ctx, main2)
    parse_one_call(ctx, subs)
    parse_one_call(ctx, funcs)
    parse_one_call(ctx, methods_text)

    # --- FuncVariablesInit: init-строки временных параметров функций ---------------
    var var_init = List[String]()
    for i in range(len(ctx.temp_vars.order)):
        var name = ctx.temp_vars.order[i]
        var info = ctx.temp_vars.info[name]
        var text = init_line_text(name, info.var_type)
        if text != "":
            var_init.append(text)

    # --- SubVarsInit + OtherVarsAddToMain -------------------------------------------
    process_var_lines(ctx, main2, subs, 0, len(main2))
    other_vars_add_to_main(ctx, var_init)

    # --- CreateProjectOutputLines (Interpreter.cs:345-446) -----------------------------
    # секции: свойства pr_* -> init переменных -> main -> subs -> funcs -> методы
    var flat = List[FlatItem]()
    for i in range(len(prop_flat)):
        flat.append(prop_flat[i].copy())
    for i in range(len(var_init)):
        flat.append(FlatItem(List[EWord](), LT_VARINIT, 0, var_init[i], List[String]()))
    for i in range(len(main2)):
        emit_line(flat, main2[i])
    for i in range(len(subs)):
        emit_line(flat, subs[i])
    for i in range(len(funcs)):
        emit_line(flat, funcs[i])
    for i in range(len(methods_text)):
        emit_line(flat, methods_text[i])

    # --- RewriteOutLines -----------------------------------------------------------------
    flat = rewrite_out_lines(flat, ctx.calls_sub, ctx.calls_func)

    # --- повторный проход по переменным (тела Function) -----------------------------------
    final_var_pass(flat)

    # --- медиа-пути (MediaBuilder через MethodErrorParser) -----------------------------
    media_pass(flat, ctx)

    # --- break/continue/return -------------------------------------------------------------
    parse_jump_operators(flat, ctx, LT_FORINIT, "endfor")
    parse_jump_operators(flat, ctx, LT_WHILEINIT, "endwhile")
    parse_jump_operators(flat, ctx, LT_SUBINIT, "endsub")

    # --- текст вывода (Builder.GetOutFile) ---------------------------------------------------
    var out = List[String]()
    for i in range(len(flat)):
        if len(flat[i].out) > 0:
            for e in range(len(flat[i].out)):
                out.append(flat[i].out[e])
        else:
            out.append(flat[i].new_line)

    return out^


def cmd_expand(path: String, outdir: String) raises -> Int:
    """Команда expand: пишет <каталог исходника>/~<Имя>/~<Имя>.bp."""
    # outdir = ModuleLibPath (библиотечные пути Clev3r://), как arg2 в C#

    var ctx = Ctx()
    var texts = run_expansion(path, outdir, ctx)

    if ctx.diags.has_errors():
        print(ctx.diags.render())
        print("Errors: " + String(ctx.diags.count()))
        exit(1)

    var name = strip_ext(base_name(path))
    var src_dir = dir_name(path)
    if src_dir == "":
        src_dir = "."  # голое имя файла: выводим рядом (Path.Combine("", x) -> x)
    var out_dir = src_dir + "/" + "~" + name
    try:
        mkdir(src_dir)
    except:
        pass
    try:
        mkdir(out_dir)
    except:
        pass
    write_text(out_dir + "/~" + name + ".bp", lines_to_text(texts))
    return 0
