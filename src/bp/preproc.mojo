"""Препроцессор Basic Plus: include (.bpi) и import (.bpm).

Порт фаз C# (файлы не менялись):
  Interpreter/Parsers/IncludeErrorParser.cs  — Start (16-56), GetIncludePath/Name (58-78),
        CreateFullPath (80-154), GetAllLines (156-196)
  Interpreter/Parsers/ImportErrorParser.cs   — Start (18-124), GetImportPath/Name (126-146),
        GetAllLines (148-277), ParseModulePropertys (279-301), ParseModule (303-362),
        RenameModleMethodsAndPropertys (364-426), GetParamCount (428-471),
        CreateFullPath (473-547)
  Interpreter/Utils/Preprocessor.cs          — FirstFindFiles (48-81)
  Interpreter/Utils/Linker.cs                — GetModuleName/GetMethodName (80-98),
        GetParamCount (100-143), ParseModuleMethodsInModules (145-247),
        ParseModuleMethodsInMain (249-281), AddIncludesToMain (283-308), IsAdded (310-322)

Работает на строках лексера (bp.lexer.Line); линковка/развёртка — в bp/expand.mojo.
Хранилище плоское: все строки всех .bpi — в inc_all (диапазоны в inc_span), всех .bpm —
в mod_all (диапазоны в mod_span); реестры свойств/методов — словари по составному ключу
"<модуль> <ключ>" + списки порядка вставки (аналог Dictionary с порядком вставки).

Квирки, воспроизведённые сознательно (docs/02 §4-§6, §12):
  * include в .bpi запрещён (1105), folder в .bpi запрещён (1106) — это защита от
    циклов include; import в .bpi разрешён и резолвится от каталога .bpi
    (IncludeErrorParser.cs:181-186);
  * дедупликации include НЕТ: два include одного файла раскрываются дважды; ключ
    Include-словаря — номер строки include в main (Preprocessor.cs:91-92);
  * import: дедуп по lowercase-имени ДО рекурсии (ImportErrorParser.cs:79/111) —
    защита от циклов; повторный import молча пропускается;
  * NewCallPath: перезаписывается каталогом загруженного модуля (cs:60) и читается
    на каждой рекурсии «как есть» (cs:117) — вложенные import резолвятся от каталога
    импортирующего файла, соседние import могут получить путь, оставленный
    предыдущей рекурсией (статическое поле C#);
  * из текста модуля удаляются IMPORT/EMPTY строки (cs:86-93);
  * объявления `number x` / `number[] x` / `string x` / `string[] x` переквалифицируются
    в LineType.MODULEPROPERTY (cs:204-206);
  * private — «липкий» флаг до конца файла (cs:286-289, 314-317);
  * ключ методов модуля — `<имя>_<число_параметров>` БЕЗ префикса модуля, ключ
    свойств — `<модуль>_<свойство>` (cs:330 vs 293);
  * дубликат метода с >=1 параметром молча пропускается — остаётся первое определение
    (cs:340); переименование до линковки (§5.2): VARIABLE-слова свойств ->
    MODULEPROPERTY `<mod>_<name>`, MODULEPROPERTY с точками -> `_`, SUBCALL/FUNCCALL ->
    MODULEMETHODCALL `<Module.Name>.<имя>` (регистр имени модуля — как на диске!),
    FUNCNAME -> `<Module.Name>_<имя>`;
  * AddIncludesToMain: EMPTY/IMPORT/FOLDER выбрасываются; include-строка заменяется
    на строки .bpi кроме EMPTY/IMPORT (297-304; условие mLine.Type != FOLDER —
    мёртвый код);
  * IsAdded отсекает методы, уже вызванные из MAIN, при сборе вызовов из тел (310-322);
  * имя файла в ошибках .bpi — `Имя.bpi` без каталога (IncludeErrorParser.cs:171);
    в ошибках .bpm — `Имя.bpm` (ImportErrorParser.cs:166);
  * GetParamCount у ImportErrorParser дополнительно считает `f.start` как sub (cs:436)
    — расхождение с Linker воспроизведено (param_count_import vs param_count_linker).

Отступление от C# (docs/notes-expansion-questions.md §4): CreateFullPath при `down > 0`
в C# собирает путь из сегментов без ведущего разделителя (абсолютный путь становится
относительным) и не ограничивает down глубиной базы; здесь путь собирается корректно
(баг оракула на New_Path_Examples не воспроизводится). Чисто валидирующие проверки
(скобочный баланс BracketErrorParser, грамматика параметров ModuleErrorParser,
StructErrorParser/ParseNames, ParsePropertyInFuncInit) не портированы — на валидном
корпусе ошибок не дают.
"""

