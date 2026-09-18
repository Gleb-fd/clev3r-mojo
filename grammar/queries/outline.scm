; Outline/structure for Basic Plus in Zed (Outline panel, symbols).
; Format: https://zed.dev/docs/extensions/languages#code-outline-structure

(sub_definition
  name: (_) @name) @item

(function_definition
  name: (_) @name) @item

(label
  name: (_) @name) @item

(include_directive
  path: (_) @name) @item

(import_directive
  path: (_) @name) @item

(folder_directive
  name: (_) @name) @item
