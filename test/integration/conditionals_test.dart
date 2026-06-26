// [[ ]] conditional expressions and case statements, executed end to end.
import 'package:dbash/dbash.dart';
import 'package:test/test.dart';

Future<String> out(String script, {Map<String, Object>? files}) async =>
    (await Bash(files: files).exec(script)).stdout;

Future<int> code(String script, {Map<String, Object>? files}) async =>
    (await Bash(files: files).exec(script)).exitCode;

void main() {
  group('[[ ]] string tests', () {
    test('-z empty / -n non-empty', () async {
      expect(await code('[[ -z "" ]]'), 0);
      expect(await code('[[ -z x ]]'), 1);
      expect(await code('[[ -n x ]]'), 0);
    });

    test('a bare word is true when non-empty', () async {
      expect(await code('[[ hello ]]'), 0);
      expect(await code('[[ "" ]]'), 1);
    });

    test('string equality and inequality', () async {
      expect(await code('[[ abc == abc ]]'), 0);
      expect(await code('[[ abc != xyz ]]'), 0);
      expect(await code('[[ abc == xyz ]]'), 1);
    });

    test('glob pattern match (unquoted RHS)', () async {
      expect(await code('[[ hello == hel* ]]'), 0);
      expect(await code('[[ hello == h?llo ]]'), 0);
      expect(await code('[[ hello == xyz* ]]'), 1);
    });

    test('a quoted RHS is literal, not a pattern', () async {
      expect(await code('[[ "hello" == "hel*" ]]'), 1);
      expect(await code('[[ "hel*" == "hel*" ]]'), 0);
    });

    test('lexical < and >', () async {
      expect(await code('[[ abc < abd ]]'), 0);
      expect(await code('[[ b > a ]]'), 0);
    });

    test('-v tests whether a variable is set', () async {
      expect(await code('x=1; [[ -v x ]]'), 0);
      expect(await code('[[ -v nope ]]'), 1);
    });
  });

  group('[[ ]] arithmetic tests', () {
    test('-eq -ne -lt -le -gt -ge', () async {
      expect(await code('[[ 3 -eq 3 ]]'), 0);
      expect(await code('[[ 3 -ne 4 ]]'), 0);
      expect(await code('[[ 2 -lt 5 && 5 -ge 5 ]]'), 0);
      expect(await code('[[ 5 -gt 9 ]]'), 1);
    });

    test('operands are evaluated as arithmetic (variables)', () async {
      expect(await code('a=3; b=4; [[ a+1 -eq b ]]'), 0);
    });
  });

  group('[[ ]] file tests', () {
    final files = {'/a.txt': 'data\n', '/empty': '', '/dir/x': 'y'};

    test('-e / -f / -d / -s', () async {
      expect(await code('[[ -e /a.txt ]]', files: files), 0);
      expect(await code('[[ -f /a.txt ]]', files: files), 0);
      expect(await code('[[ -d /dir ]]', files: files), 0);
      expect(await code('[[ -f /dir ]]', files: files), 1);
      expect(await code('[[ -s /a.txt ]]', files: files), 0);
      expect(await code('[[ -s /empty ]]', files: files), 1);
      expect(await code('[[ -e /missing ]]', files: files), 1);
    });
  });

  group('[[ ]] regex (=~)', () {
    test('matches an ERE', () async {
      expect(await code(r'[[ abc123 =~ ^[a-z]+[0-9]+$ ]]'), 0);
      expect(await code(r'[[ abc =~ ^[0-9]+$ ]]'), 1);
    });
  });

  group('[[ ]] logical operators and grouping', () {
    test('&& || ! and ( )', () async {
      expect(await code('[[ 1 -eq 1 && 2 -eq 2 ]]'), 0);
      expect(await code('[[ 1 -eq 2 || 3 -eq 3 ]]'), 0);
      expect(await code('[[ ! -z x ]]'), 0);
      expect(await code('[[ ( 1 -eq 1 || 1 -eq 2 ) && 3 -eq 3 ]]'), 0);
    });

    test('short-circuits', () async {
      expect(await code('[[ 1 -eq 2 && 3 -eq 3 ]]'), 1);
    });

    test('drives if', () async {
      expect(
        await out('if [[ -n x ]]; then echo yes; else echo no; fi'),
        'yes\n',
      );
    });
  });

  group('case statements', () {
    test('literal match', () async {
      const s = r'v=2; case $v in 1) echo one;; 2) echo two;; *) echo o;; esac';
      expect(await out(s), 'two\n');
    });

    test('glob pattern and default', () async {
      const m = 'case foobar in foo*) echo m;; *) echo d;; esac';
      const d = 'case zzz in foo*) echo m;; *) echo d;; esac';
      expect(await out(m), 'm\n');
      expect(await out(d), 'd\n');
    });

    test('alternation with |', () async {
      const s = 'case b in a|b|c) echo abc;; *) echo no;; esac';
      expect(await out(s), 'abc\n');
    });

    test('POSIX character class pattern', () async {
      expect(await out('case A in [[:upper:]]) echo U;; esac'), 'U\n');
    });

    test('no match yields exit 0 and no output', () async {
      final r = await Bash().exec('case x in a) echo a;; esac');
      expect(r.stdout, '');
      expect(r.exitCode, 0);
    });

    test(';& falls through to the next clause body', () async {
      const s = 'case a in a) echo one;& b) echo two;; esac';
      expect(await out(s), 'one\ntwo\n');
    });

    test(';;& keeps testing later patterns', () async {
      const s = 'case abc in a*) echo p1;;& *c) echo p2;; esac';
      expect(await out(s), 'p1\np2\n');
    });
  });
}
