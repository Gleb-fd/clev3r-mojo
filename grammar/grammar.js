/**
 * Tree-sitter grammar for Clev3r Basic Plus — the EV3 Basic dialect used by
 * Clev3r (files: .bp programs, .bpi includes, .bpm modules).
 *
 * Sources of truth:
 *   - docs/01-lexer-and-grammar.md  (§2 line model, §4 keywords/classes,
 *     §6 statement grammar, §7 literals, §8 stage-3 expression grammar)
 *   - tests/corpus (44 real programs, dot-bp / dot-bpi / dot-bpm)
 *
 * Language model reflected here:
 *   - One statement per line: the newline is a real token (`_newline`),
 *     blocks are sequences of lines closed by End…/Else keywords.
 *   - Case-insensitive everywhere (keywords, identifiers, builtin classes,
 *     "True"/"false", folder kinds) — implemented with per-letter character
 *     classes so no regex flags are needed.
 *   - Comments run from `'` to end of line (rule `comment`, declared as an
 *     extra so they may trail any statement). `'PRAGMA …` is matched first as
 *     a dedicated `pragma` statement (same length as a comment, higher lexical
 *     precedence wins at statement position, matching Compiler/Scanner.cs).
 *   - `'` inside a string literal stays inside the string here (the real
 *     stage-1 lexer cuts the comment first — see docs/01 §2 — but treating the
 *     string as one token is friendlier for editing and parses every corpus
 *     file identically).
 *
 * Statement-level leniencies (supersets of the real compiler, kept so that
 * hand-written code does not show ERROR nodes while editing):
 *   - trailing commas in argument/parameter lists (Byte.bp: `Byte.NOT(33,)`);
 *   - `x[i] += e` / `@g[i] -= e` (the compiler only allows `x[i] = e`);
 *   - identifiers starting with `_`.
 */

'use strict';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Escape one character for use inside a tree-sitter regex. */
function escChar(ch) {
  return /[a-zA-Z0-9]/.test(ch) ? ch : '\\' + ch;
}

/**
 * Case-insensitive regex source for an ASCII word:
 * 'endif' -> '[eE][nN][dD][iI][fF]'.
 */
function ci(word) {
  let out = '';
  for (const ch of word) {
    if (/[a-z]/i.test(ch)) out += `[${ch.toLowerCase()}${ch.toUpperCase()}]`;
    else out += escChar(ch);
  }
  return out;
}

/** Keyword rule name: 'number[]' -> 'kw_number_array'. */
function kwName(word) {
  return 'kw_' + word.toLowerCase().replace('[]', '_array').replace(/[^a-z0-9_]/g, '');
}

// The 32 keywords of Basic Plus (docs/01 §4, TokenBuilder.cs:51).
// `region`/`endregion` only ever occur inside `#…` lines, which are consumed
// whole by `preprocessor_directive`, so they get no dedicated rule.
const KEYWORDS = [
  'for', 'endfor', 'if', 'then', 'endif', 'else', 'elseif',
  'while', 'endwhile', 'and', 'or', 'sub', 'endsub', 'goto', 'step', 'to',
  'import', 'include', 'folder', 'in', 'out',
  'function', 'endfunction', 'number', 'number[]', 'string', 'string[]',
  'private', 'break', 'continue', 'return',
];

// The 31 builtin object classes (docs/01 §4, TokenBuilder.cs:267-300).
// Longest names first so `motorab` wins over `motor`, `ev3file` over `ev3`,
// `sensor1` over `sensor` regardless of the regex engine's tie-breaking.
const BUILTIN_CLASSES = [
  'assert', 'buttons', 'byte', 'ev3file', 'ev3', 'lcd', 'mailbox', 'math',
  'motorab', 'motorac', 'motorad', 'motorbc', 'motorbd', 'motorcd',
  'motora', 'motorb', 'motorc', 'motord', 'motor',
  'program', 'row', 'sensor1', 'sensor2', 'sensor3', 'sensor4', 'sensor',
  'speaker', 'text', 'thread', 'time', 'vector',
];

// Keyword rules are generated: (kw_if) @keyword etc. in queries/highlights.scm.
const keywordRules = {};
for (const word of KEYWORDS) {
  keywordRules[kwName(word)] = () => token(prec(1, new RegExp(ci(word))));
}