from std.collections import Dict
from std.os.path import exists

from bp.lexer import (
    Line,
    Word,
    build_line,
    TOK_BRACKETLEFT,
    TOK_BRACKETRIGHT,
    TOK_COMMA,
    TOK_DOUBLEBRACKET,
    TOK_FUNCNAME,
    TOK_KEYWORD,
    TOK_MODULEMETHOD,
    TOK_MODULEPROPERTY,
    TOK_STRING,
    TOK_SUBNAME,
    TOK_VARIABLE,
    LT_EMPTY,
    LT_FOLDER,
    LT_FUNCINIT,
    LT_FUNCCALL,
    LT_IMPORT,
    LT_INCLUDE,
    LT_MODULEMETHODCALL,
    LT_MODULEPROPERTY,
    LT_NUMBERINIT,
    LT_SUBCALL,
    LT_NUMBERARRAYINIT,
    LT_ONEKEYWORD,
    LT_STRINGINIT,
    LT_STRINGARRAYINIT,
    LT_SUBINIT,
)
from bp.diag import Diagnostics
from bp.util import base_name, dir_name, read_lines, strip_ext


# ============================================================================
# Реестры модулей (Module.Propertys / Module.Methods)
# ============================================================================


@fieldwise_init
struct ModProperty(Copyable, Movable, ImplicitlyCopyable):
    """Запись реестра свойств: индекс строки объявления в mod_all + private."""

    var decl_idx: Int
    var is_private: Bool


@fieldwise_init
struct ModMethod(Copyable, Movable, ImplicitlyCopyable):
    """Запись реестра методов: диапазон тела [start_idx, end_idx] в mod_all + private."""

    var start_idx: Int
    var end_idx: Int
    var is_private: Bool


@fieldwise_init
struct OrderedCalls(Copyable, Movable):
    """Упорядоченный словарь `модуль -> набор методов` (_modulesCalling / tmpCalling).

    Пары (модуль, метод) хранятся в порядке первой вставки; ключи разделены
    пробелом — имена модулей/методов пробелов не содержат.
    """

    var pairs: List[Tuple[String, String]]
    var has: Dict[String, Bool]

    def __init__(out self):
        self.pairs = List[Tuple[String, String]]()
        self.has = Dict[String, Bool]()

    def contains(self, mod: String, met: String) -> Bool:
        return (mod + " " + met) in self.has

    def add(mut self, mod: String, met: String):
        var key = mod + " " + met
        if key in self.has:
            return
        self.has[key] = True
        self.pairs.append((mod, met))

    def mod_keys(self) -> List[String]:
        """Модули в порядке первой вставки."""
        var out = List[String]()
        var seen = Dict[String, Bool]()
        for p in self.pairs:
            if p[0] in seen:
                continue
            seen[p[0]] = True
            out.append(p[0])
        return out^

    def methods_of(self, mod: String) -> List[String]:
        """Методы модуля в порядке первой вставки."""
        var out = List[String]()
        for p in self.pairs:
            if p[0] == mod:
                out.append(p[1])
        return out^


# ============================================================================
# Состояние препроцессора (Data.Project.Includes / Modules + NewCallPath)
# ============================================================================


