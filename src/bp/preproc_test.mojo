"""Регрессии подтверждённых дефектов expand/preproc (t3).

Запуск из корня репо:
  uv run mojo run src/bp/preproc_test.mojo
Печатает PREPROC_TEST OK при успехе.

Покрытие (каждый кейс — подтверждённый дефект из t10 VERDICTS.md):
  G/Additional-1  голое имя `Main.bp` -> include/import от реального родителя,
                  а не от "/" (C# Program.cs:35/43, fi.DirectoryName);
  LSP-API         необязательный 4-й параметр run_expansion project_dir;
  G/ModuleError   1809: дубликат функции нулевой арности в .bpm; различные
                  перегрузки и валидные модули не отвергаются;
  G/Bracket       1001/1002 в .bpm и .bpi (BracketErrorParser.cs:11-59,
                  ImportErrorParser.cs:263, IncludeErrorParser.cs:189);
  G/Unresolved    1806/1606/1414 на стадии expand (Interpreter.cs:676-754);
  empty input     пустой .bp -> пустой ~empty.bp (C# File.WriteAllLines);
  intentional '..' create_full_path сохраняет корректный абсолютный путь.

Тесты создают собственные временные каталоги (tempfile.mkdtemp), ничего не
пишут в corpus/golden и не зависят от main-checkout.
"""

from std.python import Python

from bp.expand import Ctx, cmd_expand, run_expansion
from bp.lexer import build_line
from bp.preproc import bracket_error_code, create_full_path
from bp.util import read_lines, write_text


def check(cond: Bool, what: String) raises:
    if not cond:
        raise Error("FAIL: " + what)
    print("ok: " + what)


def _tmpdir() raises -> String:
    var tf = Python.import_module("tempfile")
    return String(tf.mkdtemp(prefix="bp_regr_"))


def _chdir(path: String) raises:
    var os = Python.import_module("os")
    os.chdir(path)


def _codes(ctx: Ctx) -> List[Int]:
    var out = List[Int]()
    for i in range(ctx.diags.count()):
        out.append(ctx.diags.items[i].code)
    return out^


def _has_code(ctx: Ctx, code: Int) -> Bool:
    for i in range(ctx.diags.count()):
        if ctx.diags.items[i].code == code:
            return True
    return False


def _joined(texts: List[String]) -> String:
    return String("\n").join(texts)


# ---------------------------------------------------------------------------
# G/Additional-1: голое и относительное имя входа
# ---------------------------------------------------------------------------


def test_bare_and_relative_input() raises:
    var dir = _tmpdir()
    write_text(
        dir + "/Main.bp",
        'import "Module1"\nModule1.x = 3\nModule1.Show(1)\nLCD.Text(1,0,0,1,"ok")\n',
    )
    write_text(
        dir + "/Module1.bpm",
        'number x\n\nFunction Show(in number n)\n  LCD.Text(1,0,0,1,"mod")\nEndFunction\n',
    )
    var old_cwd = String(Python.import_module("os").getcwd())
    _chdir(dir)
    try:
        # голое имя: раньше dir_name("") + "/" == "/" -> 2001 (/Module1.bpm)
        var ctx1 = Ctx()
        var texts1 = run_expansion("Main.bp", "", ctx1)
        check(
            not ctx1.diags.has_errors(),
            "голое Main.bp: sibling .bpm найден (" + ctx1.diags.render() + ")",
        )
        var body = _joined(texts1)
        check(body.find("pr_module1_x") != -1, "голое Main.bp: свойство pr_module1_x")
        check(
            body.find("m_module1_show_1") != -1,
            "голое Main.bp: вызов m_module1_show_1",
        )

        # ./Main.bp и абсолютный путь дают тот же результат
        var ctx2 = Ctx()
        var texts2 = run_expansion("./Main.bp", "", ctx2)
        check(not ctx2.diags.has_errors(), "./Main.bp: без ошибок")
        check(_joined(texts2) == body, "./Main.bp: та же развёртка")

        var ctx3 = Ctx()
        var texts3 = run_expansion(dir + "/Main.bp", "", ctx3)
        check(not ctx3.diags.has_errors(), "абсолютный Main.bp: без ошибок")
        check(_joined(texts3) == body, "абсолютный Main.bp: та же развёртка")
    finally:
        _chdir(old_cwd)


