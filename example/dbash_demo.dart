// A runnable walkthrough of what dbash can do today: tokenize and parse bash
// into an AST, and use the in-memory virtual filesystem.
//
// Run with:  dart run example/dbash_demo.dart
//
// Note: the interpreter is not built yet, so scripts are parsed, not executed.
// ignore_for_file: avoid_print, lines_longer_than_80_chars
// ignore_for_file: avoid_catching_errors
import 'package:dbash/dbash.dart';

void main() async {
  _header('1. Lexer — bash source to tokens');
  _lexerDemo();

  _header('2. Parser — bash source to an AST');
  _parserDemo();

  _header('3. Virtual filesystem — sandboxed, in-memory');
  await _filesystemDemo();

  _header('4. Executing scripts — Bash.exec');
  await _execDemo();
}

void _lexerDemo() {
  const src = r'echo "hi $USER" | grep hi > out.txt';
  print('source:  $src\n');
  for (final t in Lexer(src).tokenize()) {
    if (t.type == TokenType.eof) continue;
    print('  ${t.type.name.padRight(16)} ${_q(t.value)}');
  }
}

void _parserDemo() {
  const scripts = [
    r'echo "hello $USER"',
    r'name=World; echo "Hello, $name!"',
    'ls *.txt {a,b}.md ~/docs',
    'cat < in.txt | sort -r > out.txt 2>&1',
    r'for i in 1 2 3; do echo $i; done',
    'if test -f config; then echo found; else echo missing; fi',
    r'result=${VALUE:-default}',
  ];
  for (final src in scripts) {
    print('\nsource:  $src');
    final script = parse(src);
    for (final stmt in script.statements) {
      _printStatement(stmt, '  ');
    }
  }
}

Future<void> _filesystemDemo() async {
  final fs = InMemoryFs({
    '/project/README.md': '# Demo\n',
    '/project/data.csv': 'a,b\n1,2\n',
  });

  await fs.mkdir('/project/src', recursive: true);
  await fs.writeFile('/project/src/main.dart', 'void main() {}\n');
  await fs.appendFile('/project/README.md', 'more text\n');

  print('tree under /project:');
  await _printTree(fs, '/project', '  ');

  print('\nread /project/README.md:');
  print('  ${(await fs.readFile('/project/README.md')).trimRight()}'
      .replaceAll('\n', '\n  '));

  final stat = await fs.stat('/project/data.csv');
  print('\nstat /project/data.csv: ${stat.size} bytes, '
      'mode ${stat.mode.toRadixString(8)}');

  await fs.symlink('/project/README.md', '/project/LINK');
  print('readlink /project/LINK -> ${await fs.readlink('/project/LINK')}');
}

Future<void> _execDemo() async {
  final bash = Bash(files: {'/etc/hosts': '127.0.0.1 localhost\n'});
  const scripts = [
    r'name=World; echo "Hello, $name!"',
    r'echo $((6 * 7)) is the answer',
    r'for i in 1 2 3; do echo "row $i"; done',
    'if [[ -f /etc/hosts ]]; then echo "hosts exists"; fi',
    r'v=2; case $v in 1) echo one;; 2) echo two;; *) echo other;; esac',
    r'echo "today is $(echo Tuesday)"',
  ];
  for (final src in scripts) {
    final r = await bash.exec(src);
    print('\$ $src');
    if (r.stdout.isNotEmpty) print('  ${r.stdout.trimRight()}');
  }
}

// --- tiny AST + FS renderers (demo only) -----------------------------------

void _printStatement(StatementNode stmt, String indent) {
  final bg = stmt.background ? ' &' : '';
  print('${indent}Statement$bg');
  for (var i = 0; i < stmt.pipelines.length; i++) {
    if (i > 0) print('$indent  ${stmt.operators[i - 1]}');
    _printPipeline(stmt.pipelines[i], '$indent  ');
  }
}

void _printPipeline(PipelineNode pipe, String indent) {
  final neg = pipe.negated ? '! ' : '';
  print('$indent${neg}Pipeline (${pipe.commands.length} command(s))');
  for (final cmd in pipe.commands) {
    _printCommand(cmd, '$indent  ');
  }
}

void _printCommand(CommandNode cmd, String indent) {
  switch (cmd) {
    case SimpleCommandNode():
      final name = cmd.name == null ? '(none)' : _word(cmd.name!);
      print('${indent}Command: $name');
      for (final a in cmd.assignments) {
        print('$indent  assign: ${a.name}=${a.value == null ? '' : _word(a.value!)}');
      }
      for (final a in cmd.args) {
        print('$indent  arg: ${_word(a)}  ${_wordParts(a)}');
      }
      for (final r in cmd.redirections) {
        final tgt = r.target is WordNode ? _word(r.target as WordNode) : '<heredoc>';
        final fd = r.fd ?? '';
    print('$indent  redir: $fd${r.operator} $tgt');
      }
    case IfNode():
      print('${indent}If (${cmd.clauses.length} clause(s), '
          'else: ${cmd.elseBody != null})');
    case ForNode():
      print('${indent}For ${cmd.variable} in '
          '${cmd.words?.map(_word).join(' ') ?? r'"$@"'} '
          '(body: ${cmd.body.length} stmt)');
    case WhileNode():
      print('${indent}While (body: ${cmd.body.length} stmt)');
    default:
      print('$indent${cmd.type}');
  }
}

/// Reconstruct a word's source-ish text.
String _word(WordNode w) => w.parts.map(_part).join();

String _part(WordPart p) => switch (p) {
      LiteralPart() => p.value,
      SingleQuotedPart() => "'${p.value}'",
      DoubleQuotedPart() => '"${p.parts.map(_part).join()}"',
      EscapedPart() => '\\${p.value}',
      ParameterExpansionPart() =>
        p.operation == null ? '\$${p.parameter}' : '\${${p.parameter}...}',
      GlobPart() => p.pattern,
      BraceExpansionPart() => '{...}',
      TildeExpansionPart() => '~${p.user ?? ''}',
      _ => '<${p.type}>',
    };

/// Summarize the part kinds making up a word.
String _wordParts(WordNode w) =>
    '[${w.parts.map((p) => p.type).join(', ')}]';

Future<void> _printTree(FileSystem fs, String dir, String indent) async {
  for (final entry in await fs.readdirWithFileTypes(dir)) {
    final path = dir == '/' ? '/${entry.name}' : '$dir/${entry.name}';
    final marker = entry.isDirectory ? '/' : '';
    print('$indent${entry.name}$marker');
    if (entry.isDirectory) {
      await _printTree(fs, path, '$indent  ');
    }
  }
}

String _q(String s) => "'${s.replaceAll('\n', r'\n')}'";

void _header(String title) {
  print('\n${'=' * 64}\n$title\n${'=' * 64}');
}
