# Changelog

## 0.1.0 (unreleased)

In-development foundation of the pure Dart bash interpreter.

- Virtual filesystem: `FileSystem` interface and `InMemoryFs` (lazy/async file
  entries, symlinks, hard links, stat/lstat, utf8/ascii/binary/base64/hex/latin1
  encodings). Web-safe — no `dart:io`.
- Lexer: faithful port of the bash tokenizer (operators, quoting, here-docs,
  expansions, fd-variables, extglob, `(( ))` / `[[ ]]` disambiguation).
- AST: full sealed-class node hierarchy.
- Parser: core (script / statement / pipeline / command), command and compound
  parsers, and the word/expansion parsers. Arithmetic, `[[ ]]` conditional, and
  command-substitution sub-parsers are stubbed (throw at the boundary).
- Agent-first docs and pub.dev metadata.

Not yet implemented: the interpreter (script execution), intrinsic builtins,
the `Bash.exec` host API, the `dbash_io` real-filesystem adapter, the CLI, and
the MCP server.