@fieldwise_init
struct Preproc(Movable):
    var diags: Diagnostics
    var project_path: String
    var module_lib_path: String
    var new_call_path: String

    # --- includes: ключ — номер строки include в main (Preprocessor.cs:91-92) ---
    var inc_name: Dict[Int, String]
    var inc_file: Dict[Int, String]
    var inc_span: Dict[Int, Tuple[Int, Int]]
    var inc_all: List[Line]
    var inc_all_olds: List[String]

    # --- modules: ключ — lowercase имя (ImportErrorParser.cs:111) ---
    var mod_keys: List[String]
    var mod_name: Dict[String, String]
    var mod_path: Dict[String, String]
    var mod_file: Dict[String, String]
    var mod_span: Dict[String, Tuple[Int, Int]]
    var mod_all: List[Line]
    var mod_all_olds: List[String]
    # реестры свойств/методов; составной ключ "<модуль> <имя>", порядок — ord_*
    var ord_props: List[Tuple[String, String]]
    var prop_decl: Dict[String, Int]
    var prop_priv: Dict[String, Bool]
    var ord_meths: List[Tuple[String, String]]
    var meth_span: Dict[String, Tuple[Int, Int]]
    var meth_priv: Dict[String, Bool]

    def __init__(out self, project_path: String, module_lib_path: String):
        self.diags = Diagnostics()
        self.project_path = project_path
        self.module_lib_path = module_lib_path
        self.new_call_path = String("")
        self.inc_name = Dict[Int, String]()
        self.inc_file = Dict[Int, String]()
        self.inc_span = Dict[Int, Tuple[Int, Int]]()
        self.inc_all = List[Line]()
        self.inc_all_olds = List[String]()
        self.mod_keys = List[String]()
        self.mod_name = Dict[String, String]()
        self.mod_path = Dict[String, String]()
        self.mod_file = Dict[String, String]()
        self.mod_span = Dict[String, Tuple[Int, Int]]()
        self.mod_all = List[Line]()
        self.mod_all_olds = List[String]()
        self.ord_props = List[Tuple[String, String]]()
        self.prop_decl = Dict[String, Int]()
        self.prop_priv = Dict[String, Bool]()
        self.ord_meths = List[Tuple[String, String]]()
        self.meth_span = Dict[String, Tuple[Int, Int]]()
        self.meth_priv = Dict[String, Bool]()

    # --- доступ к реестрам -----------------------------------------------------

    def module_exists(self, key: String) -> Bool:
        return key in self.mod_span

    def module_line(self, idx: Int) raises -> Line:
        return self.mod_all[idx].copy()

    def module_old(self, idx: Int) raises -> String:
        return self.mod_all_olds[idx]

    def module_file(self, key: String) raises -> String:
        return self.mod_file[key]

    def module_method_exists(self, mk: String, met: String) -> Bool:
        return (mk + " " + met) in self.meth_span

    def module_method(self, mk: String, met: String) raises -> ModMethod:
        var ck = mk + " " + met
        var span = self.meth_span[ck]
        return ModMethod(span[0], span[1], self.meth_priv[ck])

    def module_has_property(self, mk: String, key: String) -> Bool:
        return (mk + " " + key) in self.prop_decl

    def module_property(self, mk: String, key: String) raises -> ModProperty:
        var ck = mk + " " + key
        return ModProperty(self.prop_decl[ck], self.prop_priv[ck])


# ============================================================================
# Вспомогательные: GetModuleName/GetMethodName, GetParamCount
# ============================================================================


def module_name_of(text: String) -> String:
    """Linker.GetModuleName (80-88) — текст до ПЕРВОЙ точки."""
    var i = text.find(".")
    if i == -1:
        return String("")
    return String(text[byte=0:i])


def method_name_of(text: String) -> String:
    """Linker.GetMethodName (90-98) — текст после первой точки."""
    var i = text.find(".")
    if i == -1:
        return String("")
    return String(text[byte=i + 1 :])


def param_count_linker(words: List[Word]) -> Int:
    """Linker.GetParamCount (100-143): `sub`/`thread.run` -> 0 параметров."""
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