# ---------------------------------------------------------------------------
# LSP-API: необязательный project_dir (4-й параметр)
# ---------------------------------------------------------------------------


def test_project_dir_param() raises:
    var proj = _tmpdir()
    var lsp = _tmpdir()
    write_text(
        proj + "/Module1.bpm",
        "number x\n\nFunction Show(in number n)\n  LCD.Text(1,0,0,1,\"mod\")\nEndFunction\n",
    )
    # Документ LSP лежит НЕ рядом с проектом; тот же текст, что и bare-кейс.
    write_text(
        lsp + "/d0.bp",
        'import "Module1"\nModule1.Show(1)\nLCD.Text(1,0,0,1,"ok")\n',
    )

    # без project_dir: sibling нет -> 2001 (ожидаемо для temp-документа)
    var ctx_bad = Ctx()
    var _ = run_expansion(lsp + "/d0.bp", "", ctx_bad)
    check(_has_code(ctx_bad, 2001), "project_dir пуст: temp-документ не находит .bpm")

    # с project_dir: relative import разрешается от каталога проекта
    var ctx_ok = Ctx()
    var texts = run_expansion(lsp + "/d0.bp", "", ctx_ok, proj)
    check(
        not ctx_ok.diags.has_errors(),
        "project_dir задан: sibling .bpm найден (" + ctx_ok.diags.render() + ")",
    )
    check(
        _joined(texts).find("m_module1_show_1") != -1,
        "project_dir: вызов метода модуля в развёртке",
    )

    # trailing slash не обязателен во входном значении API (контракт слоя — с "/")
    var ctx_slash = Ctx()
    var _ = run_expansion(lsp + "/d0.bp", "", ctx_slash, proj + "/")
    check(not ctx_slash.diags.has_errors(), "project_dir с trailing slash")


# ---------------------------------------------------------------------------
# G/ModuleError 1809: дубликат функции нулевой арности
# ---------------------------------------------------------------------------


def test_dup_zero_arg_module() raises:
    var dir = _tmpdir()
    write_text(dir + "/Main.bp", 'import "Dup"\nLCD.Text(1,0,0,1,"ok")\n')
    write_text(
        dir + "/Dup.bpm",
        'Function A()\n  LCD.Text(1,0,0,1,"a")\nEndFunction\n'
        'Function A()\n  LCD.Text(1,0,0,1,"b")\nEndFunction\n',
    )
    var ctx = Ctx()
    var _ = run_expansion(dir + "/Main.bp", "", ctx)
    check(_has_code(ctx, 1809), "дубликат Function A() -> 1809")
    var d = ctx.diags.items[0].copy()
    check(d.line == 4, "1809 на строке второго объявления (" + String(d.line) + ")")
    check(d.file.endswith("Dup.bpm"), "1809 в файле .bpm: " + d.file)


def test_distinct_overloads_valid() raises:
    var dir = _tmpdir()
    write_text(
        dir + "/Main.bp",
        'import "Over"\nOver.A()\nOver.A(1)\nOver.A(1,2)\nLCD.Text(1,0,0,1,"ok")\n',
    )
    write_text(
        dir + "/Over.bpm",
        "number x\n\n"
        'Function A()\n  LCD.Text(1,0,0,1,"a")\nEndFunction\n'
        'Function A(in number n)\n  LCD.Text(1,0,0,1,"b")\nEndFunction\n'
        'Function A(in number n, in number m)\n  LCD.Text(1,0,0,1,"c")\nEndFunction\n',
    )
    var ctx = Ctx()
    var texts = run_expansion(dir + "/Main.bp", "", ctx)
    check(
        not ctx.diags.has_errors(),
        "перегрузки A(), A(1), A(1,2) валидны (" + ctx.diags.render() + ")",
    )
    var body = _joined(texts)
    check(body.find("m_over_a_0") != -1, "вызов A() -> m_over_a_0")
    check(body.find("m_over_a_1") != -1, "вызов A(1) -> m_over_a_1")
    check(body.find("m_over_a_2") != -1, "вызов A(1,2) -> m_over_a_2")


