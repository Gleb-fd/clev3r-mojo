; Syntax highlighting for Clev3r Basic Plus in Zed.
; Captures are from Zed's supported set:
; https://zed.dev/docs/extensions/languages#syntax-highlighting

; ---------------------------------------------------------------- keywords ---

[
  (kw_and)
  (kw_break)
  (kw_continue)
  (kw_else)
  (kw_elseif)
  (kw_endfor)
  (kw_endfunction)
  (kw_endif)
  (kw_endsub)
  (kw_endwhile)
  (kw_for)
  (kw_function)
  (kw_folder)
  (kw_goto)
  (kw_if)
  (kw_in)
  (kw_include)
  (kw_import)
  (kw_or)
  (kw_out)
  (kw_private)
  (kw_return)
  (kw_step)
  (kw_sub)
  (kw_then)
  (kw_to)
  (kw_while)
] @keyword

; `number` / `number[]` / `string` / `string[]` occur only as declaration and
; parameter types — style them as types rather than keywords.
[
  (kw_number)
  (kw_number_array)
  (kw_string)
  (kw_string_array)
] @type.builtin

; -------------------------------------------------------- directives/trivia ---

; `'PRAGMA …` and `#…` lines: preprocessor styling with comment fallback
; (Zed resolves multiple captures right-to-left).
(pragma) @comment @preproc
(preprocessor_directive) @comment @preproc

(comment) @comment

; ---------------------------------------------------------------- literals ---

(string) @string

; Boolean literals are strings in Basic Plus: "True" / "False" (any case).
; Zed resolves multiple captures right-to-left: @boolean first, @string fallback.
((string) @string @boolean
  (#match? @boolean "^\"[Tt]([Rr][Uu][Ee]|[Aa][Ll][Ss][Ee])\"$"))

(number) @number

; `folder "prjs" "Name"` — the kind is a fixed keyword-like string.
(folder_directive kind: (folder_kind) @string)

; ------------------------------------------------------------------ names ---

(builtin_object) @type @type.builtin

(identifier) @variable

; Sub calls: `move()`, `map_data(2, d1)`
(call_expression function: (identifier) @function)

; Builtin methods and module methods: `LCD.Text(...)`, `mod.DoIt(...)`
(method_call method: (identifier) @function)
(module_call method: (identifier) @function)

; Properties: `EV3.Time`, `Buttons.Current`, `mod.Counter`
(property property: (identifier) @property)
(module_property property: (identifier) @property)

; Function parameters
(parameter name: (identifier) @variable.parameter)

; Labels and goto targets
(label name: (identifier) @label)
(goto_statement name: (identifier) @label)

; -------------------------------------------------------------- operators ---

[
  "+"
  "-"
  "*"
  "/"
  "="
  "<>"
  "<"
  ">"
  "<="
  ">="
  "++"
  "--"
] @operator

(augmented_operator) @operator

; ------------------------------------------------------------- punctuation ---

[
  "("
  ")"
  "["
  "]"
] @punctuation.bracket

[
  ","
  "."
] @punctuation.delimiter

(global_variable "@" @punctuation.special)
