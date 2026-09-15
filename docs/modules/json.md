# json

Small helpers to escape strings and extract fields from JSON.

Functions
---------

- json_escape input
  - Purpose: Escape backslashes, quotes, and control characters for JSON string context.
  - Behavior: `\` and `"` are backslash-escaped; newline, carriage return and tab become `\n`, `\r`, `\t`; every other character in U+0001-U+001F becomes `\u00XX`. Printed with `printf '%s\n'`, so inputs such as `-n` are output as-is.
  - Returns: escaped string.

- format_response json
  - Purpose: Validate JSON and print its `.response` field.
  - Behavior: Exits non-zero (and logs error) if the input is not valid JSON or is empty.

- format_md_response text
  - Purpose: Strip triple backticks from a response blob for markdown-friendly output.

Dependencies
------------

- `jq` for JSON validation/extraction.