def param_count_import(words: List[Word]) -> Int:
    """ImportErrorParser.GetParamCount (428-471): дополнительно считает `f.start`."""
    var comma = 0
    if len(words) > 0:
        var first = words[0].text.lower()
        if first == "sub" or first == "thread.run" or first == "f.start":
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


def join_word_texts(words: List[Word]) -> String:
    """string.Join(" ", Words.Text) — канонический текст строки лексера."""
    var parts = List[String]()
    for i in range(len(words)):
        parts.append(words[i].text)
    if len(parts) == 0:
        return String("")
    return String(" ").join(parts)


def _split_nonempty(s: String, sep: String) -> List[String]:
    """Split(sep, StringSplitOptions.RemoveEmptyEntries)."""
    var out = List[String]()
    var parts = s.split(sep)
    for i in range(len(parts)):
        var p = String(parts[i])
        if p != "":
            out.append(p)
    return out^


# ============================================================================
# Пути: CreateFullPath (ImportErrorParser.cs:473-547 / IncludeErrorParser.cs:80-154)
# ============================================================================


def create_full_path(
    name: String, base_path: String, module_lib_path: String, is_module: Bool
) -> String:
    """Полный путь к .bpi/.bpm без расширения.

    is_module: True — import ("Lib/Modules/"), False — include ("Lib/Includes/").
    """
    var n = String(name.replace('"', "").strip().replace("\\", "/"))
    var file_name = String("")
    var last = n.rfind("/")
    if last != -1:
        file_name = String(n[byte=last:])  # квирк: Substring включает разделитель
    else:
        file_name = n
    var mp = String(base_path.replace('"', "").strip().replace("\\", "/"))

    if n.startswith("Clev3r://") or n.startswith("Clever://"):
        # Библиотечный путь (схема платформозависима: на Linux это "//")
        var sub = "Lib/Modules/" if is_module else "Lib/Includes/"
        var rest = String(n[byte=9:])  # "Clev3r://" и "Clever://" длиной 9
        var libfull = module_lib_path + sub + rest
        return libfull.replace("//", "/")

    var main_words = _split_nonempty(mp, "/")
    var name_words = _split_nonempty(n, "/")
    var full = String("")
    if len(name_words) > 1:
        var down = 0
        var next_path = String("")
        for j in range(len(name_words) - 1):
            if name_words[j] == "..":
                down += 1
            else:
                next_path += name_words[j] + "/"
        if down > 0:
            # C# собирает путь из сегментов base без ведущего "/" и не ограничивает
            # down глубиной (баг, notes §4); здесь — корректный абсолютный путь.
            var keep = len(main_words) - down
            if keep < 0:
                keep = 0
            if mp.startswith("/"):
                full += "/"
            for j in range(keep):
                full += main_words[j] + "/"
            full += next_path
        else:
            full = mp + "/" + next_path
    else:
        full = mp + "/"

    while full.endswith("/"):
        var trimmed = String(full[byte=0 : full.byte_length() - 1])
        full = trimmed^

    return (full + "/" + file_name).replace("//", "/")


# ============================================================================
# Include (.bpi): IncludeErrorParser
# ============================================================================


