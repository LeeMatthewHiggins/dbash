# AGENTS.md

Operational guide for AI coding agents working in this repository. (Human
contributors: this is just as useful as a quick-start.)

## What this project is

`dbash` is a from-scratch **pure Dart port of [just-bash](https://github.com/vercel-labs/just-bash)** — a bash interpreter with an in-memory virtual filesystem, designed as a sandboxed shell for AI agents. The port is **faithful 1:1**: behavior should match just-bash, and upstream's own test cases are the conformance target.

A read-only reference clone of the upstream TypeScript source lives in
`legacy-source/just-bash/` (git-ignored). **When porting a module, read the
corresponding upstream file there first** and mirror its logic.

## Commands

```sh
dart pub get        # install dependencies
dart analyze        # must be clean (very_good_analysis); CI-blocking
dart test           # run the unit + conformance suites
dart format .       # format before committing
```

Run a single test file: `dart test test/unit/lexer_test.dart`.

## Architecture (pipeline)

```
input → Lexer (lib/src/parser/lexer.dart)
      → Parser (lib/src/parser/parser.dart + part files)
      → AST   (lib/src/ast/ast.dart)
      → Interpreter (planned)
      → ExecResult
```

- `lib/src/fs/` — virtual filesystem (`FileSystem`, `InMemoryFs`, path/encoding helpers). **Web-safe: never import `dart:io` here.**
- `lib/src/parser/` — lexer, tokens, AST is in `lib/src/ast/`. The parser is **one library split across `part` files** (`command_parser.dart`, `compound_parser.dart`, `expansion_parser.dart`, `word_parser.dart`, `arithmetic_parser.dart`, `conditional_parser.dart`, `parser_substitution.dart`) so sub-parsers share the `Parser` instance, mirroring upstream's module layout.
- `lib/dbash.dart` — public, web-safe entry point. Real-filesystem mounts will live in `lib/dbash_io.dart` (planned), which is the only place allowed to import `dart:io`.

## Conventions (must follow)

- **Lint:** `very_good_analysis`; `dart analyze` must report no issues. Mechanical ports may disable a *small* set of stylistic lints file-wide with a documented `// ignore_for_file:` (e.g. `lines_longer_than_80_chars`, `use_string_buffers`) — keep these minimal.
- **Faithfulness:** match bash/just-bash behavior, not convenience. Mirror upstream control flow closely; don't "improve" semantics.
- **Web safety:** the core (`lib/dbash.dart` + `lib/src/**` except the future `fs_io/`) must never import `dart:io`.
- **Stubs are explicit:** unported boundaries throw `UnimplementedError` and are covered by "throws at boundary X" tests so gaps are visible, not silent.
- **Tests:** every ported module ships tests. FS/AST/parser tests are translated from upstream's own cases — no Node/pnpm dependency.
- **Numbers:** bash arithmetic uses 64-bit-ish integers; upstream "explicitly doesn't support 64-bit integers" (JS doubles) — mirror that in the arithmetic evaluator.

## Commit / PR conventions

- Conventional Commits (`feat:`, `fix:`, `test:`, `chore:`, …).
- Do **not** add AI/tool branding or `Co-Authored-By` trailers to commits.
- Keep `dart analyze` clean and `dart test` green before pushing.

## Current status

See [README.md](README.md#roadmap). FS + lexer + AST done; parser in progress
(word/expansion ported; arithmetic / conditional / substitution stubbed); the
interpreter and agent-facing surfaces (CLI, MCP server) are not built yet.
