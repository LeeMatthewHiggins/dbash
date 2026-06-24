// Regression tests for the two PR #4 review findings:
//  1. redirections must not be silently dropped, and
//  2. ExpansionError must become a shell-like result, not escape Bash.exec.
import 'package:dbash/dbash.dart';
import 'package:test/test.dart';

void main() {
  group('redirections — implemented (no longer silently dropped)', () {
    test('> writes stdout to a file instead of returning it', () async {
      final bash = Bash();
      final r = await bash.exec('echo hi > /out.txt; cat /out.txt');
      expect(r.stdout, 'hi\n');
      expect(await bash.fs.readFile('/out.txt'), 'hi\n');
    });

    test('the redirected command produces no terminal stdout', () async {
      final r = await Bash().exec('echo hi > /out.txt');
      expect(r.stdout, '');
    });

    test('>> appends', () async {
      final bash = Bash();
      await bash.exec('echo one > /log; echo two >> /log');
      expect(await bash.fs.readFile('/log'), 'one\ntwo\n');
    });

    test('< reads a file as stdin', () async {
      final bash = Bash(files: {'/in.txt': 'from file\n'});
      expect((await bash.exec('cat < /in.txt')).stdout, 'from file\n');
    });

    test('2> captures stderr to a file', () async {
      final bash = Bash();
      final r = await bash.exec('nope 2> /err.txt');
      expect(r.stderr, '');
      expect(await bash.fs.readFile('/err.txt'), contains('command not found'));
    });

    test('2>&1 merges stderr into the redirected stdout', () async {
      final bash = Bash();
      await bash.exec('nope > /both.txt 2>&1');
      expect(await bash.fs.readFile('/both.txt'), contains('command not found'));
    });

    test('bare > creates an empty file', () async {
      final bash = Bash();
      await bash.exec('> /empty.txt');
      expect(await bash.fs.readFile('/empty.txt'), '');
    });

    test('missing input file is a shell error, not an exception', () async {
      final r = await Bash().exec('cat < /missing');
      expect(r.exitCode, 1);
      expect(r.stderr, contains('No such file or directory'));
    });
  });

  group('redirections — unported boundaries throw visibly', () {
    test('redirection on a compound command throws', () async {
      expect(
        () => Bash().exec('if true; then echo hi; fi > /out'),
        throwsUnimplementedError,
      );
    });

    test('here-string redirection throws', () async {
      expect(
        () => Bash().exec('cat <<< word'),
        throwsUnimplementedError,
      );
    });
  });

  group('ExpansionError becomes a shell result (all expansion sites)', () {
    test(r'argv position: ${X:?msg}', () async {
      final r = await Bash().exec(r'echo ${MISSING:?required}');
      expect(r.exitCode, 1);
      expect(r.stderr, contains('MISSING: required'));
      expect(r.stdout, '');
    });

    test(r'assignment position: x=${X:?msg}', () async {
      final r = await Bash().exec(r'x=${MISSING:?required}');
      expect(r.exitCode, 1);
      expect(r.stderr, contains('MISSING: required'));
    });

    test(r'for-word position: for i in ${X:?msg}', () async {
      final r = await Bash().exec(r'for i in ${MISSING:?required}; do :; done');
      expect(r.exitCode, 1);
      expect(r.stderr, contains('MISSING: required'));
    });

    test('it does not throw out of Bash.exec', () async {
      // The whole point: this returns a result rather than throwing.
      await expectLater(
        Bash().exec(r'echo ${MISSING:?required}'),
        completes,
      );
    });
  });
}