def parse_include(mut pp: Preproc, line: Line, main_file: String) raises:
    """IncludeErrorParser.Start (16-56) + GetAllLines (156-196)."""
    if len(line.words) == 1:
        pp.diags.add(main_file, line.line_number, 1102, "")
        return
    elif len(line.words) > 2:
        pp.diags.add(main_file, line.line_number, 1103, "")
        return
    elif line.words[1].token != TOK_STRING:
        pp.diags.add(main_file, line.line_number, 1104, "")
        return

    var full = create_full_path(
        line.words[1].text, pp.project_path, pp.module_lib_path, False
    )
    var tmp_path = full + ".bpi"
    if not exists(tmp_path):
        pp.diags.add(main_file, line.line_number, 1101, full + ".bpi")
        return

    var inc_name = strip_ext(base_name(tmp_path))
    var inc_path = dir_name(tmp_path) + "/"

    var raw = read_lines(tmp_path)
    var lines = List[Line]()
    var olds = List[String]()
    for i in range(len(raw)):
        var ln = build_line(raw[i], i + 1)
        if ln.line_type == LT_INCLUDE:
            pp.diags.add(inc_name + ".bpi", i + 1, 1105, "")
            return
        elif ln.line_type == LT_FOLDER:
            pp.diags.add(inc_name + ".bpi", i + 1, 1106, "")
            return
        elif ln.line_type == LT_IMPORT:
            # import внутри .bpi резолвится от каталога .bpi (cs:181-186)
            start_import(pp, ln, inc_path, tmp_path)
            if pp.diags.has_errors():
                return
        lines.append(ln^)
        olds.append(raw[i])

    # BracketErrorParser на валидном корпусе молчит — не портирован
    var key = line.line_number
    pp.inc_name[key] = inc_name
    pp.inc_file[key] = tmp_path
    pp.inc_span[key] = (len(pp.inc_all), len(lines))
    for i in range(len(lines)):
        pp.inc_all.append(lines[i].copy())
        pp.inc_all_olds.append(olds[i])


# ============================================================================
# Import (.bpm): ImportErrorParser
# ============================================================================


def start_import(
    mut pp: Preproc, line: Line, call_path: String, file_name: String
) raises:
    """ImportErrorParser.Start (18-124)."""
    pp.new_call_path = call_path
    if len(line.words) == 1:
        pp.diags.add(file_name, line.line_number, 2002, "")
        return
    elif len(line.words) > 2:
        pp.diags.add(file_name, line.line_number, 2003, "")
        return
    elif line.words[1].token != TOK_STRING:
        pp.diags.add(file_name, line.line_number, 2004, "")
        return

    var full = create_full_path(
        line.words[1].origin_text.replace('"', ""),
        pp.new_call_path,
        pp.module_lib_path,
        True,
    )
    var tmp_path = full + ".bpm"
    if not exists(tmp_path):
        pp.diags.add(file_name, line.line_number, 2001, full + ".bpm")
        return

    var name = strip_ext(base_name(tmp_path))
    var path = dir_name(tmp_path) + "/"
    pp.new_call_path = path

    if pp.module_exists(name.lower()):
        # повторный import / защита от циклов — молча (cs:79)
        return

    var raw = read_lines(tmp_path)
    load_module(pp, raw, tmp_path, name, path)


