"""Сквозные команды `bp compile` и `bp check`.

Поверх трёх уже работающих стадий (только чтение чужих модулей):
  стадия expand — bp.expand.cmd_expand / run_expansion + Ctx;
  стадия 3 (lmsb) — bp.compiler3.compile_source_lines;
  стадия 4 (rbf)  — bp.asm.assemble_lmsb.

Раскладка артефактов повторяет tools/difftest.sh как эталон:
  <src_dir>/~<Имя>/~<Имя>.bp   (пишет cmd_expand)
  <src_dir>/~<Имя>/<Имя>.lmsb   (стадия 3, как cmd_lmsb в main.mojo)
  <src_dir>/~<Имя>/<Имя>.rbf    (стадия 4, как cmd_rbf в main.mojo)

Код 3000 в cmd_check — условный маркер ошибок стадии 3 (у Compiler.cs своих
числовых кодов нет; сообщение C# имеет вид "<текст> at: L:C").
"""

from bp.util import read_lines, write_text, base_name, dir_name, strip_ext
from bp.lexer import _byte_at
from bp.diag import Diagnostics
from bp.expand import cmd_expand, run_expansion, Ctx
from bp.compiler3 import compile_source_lines
from bp.asm import assemble_lmsb


def cmd_compile(main_path: String, outdir: String) raises -> Int:
    """Полный цикл: expand -> lmsb -> rbf.

    outdir пробрасывается в cmd_expand как ModuleLibPath (как arg2 в C#);
    при пустом outdir развёртка и артефакты лежат рядом с исходником.
    Артефакты .lmsb + .rbf — рядом с развёрнутым файлом (см. раскладку выше).
    Ошибки печатаются, при неуспехе возвращается 1.
    """
    var rc = cmd_expand(main_path, outdir)
    if rc != 0:
        return 1

    var name = strip_ext(base_name(main_path))
    var src_dir = dir_name(main_path)
    var exp_path = src_dir + "/~" + name + "/~" + name + ".bp"

    # --- стадия 3 (зеркало cmd_lmsb из main.mojo) ---
    var lines = read_lines(exp_path)
    var text: String = ""
    var failed = False
    try:
        text = compile_source_lines(lines)
    except e:
        failed = True
        print("bp compile: error (lmsb):", e)
    if failed:
        return 1

    var lmsb_path = src_dir + "/~" + name + "/" + name + ".lmsb"
    write_text(lmsb_path, text)

    # --- стадия 4 (зеркало cmd_rbf из main.mojo) ---
    var errors = assemble_lmsb(lmsb_path)
    if len(errors) > 0:
        for i in range(len(errors)):
            print(errors[i])
        return 1
    return 0


def _parse_line_no(s: String) -> Int:
    """Ручной разбор неотрицательного целого; -1 при неудаче."""
    if s.byte_length() == 0:
        return -1
    var v = 0
    for i in range(s.byte_length()):
        var c = Int(_byte_at(s, i))
        if c < 48 or c > 57:
            return -1
        v = v * 10 + (c - 48)
    return v


def _report_stage3_error(path: String, msg: String):
    """Ошибка стадии 3 в формате diag.mojo (file/line/code/message).

    Разбирает хвост C#-сообщения " at: L:C"; код 3000 = маркер стадии lmsb.
    """
    var marker = " at: "
    var idx = msg.rfind(marker)
    var body = msg
    var line_no = 0
    if idx != -1:
        body = String(msg[byte=0:idx])
        var tail = String(msg[byte=idx + marker.byte_length() :])
        var parts = tail.split(":")
        if len(parts) >= 1:
            var n = _parse_line_no(String(String(parts[0]).strip()))
            if n != -1:
                line_no = n
    var diags = Diagnostics()
    diags.add(path, line_no, 3000, body)
    print(diags.render())


def cmd_check(path: String) raises -> Int:
    """Проверка без артефактов: expand in-memory + компиляция in-memory.

    run_expansion ничего не пишет на диск (только читает исходник и его
    include/import), compile_source_lines работает со строками в памяти,
    поэтому артефактов не остаётся. Диагностики — в формате diag.mojo,
    возврат 1 если есть ошибки, иначе 0 и короткое OK.
    """
    var ctx = Ctx()
    var texts = run_expansion(path, "", ctx)

    if ctx.diags.has_errors():
        print(ctx.diags.render())
        print("Errors: " + String(ctx.diags.count()))
        return 1

    try:
        _ = compile_source_lines(texts)
    except e:
        _report_stage3_error(path, String(e))
        print("Errors: 1")
        return 1

    print("OK: " + path)
    return 0
