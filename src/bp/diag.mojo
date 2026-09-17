"""Диагностики компилятора Basic Plus.

Формат сообщений стадий 1-2 (как в C#, DataTemplates/Errore.cs):
    file: {FileName} line: {N} | code: {C} ===> {текст} {Message}

Стадия 3 (Compiler) использует формат:
    {message} at: L:C
"""


@fieldwise_init
struct Diagnostic(Copyable, Movable):
    var file: String
    var line: Int
    var code: Int
    var message: String


@fieldwise_init
struct Diagnostics(Copyable, Movable):
    """Список диагностик с сохранением порядка появления."""

    var items: List[Diagnostic]

    def __init__(out self):
        self.items = List[Diagnostic]()

    def add(mut self, file: String, line: Int, code: Int, message: String):
        self.items.append(Diagnostic(file, line, code, message))

    def has_errors(self) -> Bool:
        return len(self.items) > 0

    def count(self) -> Int:
        return len(self.items)

    def bp_message(self, idx: Int) -> String:
        var d = self.items[idx].copy()
        return (
            "file: "
            + d.file
            + " line: "
            + String(d.line)
            + " | code: "
            + String(d.code)
            + " ===> "
            + d.message
        )

    def render(self) -> String:
        var out = List[String]()
        for i in range(len(self.items)):
            out.append(self.bp_message(i))
        return String("\n").join(out)