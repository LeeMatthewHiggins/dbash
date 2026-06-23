/// Host command API: the contract a command (built-in or host-supplied)
/// implements, and the context it receives.
///
/// Mirrors the `Command` / `CommandContext` / `ExecResult` shapes from upstream
/// just-bash's `types.ts`, trimmed to the MVP surface.
library;

import 'dart:async';

import 'package:dbash/src/fs/file_system.dart';

/// The result of executing a command or script.
class ExecResult {
  /// Creates an execution result.
  const ExecResult({
    this.stdout = '',
    this.stderr = '',
    this.exitCode = 0,
    this.env,
  });

  /// Standard output.
  final String stdout;

  /// Standard error.
  final String stderr;

  /// The exit code.
  final int exitCode;

  /// The final environment (only set by `Bash.exec`).
  final Map<String, String>? env;

  @override
  String toString() =>
      'ExecResult(exitCode: $exitCode, stdout: ${stdout.length}b, '
      'stderr: ${stderr.length}b)';
}

/// Context handed to a [Command] when it runs.
class CommandContext {
  /// Creates a command context.
  CommandContext({
    required this.fs,
    required this.cwd,
    required this.env,
    this.stdin = '',
    this.exec,
    this.getRegisteredCommands,
  });

  /// The virtual filesystem.
  final FileSystem fs;

  /// The current working directory.
  final String cwd;

  /// The environment variables visible to the command.
  final Map<String, String> env;

  /// Standard input (text) piped into the command.
  final String stdin;

  /// Run a subcommand string (available when running via the interpreter).
  final Future<ExecResult> Function(
    String command, {
    String? cwd,
    String? stdin,
  })? exec;

  /// Returns the names of all registered commands.
  final List<String> Function()? getRegisteredCommands;
}

/// A command that can be dispatched by the shell.
abstract class Command {
  /// The command name.
  String get name;

  /// Execute with [args] and [ctx].
  Future<ExecResult> execute(List<String> args, CommandContext ctx);
}

/// The signature of a [defineCommand] handler.
typedef CommandHandler = FutureOr<ExecResult> Function(
  List<String> args,
  CommandContext ctx,
);

class _DefinedCommand implements Command {
  _DefinedCommand(this.name, this._handler);

  @override
  final String name;
  final CommandHandler _handler;

  @override
  Future<ExecResult> execute(List<String> args, CommandContext ctx) async =>
      _handler(args, ctx);
}

/// Create a [Command] from a [name] and a [handler] function.
///
/// ```dart
/// final hello = defineCommand('hello', (args, ctx) async {
///   return ExecResult(stdout: 'Hello, ${args.isEmpty ? 'world' : args[0]}!\n');
/// });
/// ```
Command defineCommand(String name, CommandHandler handler) =>
    _DefinedCommand(name, handler);

/// A registry mapping command names to their implementations.
typedef CommandRegistry = Map<String, Command>;
