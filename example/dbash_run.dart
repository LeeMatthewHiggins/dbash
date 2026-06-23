// Executes bash scripts with dbash and prints their output — the "it runs"
// showcase.  Run with:  dart run example/dbash_run.dart
// ignore_for_file: avoid_print
import 'package:dbash/dbash.dart';

Future<void> main() async {
  final bash = Bash(files: {'/data/notes.txt': 'buy milk\nwalk dog\n'});

  Future<void> show(String script) async {
    final r = await bash.exec(script);
    print('\$ $script');
    if (r.stdout.isNotEmpty) print(r.stdout.trimRight());
    if (r.stderr.isNotEmpty) print('[stderr] ${r.stderr.trimRight()}');
    print('[exit ${r.exitCode}]\n');
  }

  await show(r'name=World; echo "Hello, $name!"');
  await show('echo {a,b,c}.txt');
  await show('echo piped through | cat');
  await show(r'count=3; for i in 1 2 $count; do echo "item $i"; done');
  await show('if true; then echo yes; else echo no; fi');
  await show(r'false; echo "exit was $?"');
  await show(r'greeting=${MSG:-hi there}; echo "$greeting"');
  await show('cd /data; cat notes.txt');
  await show('nope-command');
}
