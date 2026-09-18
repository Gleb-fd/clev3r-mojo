; Auto-indentation for Basic Plus in Zed.
; Format: https://zed.dev/docs/extensions/languages#auto-indentation
; Verified 2026-09-18 against the live Zed docs: the capture set for
; auto-indentation is @indent / @start / @end / @outdent.
; (`@indent.start` / `@indent.end` is Helix syntax, NOT valid in Zed.)
;
; Blocks are closed by keywords on their own line (EndIf/EndWhile/EndFor/
; EndSub/EndFunction), and ElseIf/Else lines align with the opening If.
; Each range therefore starts after the header keyword and ends before the
; closing keyword, so the closing line itself stays at the parent level.

(if_statement
  (kw_then) @start
  (kw_endif) @end) @indent

; ElseIf/Else lines align with the opening `If` line (the keywords live inside
; elseif_clause/else_clause nodes, not directly under if_statement).
(elseif_clause
  (kw_elseif) @outdent)

(else_clause
  (kw_else) @outdent)

; Bodies of ElseIf/Else clauses indent one level from the If line.
(elseif_clause
  (kw_then) @start) @indent

(else_clause
  (kw_else) @start) @indent

(while_statement
  (kw_while) @start
  (kw_endwhile) @end) @indent

(for_statement
  (kw_for) @start
  (kw_endfor) @end) @indent

(sub_definition
  (kw_sub) @start
  (kw_endsub) @end) @indent

(function_definition
  (kw_function) @start
  (kw_endfunction) @end) @indent
