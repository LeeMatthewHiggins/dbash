// Integration tests: exercise the whole front-half pipeline end to end —
// source -> Lexer -> Parser -> AST — plus the virtual filesystem, the way a
// host (or eventually the interpreter) would drive them together.
import 'package:dbash/dbash.dart';
import 'package:test/test.dart';

/// Reconstruct a word's source-ish text from its parts.
String word(WordNode w) => w.parts.map(_part).join();
String _part(WordPart p) => switch (p) {
      LiteralPart() => p.value,
      SingleQuotedPart() => "'${p.value}'",
      DoubleQuotedPart() => '"${p.parts.map(_part).join()}"',
      EscapedPart() => '\\${p.value}',
      ParameterExpansionPart() => '\$${p.parameter}',
      GlobPart() => p.pattern,
      TildeExpansionPart() => '~${p.user ?? ''}',
      _ => '<${p.type}>',
    };

SimpleCommandNode simple(CommandNode c) => c as SimpleCommandNode;

void main() {
  group('source -> AST end to end', () {
    test('a realistic multi-stage script parses fully', () {
      const src =
          'name=World\n'
          'echo "Hello, \$name" | tr a-z A-Z > /tmp/out.txt\n'
          r'for f in *.dart; do echo "$f"; done';

      final script = parse(src);
      expect(script.statements, hasLength(3));

      // Statement 1: assignment-only command.
      final s1 = simple(script.statements[0].pipelines.single.commands.single);
      expect(s1.name, isNull);
      expect(s1.assignments.single.name, 'name');
      expect(word(s1.assignments.single.value!), 'World');

      // Statement 2: a two-command pipeline with a redirection.
      final pipe = script.statements[1].pipelines.single;
      expect(pipe.commands, hasLength(2));
      final echo = simple(pipe.commands[0]);
      expect(word(echo.name!), 'echo');
      final dq = echo.args.single.parts.single as DoubleQuotedPart;
      expect(dq.parts.whereType<ParameterExpansionPart>().single.parameter,
          'name');
      final tr = simple(pipe.commands[1]);
      expect(word(tr.name!), 'tr');
      expect(tr.redirections.single.operator, '>');
      expect(word(tr.redirections.single.target as WordNode), '/tmp/out.txt');

      // Statement 3: a for loop with a glob list.
      final loop = script.statements[2].pipelines.single.commands.single
          as ForNode;
      expect(loop.variable, 'f');
      expect((loop.words!.single.parts.first as GlobPart).pattern, '*');
      expect(loop.body, hasLength(1));
    });

    test('lexer and parser agree on token boundaries', () {
      const src = 'grep -n "TODO" src/ | wc -l';
      final tokens = Lexer(src).tokenize();
      // Lexer sees: grep -n "TODO" src/ | wc -l  + EOF
      expect(tokens.where((t) => t.type == TokenType.pipe), hasLength(1));

      final pipe = parse(src).statements.single.pipelines.single;
      expect(pipe.commands, hasLength(2));
      expect(word(simple(pipe.commands[0]).name!), 'grep');
      expect(word(simple(pipe.commands[1]).name!), 'wc');
    });

    test('and-or list with background', () {
      final stmt = parse('make && ./run.sh || echo failed &').statements.single;
      expect(stmt.pipelines, hasLength(3));
      expect(stmt.operators, ['&&', '||']);
      expect(stmt.background, isTrue);
    });

    test('parameter expansion operations survive end to end', () {
      final c = simple(parse(r'cp ${SRC:-./a} ${DEST%/}')
          .statements.single.pipelines.single.commands.single);
      final src = c.args[0].parts.single as ParameterExpansionPart;
      final dest = c.args[1].parts.single as ParameterExpansionPart;
      expect(src.operation, isA<DefaultValueOp>());
      expect(dest.operation, isA<PatternRemovalOp>());
    });
  });

  group('virtual filesystem workflow', () {
    test('create, write, read, list, stat, symlink round-trip', () async {
      final fs = InMemoryFs({'/proj/README.md': '# Title\n'});

      await fs.mkdir('/proj/src', recursive: true);
      await fs.writeFile('/proj/src/app.dart', 'void main() {}\n');
      await fs.appendFile('/proj/README.md', 'body\n');

      expect(await fs.readdir('/proj'), ['README.md', 'src']);
      expect(await fs.readdir('/proj/src'), ['app.dart']);
      expect(await fs.readFile('/proj/README.md'), '# Title\nbody\n');

      final stat = await fs.stat('/proj/src/app.dart');
      expect(stat.isFile, isTrue);
      expect(stat.size, 'void main() {}\n'.length);

      await fs.symlink('/proj/README.md', '/proj/READMElink');
      expect(await fs.readlink('/proj/READMElink'), '/proj/README.md');
      expect(await fs.readFile('/proj/READMElink'), '# Title\nbody\n');

      await fs.rm('/proj/src', recursive: true);
      expect(await fs.exists('/proj/src'), isFalse);
    });

    test('binary content and encodings round-trip', () async {
      final fs = InMemoryFs();
      await fs.writeFile('/b.bin', 'SGVsbG8=', encoding: BufferEncoding.base64);
      expect(await fs.readFile('/b.bin'), 'Hello');
      expect(
        await fs.readFile('/b.bin', encoding: BufferEncoding.hex),
        '48656c6c6f',
      );
    });
  });

  group('error and boundary behavior', () {
    test('syntax error surfaces as ParseException', () {
      expect(() => parse('if true; then'), throwsA(isA<ParseException>()));
    });

    test('missing file surfaces as FsException', () {
      final fs = InMemoryFs();
      expect(() => fs.readFile('/nope'), throwsA(isA<FsException>()));
    });
  });
}
