/// The `Bash` facade — the primary entry point for running scripts.
library;

import 'package:dbash/src/fs/file_system.dart';
import 'package:dbash/src/fs/in_memory_fs.dart';
import 'package:dbash/src/parser/parser.dart';
import 'package:dbash/src/runtime/builtins.dart';
import 'package:dbash/src/runtime/command.dart';
import 'package:dbash/src/runtime/interpreter.dart';

/// A simulated bash environment with a virtual filesystem.
///
/// Each [exec] call gets isolated shell state (a snapshot of env and cwd) while
/// the filesystem is shared across calls — mirroring just-bash.
///
/// ```dart
/// final bash = Bash(files: {'/data/x.txt': 'hi'});
/// final r = await bash.exec('cat /data/x.txt');
/// print(r.stdout); // hi
/// ```
///
/// This is an MVP: it executes simple commands, `;`/`&&`/`||` lists, pipelines,
/// assignments, and basic `if`/`for`/`while` control flow with word expansion.
/// Unsupported constructs throw [UnimplementedError].
class Bash {
  /// Creates a bash environment.
  ///
  /// [files] pre-populates the in-memory filesystem, [env] seeds environment
  /// variables, [cwd] sets the initial working directory, and [customCommands]
  /// registers host-supplied commands (see `defineCommand`).
  Bash({
    Map<String, Object>? files,
    Map<String, String>? env,
    String cwd = '/home/user',
    List<Command> customCommands = const [],
    FileSystem? fileSystem,
  })  : fs = fileSystem ?? InMemoryFs(files),
        _cwd = cwd,
        _env = {
          'HOME': '/home/user',
          'PWD': cwd,
          'PATH': '/usr/bin:/bin',
          'IFS': ' \t\n',
          ...?env,
        } {
    for (final c in [...builtinCommands, ...customCommands]) {
      _commands[c.name] = c;
    }
  }

  /// The shared virtual filesystem.
  final FileSystem fs;

  final String _cwd;
  final Map<String, String> _env;
  final CommandRegistry _commands = {};

  /// Register an additional host command after construction.
  void addCommand(Command command) => _commands[command.name] = command;

  /// The names of all registered commands.
  List<String> get commandNames => _commands.keys.toList();

  /// Execute [script] and return its result.
  ///
  /// [env] is merged into (or, with [replaceEnv], replaces) the base
  /// environment for this call only. [cwd] overrides the working directory.
  /// [args] become the positional parameters (`$1`, `$2`, …).
  Future<ExecResult> exec(
    String script, {
    Map<String, String>? env,
    String? cwd,
    List<String> args = const [],
    bool replaceEnv = false,
  }) async {
    final callEnv = replaceEnv
        ? {...?env}
        : {
            ..._env,
            ...?env,
          };
    final state = ShellState(
      env: callEnv,
      cwd: cwd ?? _cwd,
      exported: {..._env.keys},
      positionalParams: args,
    );
    final interpreter = Interpreter(fs: fs, state: state, commands: _commands);
    return interpreter.run(parse(script));
  }
}