def test_dup_one_arg_still_merged() raises:
    # Документированная семантика >=1 параметра: молчаливое схлопывание, НЕ 1809
    var dir = _tmpdir()
    write_text(dir + "/Main.bp", 'import "Dup1"\nDup1.A(1)\nLCD.Text(1,0,0,1,"ok")\n')
    write_text(
        dir + "/Dup1.bpm",
        'Function A(in number n)\n  LCD.Text(1,0,0,1,"a")\nEndFunction\n'
        'Function A(in number n)\n  LCD.Text(1,0,0,1,"b")\nEndFunction\n',
    )
    var ctx = Ctx()
    var _ = run_expansion(dir + "/Main.bp", "", ctx)
    check(not ctx.diags.has_errors(), "дубликат A(in number) по-прежнему без ошибки")


# ---------------------------------------------------------------------------
# G/BracketErrorParser 1001/1002
# ---------------------------------------------------------------------------


def _code_of(raw: String) -> Int:
    return bracket_error_code(build_line(raw, 1))


def test_bracket_validator_unit() raises:
    check(_code_of('LCD.Text(1,0,0,1,"ok")') == 0, "корректные скобки")
    check(_code_of('LCD.Text(1,0,0,1,"x"') == 1001, "незакрытая ( -> 1001")
    check(_code_of("LCD.Text(1,0,0,1,\"x\")") == 0, "лишней нет")
    check(_code_of('LCD.Text(1,0,0,1,"x")') == 0, "закрытая ( -> 0")
    check(_code_of("LCD.Text(1,0,0,1,\"x\"))") == 1001, "лишняя ) -> 1001")
    check(_code_of('LCD.Text(1,0,0,1,"(x]")') == 0, "скобки внутри строки не считаются")
    check(_code_of("Row.Read(1)") == 0, "обычный вызов")
    check(_code_of("number[] a") == 0, "объявление массива")
    check(_code_of("LCD.Text([1],0,0,1)") == 0, "правильная пара []/()")
    check(_code_of("LCD.Text([1),0,0,1)") == 1002, "несовпадение ]/ ) -> 1002")
    check(_code_of("") == 0, "пустая строка -> 0")


def test_bracket_in_bpm_and_bpi() raises:
    var dir = _tmpdir()
    write_text(dir + "/Main.bp", 'import "Bad"\nLCD.Text(1,0,0,1,"ok")\n')
    write_text(
        dir + "/Bad.bpm",
        'number x\nFunction A(in number n)\n  LCD.Text(1,0,0,1,"x"\nEndFunction\n',
    )
    var ctx = Ctx()
    var _ = run_expansion(dir + "/Main.bp", "", ctx)
    check(_has_code(ctx, 1001), "битые скобки в .bpm -> 1001")

    var dir2 = _tmpdir()
    write_text(dir2 + "/Main.bp", 'include "Inc"\nLCD.Text(1,0,0,1,"ok")\n')
    write_text(dir2 + "/Inc.bpi", 'LCD.Text(1,0,0,1,"x"\n')
    var ctx2 = Ctx()
    var _ = run_expansion(dir2 + "/Main.bp", "", ctx2)
    check(_has_code(ctx2, 1001), "битые скобки в .bpi -> 1001")

    # валидные строки со скобками внутри литералов не отвергаются
    var dir3 = _tmpdir()
    write_text(dir3 + "/Main.bp", 'LCD.Text(1,0,0,1,"(a] b)")\n')
    var ctx3 = Ctx()
    var _ = run_expansion(dir3 + "/Main.bp", "", ctx3)
    check(
        not ctx3.diags.has_errors(),
        "скобки внутри строкового литерала валидны (" + ctx3.diags.render() + ")",
    )


# ---------------------------------------------------------------------------
# G/Unresolved 1806/1606/1414 + валидные вызовы
# ---------------------------------------------------------------------------


