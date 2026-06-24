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
  });

  group('arithmetic errors are contained', () {
    test('division by zero', () async {
      final r = await Bash().exec(r'echo $((1 / 0))');
      expect(r.exitCode, 1);
      expect(r.stderr, contains('division by 0'));
    });

    test('does not throw out of Bash.exec', () async {
      await expectLater(Bash().exec(r'echo $((5 % 0))'), completes);
    });
  });
}