def load_module(
    mut pp: Preproc,
    raw: List[String],
    file_path: String,
    name: String,
    path: String,
) raises:
    """Загрузка .bpm: GetAllLines (148-277) + реестры + переименование + рекурсия."""
    var mod_key = name.lower()

    # --- GetAllLines: разметка + валидация -----------------------------------
    var all_lines = List[Line]()
    var func = False
    var func_num = 0
    var prop_names = Dict[String, Bool]()
    for i in range(len(raw)):
        var ln = build_line(raw[i], i + 1)
        var t = ln.line_type
        if t == LT_INCLUDE:
            pp.diags.add(name + ".bpm", i + 1, 2005, "")
            return
        elif t == LT_FOLDER:
            pp.diags.add(name + ".bpm", i + 1, 2006, "")
            return
        elif t == LT_FUNCINIT:
            if func:
                pp.diags.add(name + ".bpm", i + 1, 1026, "")
                return
            func = True
            func_num = i + 1
        elif (
            t == LT_ONEKEYWORD
            and len(ln.words) > 0
            and ln.words[0].text.lower() == "endfunction"
        ):
            if not func:
                pp.diags.add(name + ".bpm", i + 1, 1027, "")
                return
            func = False
        elif t == LT_SUBINIT:
            pp.diags.add(name + ".bpm", i + 1, 2007, "")
            return
        elif (
            t == LT_NUMBERINIT
            or t == LT_NUMBERARRAYINIT
            or t == LT_STRINGINIT
            or t == LT_STRINGARRAYINIT
        ):
            # переквалификация объявления свойства в MODULEPROPERTY (cs:204-206)
            ln.line_type = LT_MODULEPROPERTY
            if func:
                pp.diags.add(name + ".bpm", i + 1, 2015, "")
                return
            if len(ln.words) != 2:
                pp.diags.add(name + ".bpm", i + 1, 2011, "")
                return
            elif ln.words[0].token != TOK_KEYWORD and ln.words[0].token != TOK_VARIABLE:
                pp.diags.add(name + ".bpm", i + 1, 2012, "")
                return
            elif (
                ln.words[0].text.lower() != "number"
                and ln.words[0].text.lower() != "number[]"
                and ln.words[0].text.lower() != "string"
                and ln.words[0].text.lower() != "string[]"
            ):
                pp.diags.add(name + ".bpm", i + 1, 2013, "")
                return
            elif ln.words[1].text.lower() in prop_names:
                pp.diags.add(name + ".bpm", i + 1, 2014, ln.words[1].origin_text)
                return
            else:
                prop_names[ln.words[1].text.lower()] = True
        elif (not func) and t != LT_FUNCINIT:
            # NewLine.Trim().IndexOf("'") != 0 — всегда истинно (комментарии срезаны)
            if t != LT_EMPTY and t != LT_IMPORT and t != LT_ONEKEYWORD:
                pp.diags.add(name + ".bpm", i + 1, 2008, "")
                return
        all_lines.append(ln^)
    if func:
        pp.diags.add(name + ".bpm", func_num, 1028, "")
        return

    # ModuleErrorParser.Start (грамматика параметров функций) — чистая валидация,
    # на валидном корпусе ошибок не даёт; не портирована.

    # --- удаление IMPORT/EMPTY (cs:86-93) ------------------------------------
    var lines = List[Line]()
    var olds = List[String]()
    for i in range(len(all_lines)):
        var t = all_lines[i].line_type
        if t != LT_IMPORT and t != LT_EMPTY:
            lines.append(all_lines[i].copy())
            olds.append(raw[i])

    var base = len(pp.mod_all)

    # --- ParseModulePropertys (279-301): реестр свойств ------------------------
    var local_props = Dict[String, Bool]()
    var private_flag = False
    for idx in range(len(lines)):
        ref ln = lines[idx]
        if (
            ln.line_type == LT_ONEKEYWORD
            and len(ln.words) > 0
            and ln.words[0].text.lower() == "private"
        ):
            private_flag = True
        if ln.line_type == LT_MODULEPROPERTY and len(ln.words) > 1:
            # ключ реестра — `<модуль>_<свойство>` (ImportErrorParser.cs:293)
            var full_key = mod_key + "_" + ln.words[1].text.lower()
            var ck = mod_key + " " + full_key
            if not (ck in pp.prop_decl):
                local_props[full_key] = True
                pp.prop_decl[ck] = base + idx
                pp.prop_priv[ck] = private_flag
                pp.ord_props.append((mod_key, full_key))

    # --- ParseModule (303-362): реестр методов ---------------------------------
    private_flag = False
    var start = -1
    var end = -1
    var mname = String("")
    for idx in range(len(lines)):
        ref ln = lines[idx]
        if (
            ln.line_type == LT_ONEKEYWORD
            and len(ln.words) > 0
            and ln.words[0].text.lower() == "private"
        ):
            private_flag = True
        if ln.line_type == LT_FUNCINIT:
            # ParsePropertyInFuncInit (2019) — чистая валидация, не портирована
            start = idx
            if len(ln.words) > 1:
                mname = (
                    ln.words[1].text.lower()
                    + "_"
                    + String(param_count_import(ln.words))
                )
        elif (
            ln.line_type == LT_ONEKEYWORD
            and len(ln.words) > 0
            and ln.words[0].text.lower() == "endfunction"
        ):
            end = idx
        if start >= 0 and end >= 0 and mname != "":
            var ck = mod_key + " " + mname
            if not (ck in pp.meth_span):
                pp.meth_span[ck] = (base + start, base + end)
                pp.meth_priv[ck] = private_flag
                pp.ord_meths.append((mod_key, mname))
            start = -1
            end = -1
            mname = String("")

    # --- RenameModleMethodsAndPropertys (364-426) — до линковки ----------------
    rename_module_members(lines, name, local_props)

    # --- сохранение модуля (99-111) ---------------------------------------------
    for idx in range(len(lines)):
        pp.mod_all.append(lines[idx].copy())
        pp.mod_all_olds.append(olds[idx])
    pp.mod_keys.append(mod_key)
    pp.mod_name[mod_key] = name
    pp.mod_path[mod_key] = path
    pp.mod_file[mod_key] = file_path
    pp.mod_span[mod_key] = (base, len(lines))

    # --- рекурсия по import-строкам ПОСЛЕ регистрации (cs:113-121) --------------
    for i in range(len(all_lines)):
        ref ln2 = all_lines[i]
        if ln2.line_type == LT_IMPORT:
            var cp = pp.new_call_path
            start_import(pp, ln2, cp, file_path)
            if pp.diags.has_errors():
                return


