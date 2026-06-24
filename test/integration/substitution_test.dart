// Command and backtick substitution: $(...) and `...` run end to end.
import 'package:dbash/dbash.dart';
import 'package:test/test.dart';

void main() {
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
      expect((await bash.exec(r'echo "[$(cat /f.txt)]"')).stdout, '[content]\n');
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
}
