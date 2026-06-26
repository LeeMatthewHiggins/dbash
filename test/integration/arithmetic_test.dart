// Arithmetic: $((...)), (( )), $[...], C-style for, and ${x:off:len}.
import 'package:dbash/dbash.dart';
import 'package:test/test.dart';

Future<String> out(String script) async => (await Bash().exec(script)).stdout;

void main() {
  group(r'$((...)) expansion', () {
    test('precedence', () async {
      expect(await out(r'echo $((1 + 2 * 3))'), '7\n');
      expect(await out(r'echo $(((1 + 2) * 3))'), '9\n');
    });

    test('variables (recursively evaluated)', () async {
      expect(await out(r'x=5; echo $((x * x))'), '25\n');
      expect(await out(r'a=2; b=a+3; echo $((b))'), '5\n');
    });

    test('power is right-associative', () async {
      expect(await out(r'echo $((2 ** 10))'), '1024\n');
      expect(await out(r'echo $((2 ** 3 ** 2))'), '512\n');
    });

    test('integer division and modulo truncate toward zero', () async {
      expect(await out(r'echo $((-17 / 5))'), '-3\n');
      expect(await out(r'echo $((-17 % 5))'), '-2\n');
    });

    test('bitwise and shift', () async {
      expect(await out(r'echo $((6 & 3)) $((6 | 1)) $((5 ^ 1))'), '2 7 4\n');
      expect(await out(r'echo $((1 << 4)) $((256 >> 2))'), '16 64\n');
    });

    test('comparison and logical', () async {
      expect(await out(r'echo $((3 > 2)) $((2 > 3)) $((1 && 0)) $((1 || 0))'),
          '1 0 0 1\n');
    });

    test('ternary', () async {
      expect(await out(r'a=7; echo $((a > 5 ? 100 : 0))'), '100\n');
    });

    test('unary minus, not, complement', () async {
      expect(await out(r'echo $((-5)) $((!0)) $((!7)) $((~0))'), '-5 1 0 -1\n');
    });

    test('number bases', () async {
      expect(await out(r'echo $((0x10)) $((010)) $((2#1010)) $((36#z))'),
          '16 8 10 35\n');
    });

    test('uppercase 0x/0X hex digits are case-insensitive', () async {
      // Regression: A-F in a 0x literal must map to 10-15, not the base#num
      // alphabet's 36-41. (bash: `echo $((0xFF))` => 255)
      expect(await out(r'echo $((0xFF))'), '255\n');
      expect(await out(r'echo $((0Xff))'), '255\n');
      expect(await out(r'echo $((0xDEADBEEF))'), '3735928559\n');
      expect(await out(r'echo $((0xAbCdEf))'), '11259375\n');
    });

    test('uppercase 0x literal in a variable evaluates cleanly', () async {
      final r = await Bash().exec(r'h=0xFF; echo $((h + 1))');
      expect(r.exitCode, 0);
      expect(r.stdout, '256\n');
    });

    test('case-insensitive bases <= 36 (base#num form)', () async {
      // bash: for base <= 36, uppercase and lowercase are interchangeable.
      expect(
        await out(r'echo $((16#FF)) $((16#ff)) $((36#Z))'),
        '255 255 35\n',
      );
    });

    test('bases above 36 use the extended uppercase alphabet', () async {
      // For base > 36, uppercase A-Z = 36-61 (distinct from lowercase).
      expect(await out(r'echo $((37#A))'), '36\n');
    });

    test('a digit too great for its base is rejected', () async {
      for (final script in [
        r'echo $((3#13))',
        r'echo $((2#102))',
        r'echo $((16#1g))',
      ]) {
        final r = await Bash().exec(script);
        expect(r.exitCode, 1, reason: script);
        expect(r.stderr, contains('value too great for base'), reason: script);
      }
    });

    test('assignment inside expansion persists', () async {
      expect(await out(r'echo $((n = 3 + 4)); echo $n'), '7\n7\n');
    });

    test('compound assignment', () async {
      expect(await out(r'x=10; echo $((x += 5)); echo $x'), '15\n15\n');
    });

    test(r'$[...] old-style arithmetic', () async {
      expect(await out(r'echo $[6 * 7]'), '42\n');
    });
  });

  group('(( ... )) command', () {
    test('non-zero result is success, zero is failure', () async {
      expect((await Bash().exec('(( 1 + 1 ))')).exitCode, 0);
      expect((await Bash().exec('(( 0 ))')).exitCode, 1);
    });

    test('increments a variable', () async {
      expect(await out(r'i=0; ((i++)); ((i++)); ((++i)); echo $i'), '3\n');
    });

    test('drives an if condition', () async {
      expect(await out('if (( 3 > 2 )); then echo y; else echo n; fi'), 'y\n');
    });
  });

  group('C-style for', () {
    test('counts', () async {
      expect(
        await out(r'for ((i=0; i<3; i++)); do echo $i; done'),
        '0\n1\n2\n',
      );
    });

    test('with a brace body', () async {
      const script =
          r'sum=0; for ((i=1; i<=4; i++)); do sum=$((sum+i)); done; echo $sum';
      expect(await out(script), '10\n');
    });

    test('zero iterations return success, not the prior status', () async {
      final r =
          await Bash().exec('false; for ((i=5; i<3; i++)); do echo x; done');
      expect(r.exitCode, 0);
    });

    test('arithmetic error in update keeps already-emitted output (#11)',
        () async {
      final r = await Bash().exec(r'for ((i=0; i<3; i=i/0)); do echo $i; done');
      expect(r.stdout, '0\n');
      expect(r.exitCode, 1);
      expect(r.stderr, contains('division by 0'));
    });

    test('arithmetic error in init produces no output', () async {
      final r = await Bash().exec(r'for ((i=1/0; i<3; i++)); do echo $i; done');
      expect(r.stdout, '');
      expect(r.exitCode, 1);
    });
  });

  group('64-bit integer literals (#11)', () {
    test('large decimal literals are not clamped to 2^53-1', () async {
      expect(await out(r'echo $((10000000000000000))'), '10000000000000000\n');
    });

    test('int64-max hex literal', () async {
      expect(
        await out(r'echo $((0x7FFFFFFFFFFFFFFF))'),
        '9223372036854775807\n',
      );
    });

    test('arithmetic on large values', () async {
      expect(await out(r'echo $((5000000000 * 2))'), '10000000000\n');
    });
  });

  group(r'${var:offset:length} substring', () {
    test('basic', () async {
      expect(await out(r'v=hello; echo ${v:1:3}'), 'ell\n');
    });

    test('offset only', () async {
      expect(await out(r'v=hello; echo ${v:2}'), 'llo\n');
    });

    test('negative length counts from the end', () async {
      expect(await out(r'v=hello; echo ${v:0:-1}'), 'hell\n');
    });

    test('offset from a variable', () async {
      expect(await out(r'v=abcdef; n=2; echo ${v:n:2}'), 'cd\n');
    });

    test('negative offset before the start yields empty', () async {
      expect(await out(r'v=hello; echo "[${v: -100}]"'), '[]\n');
    });

    test('negative length before the offset is an error', () async {
      final r = await Bash().exec(r'v=hello; echo ${v:1:-100}');
      expect(r.exitCode, 1);
      expect(r.stderr, contains('substring expression < 0'));
    });
  });

  group('arithmetic errors are reported, not thrown', () {
    test('division by zero', () async {
      final r = await Bash().exec(r'echo $((1 / 0))');
      expect(r.exitCode, 1);
      expect(r.stderr, contains('division by 0'));
    });

    test('does not throw out of Bash.exec', () async {
      await expectLater(Bash().exec(r'echo $((5 % 0))'), completes);
    });
  });

  // bash parity (#13): an arithmetic error in a *word* (`$(())`, `$[...]`) is a
  // word-expansion error — it aborts the whole enclosing command (the loop /
  // compound command it sits in), unlike `(( ))` or a C-style for's
  // init/cond/update arithmetic, which are command failures that let the
  // enclosing list continue.
  group(r'$(()) error in a command word aborts the enclosing command (#13)',
      () {
    test('aborts a C-style for loop instead of running every iteration',
        () async {
      final r = await Bash()
          .exec(r'for ((i=0;i<3;i++)); do echo $((1/0)); echo $i; done');
      // bash 5.2: no stdout, the error once, exit 1 — not 0\n1\n2 + 3 errors.
      expect(r.stdout, '');
      expect(r.exitCode, 1);
      expect('division by 0'.allMatches(r.stderr).length, 1);
    });

    test('keeps output emitted before the failing word', () async {
      final r = await Bash()
          .exec(r'for ((i=0;i<3;i++)); do echo $i; echo $((1/0)); done');
      expect(r.stdout, '0\n');
      expect(r.exitCode, 1);
    });

    test('aborts a regular for loop', () async {
      final r = await Bash().exec(r'for x in a b c; do echo $((1/0)); done');
      expect(r.stdout, '');
      expect(r.exitCode, 1);
    });

    test('aborts a while loop, keeping earlier output', () async {
      final r = await Bash().exec(
        r'x=1; while (( x )); do echo hi; echo $((1/0)); x=0; done',
      );
      // The body runs once (echo hi) then the word error aborts the loop.
      expect(r.stdout, 'hi\n');
      expect(r.exitCode, 1);
    });

    test('aborts through a nested if + for, keeping earlier output', () async {
      final r = await Bash().exec(
        r'if true; then for ((i=0;i<2;i++)); do echo $i; echo $((1/0)); done; '
        'echo never; fi',
      );
      expect(r.stdout, '0\n');
      expect(r.stderr, contains('division by 0'));
      expect(r.exitCode, 1);
    });

    test(r'$[...] form aborts too', () async {
      final r = await Bash().exec(r'for x in a b; do echo $[1/0]; done');
      expect(r.stdout, '');
      expect(r.exitCode, 1);
    });

    test('the next top-level command still runs', () async {
      // dbash flattens `;` and newline into separate top-level statements, so
      // the abort ends the current command and the script continues.
      final r = await Bash()
          .exec('for ((i=0;i<2;i++)); do echo \$((1/0)); done\necho after');
      expect(r.stdout, 'after\n');
    });
  });

  group('(( )) and C-style for arithmetic errors are command failures (#13)',
      () {
    test('(( )) error does not abort the list', () async {
      final r = await Bash().exec('echo a\n(( 1/0 ))\necho b');
      expect(r.stdout, 'a\nb\n');
      expect(r.stderr, contains('division by 0'));
      // Last command is `echo b`, so the list's status is its success.
      expect(r.exitCode, 0);
    });

    test('for-loop init error does not abort the list', () async {
      final r = await Bash()
          .exec('echo a\nfor ((i=1/0;i<2;i++)); do echo \$i; done\necho b');
      expect(r.stdout, 'a\nb\n');
      expect(r.exitCode, 0);
    });
  });
}
