# dbash

**A pure Dart bash interpreter with a virtual filesystem — a sandboxed shell for AI agents and Dart/Flutter apps.**

`dbash` is a from-scratch Dart port of [just-bash](https://github.com/vercel-labs/just-bash) ("Bash for Agents"). It runs bash scripts against an in-memory virtual filesystem with **no real disk or network access by default**, making it safe to hand to an LLM agent as a tool. The core is web-safe (no `dart:io`), so it runs on native, server, and Flutter — including Flutter web.

> [!IMPORTANT]
> **Status: in active development.** The virtual filesystem, lexer, AST, and most of the parser are implemented and tested. The interpreter (script execution), intrinsic builtins, the `Bash.exec` host API, the CLI, and the MCP server are not built yet — see the [roadmap](#roadmap). Today the package is useful for *parsing* bash into an AST; it cannot yet *run* scripts. APIs below marked _(planned)_ describe the intended surface.

## Why dbash

- **Agent-safe sandbox.** Scripts touch only an in-memory filesystem you provide. No host disk, no network unless you explicitly allow-list it.
- **Pure Dart, runs everywhere.** The engine never imports `dart:io`; real-filesystem mounts live in a separate optional `dbash_io` library.
- **Faithful to bash.** Ported 1:1 from just-bash, with its test cases as the conformance target.
- **Host-extensible.** Bring your own commands with a `defineCommand` API _(planned)_ — expose domain tools to the shell (and to agents) without forking.

## Install

```yaml
dependencies:
  dbash: ^0.1.0
```

```sh
dart pub add dbash
```

## Usage today: parse bash to an AST

```dart
import 'package:dbash/dbash.dart';

void main() {
  final script = parse('echo "hello \$USER" | grep hello > out.txt');
  // Walk the AST: statements -> pipelines -> commands -> word parts.
  print(script.statements.length); // 1
}
```

The lexer and virtual filesystem are also usable directly:

```dart
import 'package:dbash/dbash.dart';

Future<void> main() async {
  final fs = InMemoryFs({'/data/greeting.txt': 'hi'});
  print(await fs.readFile('/data/greeting.txt')); // hi

  final tokens = Lexer('for i in 1 2 3; do echo \$i; done').tokenize();
  print(tokens.length);
}
```

## Usage _(planned)_: run scripts

```dart
import 'package:dbash/dbash.dart';

Future<void> main() async {
  final bash = Bash(files: {'/data/file.txt': 'content'});
  final result = await bash.exec('cat /data/file.txt');
  print(result.stdout);   // content
  print(result.exitCode); // 0
}
```

## For AI agents _(planned)_

dbash is designed to be an agent tool. The intended distribution surfaces:

- **Dart library** — embed the sandbox in a Dart/Flutter agent; give the model a `bash` tool backed by `Bash.exec`.
- **CLI** — `dart pub global activate dbash` provides a `dbash` command (`dbash -c 'ls -la'`); `dart compile exe bin/dbash.dart` produces a standalone binary to drop into an agent's sandbox.
- **MCP server** — a [Model Context Protocol](https://modelcontextprotocol.io) server exposing a single high-signal `bash` tool (`{ script } -> { stdout, stderr, exitCode }`) over stdio, discoverable through the MCP registries.

See [`AGENTS.md`](AGENTS.md) for how coding agents should work in this repo, and [`llms.txt`](llms.txt) for a documentation index.

## Roadmap

| Stage | Status |
|---|---|
| Virtual filesystem (`InMemoryFs`) | ✅ |
| Lexer | ✅ |
| AST | ✅ |
| Parser (core + words/expansions) | 🟡 in progress |
| Interpreter (execution) | ⬜ planned |
| Intrinsic builtins (`cd`, `export`, …) | ⬜ planned |
| `Bash.exec` host API + `defineCommand` | ⬜ planned |
| `dbash_io` (real-FS overlay) + CLI | ⬜ planned |
| MCP server + registry listing | ⬜ planned |

## License & attribution

Apache-2.0. `dbash` is a derivative work of [just-bash](https://github.com/vercel-labs/just-bash) by Vercel Labs — see [`NOTICE.md`](NOTICE.md).
