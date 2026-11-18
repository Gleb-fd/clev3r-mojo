"""Фокусные регрессии JSON-арены (t24): O(1)-дозапись детей + семантика.

Запуск из корня репо:
  uv run mojo run src/bp/json_test.mojo
Печатает "JSON_TEST OK" при успехе.

Покрытие (каждый пункт — инвариант, который обязана сохранить замена обхода
детей в _link_child на поддерживаемый хвост контейнера):

  * широкий массив: длина, порядок, jarray_at, дамп = вход;
  * широкий объект: порядок ключей, jobject_get, дамп = вход;
  * вложенное чередование массив/объект: дамп = вход;
  * пустые контейнеры (kid == -1 <=> tail == -1);
  * дубликаты ключей: jobject_get -> ПЕРВОЕ значение, дамп сохраняет оба;
  * инвариант kid/sib/tail на каждом контейнере каждого документа;
  * глубина: 128 контейнеров допустимы, 129 отвергаются;
  * ошибки разбора не превращаются в молчаливый успех;
  * замер масштабирования parse на 20/40/80/160/320 KiB (печать времени;
    сравнение с квадратичным b580bcc — снаружи, по тому же входу).

Тест не пишет файлов и не зависит от main-checkout.
"""

from std.time import perf_counter_ns

from bp.json import (
    JK_ARR,
    JK_OBJ,
    JDoc,
    jarray_at,
    jarray_len,
    jobject_get,
    jkind,
    json_dump,
    json_parse,
    jstr,
)


def check(cond: Bool, what: String) raises:
    if not cond:
        raise Error("FAIL: " + what)


def _to_str(raw: List[UInt8]) -> String:
    var span = Span(unsafe_ptr=raw.unsafe_ptr(), length=len(raw))
    return String(StringSlice(unsafe_from_utf8=span))


def _add(mut out: List[UInt8], s: String):
    for i in range(s.byte_length()):
        out.append(s.unsafe_ptr().unsafe_offset(i)[])


def _byte(mut out: List[UInt8], b: Int):
    out.append(UInt8(b))


def wide_array_json(n: Int) -> String:
    """[0,1,2,...,n-1] — широкий массив коротких чисел."""
    var out = List[UInt8]()
    _byte(out, 91)  # [
    for i in range(n):
        if i > 0:
            _byte(out, 44)  # ,
        _add(out, String(i))
    _byte(out, 93)  # ]
    return _to_str(out)


def wide_object_json(n: Int) -> String:
    """{"k0":0,"k1":3,...} — широкий объект с уникальными ключами."""
    var out = List[UInt8]()
    _byte(out, 123)  # {
    for i in range(n):
        if i > 0:
            _byte(out, 44)  # ,
        _add(out, "\"k")
        _add(out, String(i))
        _byte(out, 34)  # "
        _byte(out, 58)  # :
        _add(out, String(i * 3))
    _byte(out, 125)  # }
    return _to_str(out)


def nested_json(depth: Int) -> String:
    """Чередование [ {"k": ... } [ ... ] ] заданной глубины."""
    var out = List[UInt8]()
    for i in range(depth):
        if i % 2 == 0:
            _byte(out, 91)  # [
        else:
            _add(out, "{\"k\":")
    _add(out, String(1))
    var j = depth - 1
    while j >= 0:
        if j % 2 == 0:
            _byte(out, 93)  # ]
        else:
            _byte(out, 125)  # }
        j -= 1
    return _to_str(out)


def deep_arrays(depth: Int) -> String:
    """[[[...0...]]] — ровно depth контейнеров."""
    var out = List[UInt8]()
    for _ in range(depth):
        _byte(out, 91)
    _byte(out, 48)  # 0
    for _ in range(depth):
        _byte(out, 93)
    return _to_str(out)


def check_tree(doc: JDoc) raises:
    """Инвариант: kid == -1 <=> tail == -1; tail — последний ребёнок."""
    var bad = 0
    var n = len(doc.nodes)
    for i in range(n):
        var kind = doc.nodes[i].kind
        if kind != JK_ARR and kind != JK_OBJ:
            continue
        var kid = doc.nodes[i].kid
        var tail = doc.nodes[i].tail
        if kid == -1:
            if tail != -1:
                bad += 1
            continue
        if tail == -1:
            bad += 1
            continue
        var c = kid
        var last = -1
        var steps = 0
        while c != -1:
            if c < 0 or c >= n:
                bad += 1
                last = -2
                break
            last = c
            c = doc.nodes[c].sib
            steps += 1
            if steps > n:  # цикл в sib — уже нарушение
                bad += 1
                last = -2
                break
        if last == -2:
            continue
        if last != tail:
            bad += 1
        elif doc.nodes[tail].sib != -1:
            bad += 1
    check(bad == 0, "инвариант kid/sib/tail на всех контейнерах")


