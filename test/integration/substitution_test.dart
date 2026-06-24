// Command and backtick substitution: $(...) and `...` run end to end.
import 'package:dbash/dbash.dart';
import 'package:test/test.dart';

void main() {
  group('word splitting of unquoted substitution (review: kumar)', () {
    test('leading/trailing IFS whitespace produces no empty fields', () async {
      final r = await Bash().exec(
        r'for w in $(echo "  a  "); do echo "[$w]"; done',
      );
      expect(r.stdout, '[a]\n');
    });

    test('interior whitespace splits; neighbours stay joined', () async {
      final r = await Bash(env: {'U': ' a '}).exec(
        r'for w in x${U}y; do echo "[$w]"; done',
      );
      expect(r.stdout, '[x]\n[a]\n[y]\n');
    });

    test('whitespace-only substitution yields no fields', () async {
      final r = await Bash().exec(
        r'n=0; for w in $(echo "   "); do n=1; done; echo $n',
      );
      expect(r.stdout, '0\n');
    });
  });

  group('backtick escapes and quoting (review: data)', () {
    test('backtick inside double quotes', () async {
      expect((await Bash().exec('echo "x=`echo hi`"')).stdout, 'x=hi\n');
    });

    test(r'\$ escape inside backticks defers expansion to the inner shell',
        () async {
      // `echo \$HOME` -> inner command is `echo $HOME` -> HOME value.
      expect((await Bash().exec(r'echo `echo \$HOME`')).stdout, '/home/user\n');
    });

    test(r'\" escape is special only inside double quotes', () async {
      final r = await Bash().exec(r'echo "`echo \"hi\"`"');
      expect(r.stdout, 'hi\n');
    });
  });

  group('error boundaries (review: data)', () {
    test(r'unterminated $( throws ParseException', () {
      expect(() => Bash().exec(r'echo $(echo hi'),
          throwsA(isA<ParseException>()));
    });

    test('unterminated backtick throws ParseException', () {
      expect(() => Bash().exec('echo `echo hi'),
          throwsA(isA<ParseException>()));
    });
  });

  group('parser-level disambiguation (review: data)', () {
    test(r'$(( with inner subshell parses as command substitution', () {
      final cmd = parse(r'echo $((echo a); (echo b))')
          .statements.single.pipelines.single.commands.single
          as SimpleCommandNode;
      expect(cmd.args.single.parts.single, isA<CommandSubstitutionPart>());
    });
  });

  group('propagation and trimming (review: data)', () {
    test('stderr from a substitution propagates', () async {
      final r = await Bash().exec(r'x=$(nosuchcmd); echo after');
      expect(r.stdout, 'after\n');
      expect(r.stderr, contains('command not found'));
    });

    test('only trailing newlines are stripped — trailing spaces stay',
        () async {
      final r = await Bash().exec(r'''x=$(printf 'hi   '); echo "[$x]"''');
      expect(r.stdout, '[hi   ]\n');
    });

    test('all trailing newlines collapse', () async {
      final r = await Bash().exec(r'''x=$(printf 'x\n\n\n'); echo "[$x]"''');
      expect(r.stdout, '[x]\n');
    });
  });

  group(r'$(...) command substitution', () {
    test('substitutes captured stdout', () async {
      expect(
        (await Bash().exec(r'echo "got: $(echo hi)"')).stdout,
        'got: hi\n',
      );
    });

    test('strips trailing newlines', () async {
      // printf adds no newline; echo adds one — both collapse the same.
      final r = await Bash().exec(r'x=$(echo line); echo "[$x]"');
      expect(r.stdout, '[line]\n');
    });

    test('into an assignment', () async {
      final r = await Bash().exec(r'name=$(echo Ada); echo "hi $name"');
      expect(r.stdout, 'hi Ada\n');
    });

    test('unquoted result is word-split', () async {
      final r =
          await Bash().exec(r'for w in $(echo a b c); do echo "- $w"; done');
      expect(r.stdout, '- a\n- b\n- c\n');
    });

    test('quoted result is not word-split', () async {
      final r = await Bash().exec(r'printf "%s" "$(echo a b c)" | cat');
      // The whole "a b c" stays a single field; cat echoes it back.
      expect(r.stdout, 'a b c');
    });

    test('reads from the shared virtual filesystem', () async {
      final bash = Bash(files: {'/f.txt': 'content\n'});
      expect(
          (await bash.exec(r'echo "[$(cat /f.txt)]"')).stdout, '[content]\n');
    });

    test('nested substitution', () async {
      final r = await Bash().exec(r'echo $(echo $(echo deep))');
      expect(r.stdout, 'deep\n');
    });

    test(r'$? reflects the substituted command exit code', () async {
      final r = await Bash().exec(r'out=$(false); echo $?');
      expect(r.stdout, '1\n');
    });

    test(r'assignments inside $(...) do not leak to the parent', () async {
      final r = await Bash().exec(r'v=outer; x=$(v=inner; echo hi); echo $v');
      expect(r.stdout, 'outer\n');
    });

    test('a command substitution can write to the shared FS', () async {
      final bash = Bash();
      await bash.exec(r'_=$(echo data > /made.txt); cat /made.txt');
      expect(await bash.fs.readFile('/made.txt'), 'data\n');
    });
  });

  group('backtick substitution', () {
    test('legacy backtick works like dollar-paren', () async {
      expect((await Bash().exec('echo `echo hi`')).stdout, 'hi\n');
    });
  });

  group('exit status of an empty command word (POSIX 2.9.1)', () {
    test(r'bare $(false) carries the substitution status', () async {
      // No command name remains after expansion; $? must be the last
      // command substitution's status, not a hard-reset 0.
      expect((await Bash().exec(r'$(false); echo $?')).stdout, '1\n');
    });

    test(r'bare $(true) yields 0', () async {
      expect((await Bash().exec(r'$(true); echo $?')).stdout, '0\n');
    });

    test('an empty word with no substitution still yields 0', () async {
      // No substitution ran, so the POSIX rule does not apply: status is 0,
      // not the carried-over status of a prior command.
      expect(
        (await Bash().exec(r'false; e=; $e; echo $?')).stdout,
        '0\n',
      );
    });

    test(r'$(true)$(false) takes the LAST substitution performed', () async {
      expect((await Bash().exec(r'$(true)$(false); echo $?')).stdout, '1\n');
    });

    test('backtick empty command word carries the status', () async {
      expect((await Bash().exec(r'`false`; echo $?')).stdout, '1\n');
    });

    test(r'an empty $(false) condition takes the else branch', () async {
      // The status reset previously made `if $(false)` read as success and
      // silently run the wrong branch.
      final r = await Bash().exec(
        r'if $(false); then echo y; else echo n; fi',
      );
      expect(r.stdout, 'n\n');
    });
  });

  group(r'$? is readable during expansion (no pre-reset)', () {
    test(r'assignment RHS can read $? of the previous command', () async {
      // Regression: resetting lastExitCode before expanding the RHS broke
      // `x=$?` — it always read 0.
      expect((await Bash().exec(r'false; x=$?; echo $x')).stdout, '1\n');
    });

    test(r'x=$? after a success reads 0', () async {
      expect((await Bash().exec(r'true; x=$?; echo $x')).stdout, '0\n');
    });

    test('a masked substitution failure does not surface', () async {
      // echo succeeds, so the failed $(false) inside it is intentionally
      // masked — the non-empty command path is unaffected by the fix.
      expect((await Bash().exec(r'echo "$(false)"; echo $?')).stdout, '\n0\n');
    });
  });
}
