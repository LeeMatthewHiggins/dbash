// The "it runs" tests: Bash.exec actually executes scripts and produces output.
import 'package:dbash/dbash.dart';
import 'package:test/test.dart';

void main() {
  group('simple commands', () {
    test('echo prints its argument', () async {
      final r = await Bash().exec('echo hello');
      expect(r.stdout, 'hello\n');
      expect(r.exitCode, 0);
    });

    test('echo -n suppresses the newline', () async {
      expect((await Bash().exec('echo -n hi')).stdout, 'hi');
    });

    test('multiple args are space-joined', () async {
      expect((await Bash().exec('echo a b c')).stdout, 'a b c\n');
    });

    test('unknown command is 127 with a message', () async {
      final r = await Bash().exec('nope');
      expect(r.exitCode, 127);
      expect(r.stderr, contains('command not found'));
    });
  });

  group('variables and expansion', () {
    test('assignment then expansion', () async {
      final r = await Bash().exec(r'name=World; echo "Hello, $name"');
      expect(r.stdout, 'Hello, World\n');
    });

    test('seeded env var', () async {
      final r = await Bash(env: {'WHO': 'Ada'}).exec(r'echo $WHO');
      expect(r.stdout, 'Ada\n');
    });

    test(r'$? reflects last exit code', () async {
      final r = await Bash().exec(r'false; echo $?');
      expect(r.stdout, '1\n');
    });

    test('default-value operator', () async {
      expect((await Bash().exec(r'echo ${X:-fallback}')).stdout, 'fallback\n');
    });

    test('assign-default sets the variable', () async {
      final r = await Bash().exec(r'echo ${X:=set}; echo $X');
      expect(r.stdout, 'set\nset\n');
    });

    test('length operator', () async {
      expect((await Bash().exec(r'v=hello; echo ${#v}')).stdout, '5\n');
    });

    test('single quotes are literal', () async {
      expect((await Bash().exec(r"echo '$HOME'")).stdout, '\$HOME\n');
    });

    test('brace expansion', () async {
      expect((await Bash().exec('echo {a,b,c}')).stdout, 'a b c\n');
    });

    test('numeric brace range', () async {
      expect((await Bash().exec('echo {1..4}')).stdout, '1 2 3 4\n');
    });

    test('tilde expands to HOME', () async {
      expect((await Bash().exec('echo ~')).stdout, '/home/user\n');
    });

    test('unquoted expansion word-splits', () async {
      final r = await Bash(env: {'L': 'a b c'}).exec(r'echo $L');
      expect(r.stdout, 'a b c\n');
    });
  });

  group('lists and pipelines', () {
    test('&& runs on success', () async {
      expect((await Bash().exec('true && echo yes')).stdout, 'yes\n');
    });

    test('&& skips on failure', () async {
      expect((await Bash().exec('false && echo yes')).stdout, '');
    });

    test('|| runs on failure', () async {
      expect((await Bash().exec('false || echo no')).stdout, 'no\n');
    });

    test('pipeline feeds stdout to stdin', () async {
      expect((await Bash().exec('echo piped | cat')).stdout, 'piped\n');
    });
  });

  group('filesystem-backed commands', () {
    test('cat reads a seeded file', () async {
      final bash = Bash(files: {'/data/x.txt': 'file content\n'});
      expect((await bash.exec('cat /data/x.txt')).stdout, 'file content\n');
    });

    test('filesystem is shared across exec calls', () async {
      final bash = Bash(files: {'/a.txt': 'one\n'});
      final r1 = await bash.exec('cat /a.txt');
      final r2 = await bash.exec('cat /a.txt');
      expect(r1.stdout, 'one\n');
      expect(r2.stdout, 'one\n');
    });

    test('cd changes the working directory', () async {
      final bash = Bash(files: {'/work/note.txt': 'hi\n'});
      final r = await bash.exec('cd /work; cat note.txt');
      expect(r.stdout, 'hi\n');
    });
  });

  group('control flow', () {
    test('for loop over a word list', () async {
      final r = await Bash().exec(r'for i in 1 2 3; do echo $i; done');
      expect(r.stdout, '1\n2\n3\n');
    });

    test('if/then/else — then branch', () async {
      final r = await Bash().exec('if true; then echo yes; else echo no; fi');
      expect(r.stdout, 'yes\n');
    });

    test('if/then/else — else branch', () async {
      final r = await Bash().exec('if false; then echo yes; else echo no; fi');
      expect(r.stdout, 'no\n');
    });
  });

  group('host-defined commands', () {
    test('a custom command is dispatched', () async {
      final greet = defineCommand('greet', (args, ctx) async {
        return ExecResult(stdout: 'hi ${args.isEmpty ? '?' : args[0]}\n');
      });
      final bash = Bash(customCommands: [greet]);
      expect((await bash.exec('greet Ada')).stdout, 'hi Ada\n');
    });

    test('custom command reads the virtual filesystem', () async {
      final count = defineCommand('lines', (args, ctx) async {
        final text = await ctx.fs.readFile('/f.txt');
        return ExecResult(stdout: '${text.trimRight().split('\n').length}\n');
      });
      final bash = Bash(files: {'/f.txt': 'a\nb\nc\n'}, customCommands: [count]);
      expect((await bash.exec('lines')).stdout, '3\n');
    });
  });
}
