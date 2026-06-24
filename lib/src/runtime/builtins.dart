/// Built-in commands shipped with the interpreter (MVP set).
library;

import 'package:dbash/src/fs/path_utils.dart' as paths;
import 'package:dbash/src/runtime/command.dart';

/// `echo [-n] [args...]` — print arguments separated by spaces.
final Command echoCommand = defineCommand('echo', (args, ctx) async {
  var noNewline = false;
  var i = 0;
  while (i < args.length && args[i] == '-n') {
    noNewline = true;
    i++;
  }
  final text = args.sublist(i).join(' ');
  return ExecResult(stdout: noNewline ? text : '$text\n');
});

/// `cat [files...]` — concatenate files, or stdin when no files are given.
final Command catCommand = defineCommand('cat', (args, ctx) async {
  if (args.isEmpty) {
    return ExecResult(stdout: ctx.stdin);
  }
  final out = StringBuffer();
  for (final arg in args) {
    final path = paths.resolvePath(ctx.cwd, arg);
    try {
      out.write(await ctx.fs.readFile(path));
    } on Object {
      return ExecResult(
        stdout: out.toString(),
        stderr: 'cat: $arg: No such file or directory\n',
        exitCode: 1,
      );
    }
  }
  return ExecResult(stdout: out.toString());
});

/// `printf FORMAT [args...]` — minimal: supports `%s`, `%d`, `%%`, and `\n`.
final Command printfCommand = defineCommand('printf', (args, ctx) async {
  if (args.isEmpty) return const ExecResult();
  final format = args.first;
  final rest = args.sublist(1);
  final out = StringBuffer();
  var argIdx = 0;
  for (var i = 0; i < format.length; i++) {
    final c = format[i];
    if (c == r'\' && i + 1 < format.length) {
      final next = format[i + 1];
      out.write(switch (next) {
        'n' => '\n',
        't' => '\t',
        r'\' => r'\',
        _ => '\\$next',
      });
      i++;
    } else if (c == '%' && i + 1 < format.length) {
      final spec = format[i + 1];
      switch (spec) {
        case 's':
          out.write(argIdx < rest.length ? rest[argIdx++] : '');
        case 'd':
          final v = argIdx < rest.length ? rest[argIdx++] : '0';
          out.write(int.tryParse(v) ?? 0);
        case '%':
          out.write('%');
        default:
          out.write('%$spec');
      }
      i++;
    } else {
      out.write(c);
    }
  }
  return ExecResult(stdout: out.toString());
});

/// The default built-in commands registered by a new `Bash` environment.
List<Command> get builtinCommands => [
      echoCommand,
      catCommand,
      printfCommand,
    ];