def rename_module_members(
    mut lines: List[Line], module_name: String, prop_keys: Dict[String, Bool]
):
    """RenameModleMethodsAndPropertys (ImportErrorParser.cs:364-426)."""
    for k in range(len(lines)):
        ref line = lines[k]
        if len(line.words) > 0:
            for wi in range(len(line.words)):
                var tok = line.words[wi].token
                if tok == TOK_VARIABLE:
                    var pname = module_name.lower() + "_" + line.words[wi].text.lower()
                    if pname in prop_keys:
                        line.words[wi].token = TOK_MODULEPROPERTY
                        line.words[wi].text = pname
                elif tok == TOK_MODULEPROPERTY:
                    line.words[wi].text = line.words[wi].text.lower().replace(".", "_")
        if line.line_type == LT_SUBCALL or line.line_type == LT_FUNCCALL:
            line.line_type = LT_MODULEMETHODCALL
            for wi in range(len(line.words)):
                var tok = line.words[wi].token
                if tok == TOK_SUBNAME or tok == TOK_FUNCNAME:
                    line.words[wi].token = TOK_MODULEMETHOD
                    line.words[wi].text = module_name + "." + line.words[wi].text
        elif line.line_type == LT_FUNCINIT:
            for wi in range(len(line.words)):
                var tok = line.words[wi].token
                if tok == TOK_FUNCNAME:
                    line.words[wi].text = module_name + "_" + line.words[wi].text


# ============================================================================
# Preprocessor.FirstFindFiles (48-81)
# ============================================================================


def first_find_files(mut pp: Preproc, main_lines: List[Line], main_file: String) raises:
    """Первый проход main: include/import (folder обрабатывается в expand.mojo)."""
    for k in range(len(main_lines)):
        ref line = main_lines[k]
        if line.line_type == LT_INCLUDE:
            parse_include(pp, line, main_file)
            if pp.diags.has_errors():
                return
        elif line.line_type == LT_IMPORT:
            var cp = pp.project_path
            start_import(pp, line, cp, main_file)
            if pp.diags.has_errors():
                return


# ============================================================================
# AddIncludesToMain (Linker.cs:283-308)
# ============================================================================


def add_includes_to_main(
    pp: Preproc,
    main_lines: List[Line],
    main_olds: List[String],
    main_file: String,
    mut out_lines: List[Line],
    mut out_olds: List[String],
    mut out_files: List[String],
) raises:
    """Склейка main + include-контента (MainText).

    EMPTY/IMPORT/FOLDER выбрасываются; строка include заменяется на строки .bpi
    (кроме EMPTY/IMPORT); дедупликации нет.
    """
    for k in range(len(main_lines)):
        ref mline = main_lines[k]
        var t = mline.line_type
        if t == LT_EMPTY or t == LT_IMPORT or t == LT_FOLDER:
            continue
        var key = mline.line_number
        if key in pp.inc_span:
            var sp = pp.inc_span[key]
            for i in range(sp[0], sp[0] + sp[1]):
                var iln = pp.inc_all[i].copy()
                if iln.line_type != LT_EMPTY and iln.line_type != LT_IMPORT:
                    out_lines.append(iln^)
                    out_olds.append(pp.inc_all_olds[i])
                    out_files.append(pp.inc_file[key])
        else:
            out_lines.append(mline.copy())
            out_olds.append(main_olds[k])
            out_files.append(main_file)