// Operator precedence (docs/01 §8.4, lowest binds loosest).
const PREC = {
  OR: 1,
  AND: 2,
  COMPARE: 3,
  ADD: 4,
  MULTIPLY: 5,
  UNARY: 6,
  CALL: 7,
  MEMBER: 8,
};

// ---------------------------------------------------------------------------
// Grammar
// ---------------------------------------------------------------------------

module.exports = grammar({
  name: 'basic_plus',

  // Spaces/tabs separate words; comments may appear anywhere between tokens.
  // The newline is NOT an extra — it terminates statements.
  extras: $ => [
    /[ \t]+/,
    $.comment,
  ],

  // Enables keyword extraction and better "missing identifier" errors.
  word: $ => $.identifier,

  rules: {
    // NOTE: the FIRST rule of this object is the tree-sitter start symbol, so
    // `source_file` must stay at the top — do not move the keywordRules
    // spread above it.
    source_file: $ => seq(repeat($._line), optional($._statement)),

    ...keywordRules,

    // Every statement form of the language. Order does not matter for
    // precedence, only for readability; disambiguation is lexical (the token
    // after the first word decides which rule applies).
    _statement: $ => choice(
      // file directives
      $.folder_directive,
      $.include_directive,
      $.import_directive,
      $.pragma,
      $.preprocessor_directive,
      // definitions
      $.sub_definition,
      $.function_definition,
      // control flow
      $.if_statement,
      $.while_statement,
      $.for_statement,
      $.goto_statement,
      $.label,
      $.break_statement,
      $.continue_statement,
      $.return_statement,
      $.private_statement,
      // declarations & simple statements
      $.variable_declaration,
      $.property_assignment,
      $.array_assignment,
      $.augmented_assignment,
      $.inc_statement,
      $.assignment,
      $.call_expression,
      $.method_call,
      $.module_call,
    ),

    _line: $ => choice($._newline, seq($._statement, $._newline)),

    // A block is a non-empty sequence of lines; used as the body of every
    // End…-closed construct. `optional($._statement)` covers a body whose
    // last line has no trailing newline (end of file / mid-edit). Use sites
    // wrap it in `optional()` so empty bodies (`Sub X` + `EndSub`) parse.
    _block: $ => seq(repeat1($._line), optional($._statement)),

    _newline: $ => /\r?\n|\r/,

    // -- file directives (docs/01 §6.2) -------------------------------------

    folder_directive: $ => seq(
      field('keyword', $.kw_folder),
      field('kind', $.folder_kind),   // "prjs" | "sd"
      field('name', $.string),        // project name, <= 32 chars
    ),

    folder_kind: $ => token(choice(
      new RegExp(`"${ci('prjs')}"`),
      new RegExp(`"${ci('sd')}"`),
    )),

    include_directive: $ => seq(
      field('keyword', $.kw_include),
      field('path', $.string),
    ),

    import_directive: $ => seq(
      field('keyword', $.kw_import),
      field('path', $.string),
    ),

    // `'PRAGMA NOBOUNDSCHECK` / BOUNDSCHECK / NODIVISIONCHECK / DIVISIONCHECK.
    // Matched as one token of the same length as a comment, with higher
    // lexical precedence so it wins at statement position (docs/01 §2, §8.1).
    pragma: $ => token(prec(1, new RegExp(
      `'${ci('PRAGMA')}([ \\t]+[^\\r\\n]*)?`,
    ))),

    // `#…` lines (#region/#endregion and any IDE directive) are ignored by the
    // compiler stages; consumed whole as a single token.
    preprocessor_directive: $ => token(prec(1, /#[^\r\n]*/)),

    // -- definitions (docs/01 §6.3) ------------------------------------------

    sub_definition: $ => seq(
      field('keyword', $.kw_sub),
      field('name', $._name),
      $._newline,
      optional($._block),
      field('end', $.kw_endsub),
    ),

    // `Function map_data(in number n, out number data)` … `EndFunction`
    function_definition: $ => seq(
      field('keyword', $.kw_function),
      field('name', $._name),
      field('parameters', $.parameter_list),
      $._newline,
      optional($._block),
      field('end', $.kw_endfunction),
    ),

    parameter_list: $ => seq(
      '(',
      optional(seq(
        $.parameter,
        repeat(seq(',', $.parameter)),
        optional(','),
      )),
      ')',
    ),

    parameter: $ => seq(
      field('direction', choice($.kw_in, $.kw_out)),
      field('type', $._type),
      field('name', $._name),
    ),

    // -- control flow (docs/01 §6.1, §6.5) ------------------------------------

    if_statement: $ => seq(
      field('keyword', $.kw_if),
      field('condition', $._expression),
      field('then', $.kw_then),
      $._newline,
      optional($._block),
      repeat($.elseif_clause),
      optional($.else_clause),
      field('end', $.kw_endif),
    ),

    elseif_clause: $ => seq(
      field('keyword', $.kw_elseif),
      field('condition', $._expression),
      field('then', $.kw_then),
      $._newline,
      optional($._block),
    ),

    else_clause: $ => seq(
      field('keyword', $.kw_else),
      $._newline,
      optional($._block),
    ),

    while_statement: $ => seq(
      field('keyword', $.kw_while),
      field('condition', $._expression),
      $._newline,
      optional($._block),
      field('end', $.kw_endwhile),
    ),

    // `For v = from To to [Step step]` … `EndFor`
    for_statement: $ => seq(
      field('keyword', $.kw_for),
      field('variable', $._name),
      '=',
      field('from', $._expression),
      field('to', $.kw_to),
      field('to_value', $._expression),
      optional(seq(
        field('step', $.kw_step),
        field('step_value', $._expression),
      )),
      $._newline,
      optional($._block),
      field('end', $.kw_endfor),
    ),

    goto_statement: $ => seq(
      field('keyword', $.kw_goto),
      field('name', $._name),
    ),

    // A label is a lone `name:` line (docs/01 §6.1).
    label: $ => seq(
      field('name', $._name),
      ':',
    ),

    break_statement: $ => $.kw_break,
    continue_statement: $ => $.kw_continue,
    return_statement: $ => $.kw_return,

    // A lone `private` line (ONEKEYWORD in docs/01 §5).
    private_statement: $ => $.kw_private,

    // -- declarations (.bpm module properties, docs/01 §1.2) ------------------

    variable_declaration: $ => seq(
      field('type', $._type),
      field('name', $._name),
    ),

    // -- simple statements (docs/01 §6.4, §6.6) -------------------------------

    assignment: $ => seq(
      field('left', $._simple_target),
      field('operator', '='),
      field('right', $._expression),
    ),

    // `x += e` and friends; `x[i] += e` is allowed here although the real
    // compiler rejects it (docs/01 §11.5) — leniency for editing.
    augmented_assignment: $ => seq(
      field('left', choice($._simple_target, $._array_target)),
      field('operator', $.augmented_operator),
      field('right', $._expression),
    ),

    augmented_operator: $ => choice('+=', '-=', '*=', '/='),

    // `x++` / `x--` (VARDOUBLEMATH); only plain variables in the real language.
    inc_statement: $ => seq(
      field('operand', $._simple_target),
      field('operator', choice('++', '--')),
    ),

    // `x[i] = e` (VARARRAYINIT).
    array_assignment: $ => seq(
      field('left', $._array_target),
      field('operator', '='),
      field('right', $._expression),
    ),

    // `thread.run = SUB2`, `f.start = id`, `mod.prop = e`.
    property_assignment: $ => seq(
      field('left', $._member_target),
      field('operator', '='),
      field('right', $._expression),
    ),

    // -- expressions (docs/01 §6.4, §8.4) --------------------------------------

    _expression: $ => choice(
      $.binary_expression,
      $.unary_expression,
      $.parenthesized_expression,
      $._atom,
    ),

    _atom: $ => choice(
      $.number,
      $.string,
      $.identifier,
      $.builtin_object,
      $.global_variable,
      $.array_reference,
      $.call_expression,
      $.method_call,
      $.module_call,
      $.property,
      $.module_property,
    ),

    binary_expression: $ => choice(
      prec.left(PREC.OR, seq(
        field('left', $._expression),
        field('operator', $.kw_or),
        field('right', $._expression),
      )),
      prec.left(PREC.AND, seq(
        field('left', $._expression),
        field('operator', $.kw_and),
        field('right', $._expression),
      )),
      prec.left(PREC.COMPARE, seq(
        field('left', $._expression),
        field('operator', choice('=', '<>', '<', '>', '<=', '>=')),
        field('right', $._expression),
      )),
      prec.left(PREC.ADD, seq(
        field('left', $._expression),
        field('operator', choice('+', '-')),
        field('right', $._expression),
      )),
      prec.left(PREC.MULTIPLY, seq(
        field('left', $._expression),
        field('operator', choice('*', '/')),
        field('right', $._expression),
      )),
    ),

    // Unary minus only; there is no unary `+` (docs/01 §8.4 level 6).
    unary_expression: $ => prec(PREC.UNARY, seq(
      '-',
      field('operand', $._expression),
    )),

    parenthesized_expression: $ => seq(
      '(',
      field('expression', $._expression),
      ')',
    ),

    // Sub call: `move()`, `map_data(2, d1)`.
    call_expression: $ => prec(PREC.CALL, seq(
      field('function', $._name),
      field('arguments', $.argument_list),
    )),

    // Builtin class member call: `LCD.Text(...)`, `Math.Floor(...)`.
    method_call: $ => prec(PREC.CALL, seq(
      field('object', $.builtin_object),
      '.',
      field('method', $.identifier),
      field('arguments', $.argument_list),
    )),

    // User module member call: `MyModule.DoIt(...)`.
    module_call: $ => prec(PREC.CALL, seq(
      field('object', $.identifier),
      '.',
      field('method', $.identifier),
      field('arguments', $.argument_list),
    )),

    // Builtin class property read: `EV3.Time`, `Buttons.Current`.
    property: $ => prec(PREC.MEMBER, seq(
      field('object', $.builtin_object),
      '.',
      field('property', $.identifier),
    )),

    // User module property read: `MyModule.Counter`.
    module_property: $ => prec(PREC.MEMBER, seq(
      field('object', $.identifier),
      '.',
      field('property', $.identifier),
    )),

    array_reference: $ => prec(PREC.MEMBER, seq(
      field('array', $._variable_atom),
      '[',
      field('index', $._expression),
      ']',
    )),

    // `@name` — access to a global variable from inside a Function.
    global_variable: $ => seq(
      '@',
      field('name', $._name),
    ),

    argument_list: $ => seq(
      '(',
      optional(seq(
        $._expression,
        repeat(seq(',', $._expression)),
        optional(','),   // trailing comma: Byte.bp `Byte.NOT(33,)`
      )),
      ')',
    ),

    // -- shared building blocks ------------------------------------------------

    _name: $ => choice($.identifier, $.builtin_object),

    _variable_atom: $ => choice($.identifier, $.builtin_object, $.global_variable),

    _simple_target: $ => choice($.identifier, $.builtin_object, $.global_variable),

    _array_target: $ => seq(
      field('array', $._variable_atom),
      '[',
      field('index', $._expression),
      ']',
    ),

    _member_target: $ => choice(
      seq(field('object', $.builtin_object), '.', field('property', $.identifier)),
      seq(field('object', $.identifier), '.', field('property', $.identifier)),
    ),

    _type: $ => choice(
      $.kw_number,
      $.kw_number_array,
      $.kw_string,
      $.kw_string_array,
    ),

    // -- literals & trivia ------------------------------------------------------

    // `[0-9]([0-9.])*` per docs/01 §7: `2.5`, `5.`; no leading-dot form,
    // no sign (unary minus is part of the grammar), no hex literals.
    number: $ => /[0-9]+(\.[0-9]*)?/,

    // `"…"`; a doubled quote `""` inside continues the string (docs/01 §7).
    // The second alternative keeps unterminated strings (while typing or at
    // an apostrophe-cut line) a single node instead of an ERROR.
    string: $ => token(choice(
      /"([^"\r\n]|"")*"/,
      /"([^"\r\n]|"")*/,
    )),

    // `'` to end of line; `'#…` directive-comments are just comments.
    comment: $ => token(/'[^\r\n]*/),

    // -- tokens ------------------------------------------------------------------

    identifier: $ => /[a-zA-Z_][a-zA-Z0-9_]*/,

    builtin_object: $ => token(prec(1, new RegExp(
      BUILTIN_CLASSES.map(ci).join('|'),
    ))),
  },
});