def test_unresolved_calls() raises:
    var dir = _tmpdir()

    write_text(dir + "/Missing.bp", 'Missing(1)\nLCD.Text(1,0,0,1,"ok")\n')
    var c1 = Ctx()
    var _ = run_expansion(dir + "/Missing.bp", "", c1)
    check(_has_code(c1, 1806), "неизвестная функция с аргументом -> 1806")

    write_text(dir + "/MissingSub.bp", 'MissingSub()\nLCD.Text(1,0,0,1,"ok")\n')
    var c2 = Ctx()
    var _ = run_expansion(dir + "/MissingSub.bp", "", c2)
    check(_has_code(c2, 1606), "неизвестная процедура без аргументов -> 1606")

    write_text(dir + "/MissingSub1.bp", 'MissingSub(1)\nLCD.Text(1,0,0,1,"ok")\n')
    var c3 = Ctx()
    var _ = run_expansion(dir + "/MissingSub1.bp", "", c3)
    check(_has_code(c3, 1806), "неизвестная процедура с аргументом -> 1806")

    write_text(
        dir + "/ThreadMissing.bp", 'Thread.Run = NOPE\nLCD.Text(1,0,0,1,"ok")\n'
    )
    var c4 = Ctx()
    var _ = run_expansion(dir + "/ThreadMissing.bp", "", c4)
    check(_has_code(c4, 1606), "Thread.Run на неизвестную процедуру -> 1606")

    write_text(
        dir + "/ThreadBad.bp", 'Thread.Run = 1\nLCD.Text(1,0,0,1,"ok")\n'
    )
    var c5 = Ctx()
    var _ = run_expansion(dir + "/ThreadBad.bp", "", c5)
    check(_has_code(c5, 1414), "Thread.Run с недопустимым выражением -> 1414")


def test_valid_calls_not_rejected() raises:
    var dir = _tmpdir()
    write_text(
        dir + "/Valid.bp",
        "Sub Hi\n"
        '  LCD.Text(1,0,0,1,"hi")\n'
        "EndSub\n"
        "Function Zero ()\n"
        '  LCD.Text(1,0,0,1,"zero")\n'
        "EndFunction\n"
        "Hi()\n"
        "Zero()\n"
        "Thread.Run = Hi\n"
        'LCD.Text(1,0,0,1,"ok")\n',
    )
    var ctx = Ctx()
    var _ = run_expansion(dir + "/Valid.bp", "", ctx)
    check(
        not ctx.diags.has_errors(),
        "valid Sub/Function0/Thread.Run/builtin не отвергаются (" + ctx.diags.render() + ")",
    )


# ---------------------------------------------------------------------------
# empty input: ~empty.bp пустой
# ---------------------------------------------------------------------------


def test_empty_expansion() raises:
    var dir = _tmpdir()
    write_text(dir + "/empty.bp", "")
    var rc = cmd_expand(dir + "/empty.bp", "")
    check(rc == 0, "пустой вход: exit 0")
    var out = read_lines(dir + "/~empty/~empty.bp")
    check(len(out) == 0, "пустой вход: 0 строк, получено " + String(len(out)))
    var st = Python.import_module("os").stat(dir + "/~empty/~empty.bp")
    check(
        String(st.st_size) == "0", "пустой вход: файл 0 байт (не перевод строки)"
    )


# ---------------------------------------------------------------------------
# intentional '..' fix create_full_path
# ---------------------------------------------------------------------------


def test_create_full_path_dotdot() raises:
    check(
        create_full_path("../Sensors/Probe", "/a/Devices", "", False)
        == "/a/Sensors/Probe",
        "absolute base + ../Sensors/Probe сохраняет ведущий / (intentional fix)",
    )
    check(
        create_full_path("Inc", "/a/b", "", False) == "/a/b/Inc",
        "sibling include от каталога входа",
    )
    check(
        create_full_path("Inc", ".", "", False) == "./Inc",
        "голый вход: база '.' (не '/')",
    )
    check(
        create_full_path("Clev3r://Lib/Inc", "", "/lib/", False)
        == "/lib/Lib/Includes/Lib/Inc",
        "Clev3r:// путь в библиотеку include",
    )


def main() raises:
    test_bare_and_relative_input()
    test_project_dir_param()
    test_dup_zero_arg_module()
    test_distinct_overloads_valid()
    test_dup_one_arg_still_merged()
    test_bracket_validator_unit()
    test_bracket_in_bpm_and_bpi()
    test_unresolved_calls()
    test_valid_calls_not_rejected()
    test_empty_expansion()
    test_create_full_path_dotdot()
    print("PREPROC_TEST OK")