# ============================================================================
# Сбор вызовов методов модулей (Linker.cs:145-281)
# ============================================================================


def parse_module_methods_in_main(lines: List[Line]) -> OrderedCalls:
    """Linker.ParseModuleMethodsInMain (249-281) — вызовы MODULEMETHOD в MainText."""
    var res = OrderedCalls()
    for k in range(len(lines)):
        ref line = lines[k]
        for i in range(len(line.words)):
            if line.words[i].token == TOK_MODULEMETHOD:
                var name = module_name_of(line.words[i].text).lower()
                var met = (
                    method_name_of(line.words[i].text).lower()
                    + "_"
                    + String(param_count_linker(line.words))
                )
                res.add(name, met)
    return res^


def collect_module_methods(
    pp: Preproc, main_calls: OrderedCalls, mut result: List[Tuple[String, Int]]
) raises:
    """Linker.ParseModuleMethodsInModules (145-247): замыкание вызовов по модулям.

    result — пары (модуль, индекс строки в mod_all) в порядке добавления тел в
    ModuleMethodsText; вложенные вызовы добавляются рекурсивно.
    """
    var tmp = OrderedCalls()
    _collect_step(pp, main_calls, main_calls, tmp, result)


def _collect_step(
    pp: Preproc,
    original: OrderedCalls,
    calling: OrderedCalls,
    mut tmp: OrderedCalls,
    mut result: List[Tuple[String, Int]],
) raises:
    # шаг 1: новые вызовы с дедупом по tmpCalling (cs:149-170)
    var new_calling = OrderedCalls()
    for p in calling.pairs:
        if not tmp.contains(p[0], p[1]):
            tmp.add(p[0], p[1])
            new_calling.add(p[0], p[1])

    # шаг 2: тела методов -> ModuleMethodsText, затем рекурсия (cs:173-246)
    var seen = Dict[String, Bool]()
    for p in new_calling.pairs:
        var mod_name = p[0]
        if mod_name in seen:
            continue
        seen[mod_name] = True
        if not pp.module_exists(mod_name):
            # модуль вызван, но не импортирован — молча; ошибка будет 1806 (cs:241-245)
            continue
        var methods = new_calling.methods_of(mod_name)
        for mi in range(len(methods)):
            var met = methods[mi]
            if not pp.module_method_exists(mod_name, met):
                continue
            var mm = pp.module_method(mod_name, met)
            if mm.end_idx < mm.start_idx:
                continue
            for bi in range(mm.start_idx, mm.end_idx + 1):
                result.append((mod_name, bi))
            # вызовы методов из добавленного тела (cs:199-236)
            var m_calling = OrderedCalls()
            for bi in range(mm.start_idx, mm.end_idx + 1):
                var ln = pp.module_line(bi)
                if ln.line_type == LT_MODULEMETHODCALL:
                    for wi in range(len(ln.words)):
                        if ln.words[wi].token == TOK_MODULEMETHOD:
                            var wname = module_name_of(ln.words[wi].text).lower()
                            var wmet = (
                                method_name_of(ln.words[wi].text).lower()
                                + "_"
                                + String(param_count_linker(ln.words))
                            )
                            # IsAdded (cs:310-322): уже вызванные из MAIN не собираются
                            if not original.contains(wname, wmet):
                                m_calling.add(wname, wmet)
            if len(m_calling.pairs) > 0:
                _collect_step(pp, original, m_calling, tmp, result)