def test_wide_array() raises:
    var n = 1000
    var text = wide_array_json(n)
    var doc = json_parse(text)
    check(jkind(doc, doc.root) == JK_ARR, "root широкого массива")
    check(jarray_len(doc, doc.root) == n, "длина широкого массива")
    check(jstr(doc, jarray_at(doc, doc.root, 0)) == "0", "первый элемент")
    check(jstr(doc, jarray_at(doc, doc.root, 777)) == "777", "элемент 777")
    check(
        jstr(doc, jarray_at(doc, doc.root, n - 1)) == String(n - 1),
        "последний элемент",
    )
    check(jarray_at(doc, doc.root, n) == -1, "индекс за концом = -1")
    check(json_dump(doc, doc.root) == text, "дамп массива = вход")
    check_tree(doc)


def test_wide_object() raises:
    var n = 600
    var text = wide_object_json(n)
    var doc = json_parse(text)
    check(jkind(doc, doc.root) == JK_OBJ, "root широкого объекта")
    check(jobject_get(doc, doc.root, "k0") != -1, "ключ k0 найден")
    check(
        jstr(doc, jobject_get(doc, doc.root, "k599")) == "1797",
        "значение k599",
    )
    check(jobject_get(doc, doc.root, "nope") == -1, "чужой ключ = -1")
    check(json_dump(doc, doc.root) == text, "дамп объекта = вход")
    var first = doc.nodes[doc.root].kid
    var last = doc.nodes[doc.root].tail
    check(doc.nodes[first].key == "k0", "первый ребёнок = k0")
    check(doc.nodes[last].key == String("k") + String(n - 1), "хвост = k599")
    check_tree(doc)


def test_nested_and_empty() raises:
    var depth = 40
    var text = nested_json(depth)
    var doc = json_parse(text)
    check(json_dump(doc, doc.root) == text, "вложенный дамп = вход")
    check_tree(doc)

    var empty = json_parse("{\"a\":[],\"b\":{},\"c\":[[]],\"d\":{\"x\":{}}}")
    check(jarray_len(empty, jobject_get(empty, empty.root, "a")) == 0, "[]")
    check(jarray_len(empty, jobject_get(empty, empty.root, "c")) == 1, "[[]]")
    check(
        jkind(empty, jobject_get(empty, empty.root, "b")) == JK_OBJ,
        "{}",
    )
    check_tree(empty)

    var dup = json_parse("{\"a\":1,\"a\":2,\"b\":[3,3,{\"a\":4}]}")
    check(jstr(dup, jobject_get(dup, dup.root, "a")) == "1", "дубликат: первое")
    check(jarray_len(dup, jobject_get(dup, dup.root, "b")) == 3, "b[3]")
    check(
        json_dump(dup, dup.root) == "{\"a\":1,\"a\":2,\"b\":[3,3,{\"a\":4}]}",
        "дубликаты сохранены в порядке",
    )
    check_tree(dup)


def test_depth_guards() raises:
    var ok_text = deep_arrays(128)
    var ok_doc = json_parse(ok_text)
    check(json_dump(ok_doc, ok_doc.root) == ok_text, "глубина 128 допустима")
    check_tree(ok_doc)
    var rejected = False
    try:
        _ = json_parse(deep_arrays(129))
    except:
        rejected = True
    check(rejected, "глубина 129 отвергнута")
    var bad = False
    try:
        _ = json_parse("{\"a\":}")
    except:
        bad = True
    check(bad, "битый JSON — ошибка")
    var trailing = False
    try:
        _ = json_parse("[] x")
    except:
        trailing = True
    check(trailing, "мусор после значения — ошибка")


def measure_scaling() raises:
    print("json scaling (parse only):")
    var sizes = List[Int]()
    sizes.append(20)
    sizes.append(40)
    sizes.append(80)
    sizes.append(160)
    sizes.append(320)
    var max_ms = 0.0
    for si in range(len(sizes)):
        var kb = sizes[si]
        var n = (kb * 1024) / 2
        var text = wide_array_json(n)
        var t0 = perf_counter_ns()
        var doc = json_parse(text)
        var ms = Float64(perf_counter_ns() - t0) / 1000000.0
        check(jarray_len(doc, doc.root) == n, "длина при замере")
        print("  ", kb, " KiB: ", ms, " ms")
        if ms > max_ms:
            max_ms = ms
    # Грубая функциональная граница: квадратичный разбор 320 KiB — минуты,
    # линейный — единицы миллисекунд. Не микробенчмарк.
    check(max_ms < 5000.0, "320 KiB разбираются быстрее 5 c")


def main() raises:
    test_wide_array()
    test_wide_object()
    test_nested_and_empty()
    test_depth_guards()
    measure_scaling()
    print("JSON_TEST OK")
