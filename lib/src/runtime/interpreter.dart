/// Tree-walking interpreter (MVP).
///
/// Executes the supported AST subset: scripts, `;`/`&&`/`||` lists, pipelines,
/// simple commands with prefix and standalone assignments, and basic `if` /
/// `for` / `while` / `until` control flow. Word expansion is delegated to
/// [Expander]. Unsupported compound commands and word forms throw
/// [UnimplementedError] at their boundary.
// ignore_for_file: use_string_buffers
library;

import 'package:dbash/src/ast/ast.dart';
import 'package:dbash/src/fs/file_system.dart';
import 'package:dbash/src/fs/path_utils.dart' as paths;
import 'package:dbash/src/parser/parser.dart';
import 'package:dbash/src/runtime/command.dart';
import 'package:dbash/src/runtime/expansion.dart';

/// Mutable shell state for one execution.
class ShellState implements ExpansionHost {
  /// Creates shell state.
  ShellState({
    required this.env,
    required this.cwd,
    required this.exported,
    this.positionalParams = const [],
    this.shellName = 'dbash',
  });

  /// Shell and environment variables.
  final Map<String, String> env;

  /// The current working directory.
  String cwd;

  /// Names of exported variables.
  final Set<String> exported;

  @override
  List<String> positionalParams;

  @override
  final String shellName;

  @override
  int lastExitCode = 0;

  @override
  String? getVar(String name) => env[name];

  @override
  void setVar(String name, String value) => env[name] = value;
}

/// Executes a parsed script against a [FileSystem] and a command registry.
class Interpreter {
  /// Creates an interpreter.
  Interpreter({
    required this.fs,
    required this.state,
    required this.commands,
  }) : _expander = Expander(state);

  /// The virtual filesystem.
  final FileSystem fs;

  /// The shell state.
  final ShellState state;

  /// The command registry (built-ins + host commands).
  final CommandRegistry commands;

  final Expander _expander;
  final StringBuffer _stderr = StringBuffer();

  /// Execute a parsed [script] and return the aggregated result.
  Future<ExecResult> run(ScriptNode script) async {
    var stdout = '';
    for (final stmt in script.statements) {
      if (stmt.deferredError != null) {
        _stderr.write('dbash: ${stmt.deferredError!.message}\n');
        state.lastExitCode = 2;
        continue;
      }
      final r = await _execStatement(stmt, '');
      stdout += r.stdout;
    }
    return ExecResult(
      stdout: stdout,
      stderr: _stderr.toString(),
      exitCode: state.lastExitCode,
      env: Map.of(state.env),
    );
  }

  Future<ExecResult> _execStatement(StatementNode stmt, String stdin) async {
    var stdout = '';
    var run = true;
    for (var i = 0; i < stmt.pipelines.length; i++) {
      if (i > 0) {
        final op = stmt.operators[i - 1];
        if (op == '&&') run = state.lastExitCode == 0;
        if (op == '||') run = state.lastExitCode != 0;
        // ';' always runs.
        if (op == ';') run = true;
      }
      if (!run) continue;
      final r = await _execPipeline(stmt.pipelines[i], stdin);
      stdout += r.stdout;
    }
    return ExecResult(stdout: stdout, exitCode: state.lastExitCode);
  }

  Future<ExecResult> _execPipeline(PipelineNode pipe, String stdin) async {
    var input = stdin;
    var stdout = '';
    for (var i = 0; i < pipe.commands.length; i++) {
      final r = await _execCommand(pipe.commands[i], input);
      if (i < pipe.commands.length - 1) {
        input = r.stdout; // pipe stdout -> next stdin
        stdout = '';
      } else {
        stdout = r.stdout;
      }
    }
    if (pipe.negated) {
      state.lastExitCode = state.lastExitCode == 0 ? 1 : 0;
    }
    return ExecResult(stdout: stdout, exitCode: state.lastExitCode);
  }

  Future<ExecResult> _execCommand(CommandNode node, String stdin) async {
    switch (node) {
      case SimpleCommandNode():
        return _execSimpleCommand(node, stdin);
      case IfNode():
        return _execIf(node, stdin);
      case ForNode():
        return _execFor(node, stdin);
      case WhileNode():
        return _execWhileUntil(node.condition, node.body, until: false);
      case UntilNode():
        return _execWhileUntil(node.condition, node.body, until: true);
      default:
        throw UnimplementedError(
          'execution of ${node.type} is not in the MVP yet',
        );
    }
  }

  Future<ExecResult> _execSimpleCommand(
    SimpleCommandNode node,
    String stdin,
  ) async {
    // Assignment-only command: persist to shell state.
    if (node.name == null) {
      for (final a in node.assignments) {
        _applyAssignment(a, state.env);
      }
      state.lastExitCode = 0;
      return const ExecResult();
    }

    // Prefix assignments apply to a temp env for this command only.
    final env = Map<String, String>.of(state.env);
    for (final a in node.assignments) {
      _applyAssignment(a, env);
    }

    final argv = [
      ..._expander.expandWord(node.name!),
      ..._expander.expandWords(node.args),
    ];
    if (argv.isEmpty) {
      state.lastExitCode = 0;
      return const ExecResult();
    }

    final name = argv.first;
    final args = argv.sublist(1);

    // Interpreter-level builtins.
    switch (name) {
      case ':':
      case 'true':
        state.lastExitCode = 0;
        return const ExecResult();
      case 'false':
        state.lastExitCode = 1;
        return const ExecResult();
      case 'cd':
        return _builtinCd(args);
      case 'export':
        return _builtinExport(args, env);
      case 'unset':
        for (final n in args) {
          state.env.remove(n);
        }
        state.lastExitCode = 0;
        return const ExecResult();
    }

    final command = commands[name];
    if (command == null) {
      _stderr.write('dbash: $name: command not found\n');
      state.lastExitCode = 127;
      return const ExecResult();
    }

    final ctx = CommandContext(
      fs: fs,
      cwd: state.cwd,
      env: env,
      stdin: stdin,
      exec: (cmd, {cwd, stdin}) =>
          Interpreter(fs: fs, state: state, commands: commands)
              .run(parse(cmd)),
      getRegisteredCommands: () => commands.keys.toList(),
    );

    try {
      final result = await command.execute(args, ctx);
      _stderr.write(result.stderr);
      state.lastExitCode = result.exitCode;
      return ExecResult(stdout: result.stdout, exitCode: result.exitCode);
    } on ExpansionError catch (e) {
      _stderr.write('dbash: ${e.message}\n');
      state.lastExitCode = e.exitCode;
      return const ExecResult();
    }
  }

  Future<ExecResult> _execIf(IfNode node, String stdin) async {
    for (final clause in node.clauses) {
      await _runStatements(clause.condition);
      if (state.lastExitCode == 0) {
        final out = await _runStatements(clause.body);
        return ExecResult(stdout: out, exitCode: state.lastExitCode);
      }
    }
    if (node.elseBody != null) {
      final out = await _runStatements(node.elseBody!);
      return ExecResult(stdout: out, exitCode: state.lastExitCode);
    }
    state.lastExitCode = 0;
    return const ExecResult();
  }

  Future<ExecResult> _execFor(ForNode node, String stdin) async {
    final values = node.words == null
        ? state.positionalParams
        : _expander.expandWords(node.words!);
    var stdout = '';
    for (final v in values) {
      state.env[node.variable] = v;
      stdout += await _runStatements(node.body);
    }
    return ExecResult(stdout: stdout, exitCode: state.lastExitCode);
  }

  Future<ExecResult> _execWhileUntil(
    List<StatementNode> condition,
    List<StatementNode> body, {
    required bool until,
  }) async {
    var stdout = '';
    var guard = 0;
    while (guard++ < 100000) {
      await _runStatements(condition);
      final ok = state.lastExitCode == 0;
      if (until ? ok : !ok) break;
      stdout += await _runStatements(body);
    }
    return ExecResult(stdout: stdout, exitCode: state.lastExitCode);
  }

  Future<String> _runStatements(List<StatementNode> statements) async {
    var stdout = '';
    for (final s in statements) {
      final r = await _execStatement(s, '');
      stdout += r.stdout;
    }
    return stdout;
  }

  void _applyAssignment(AssignmentNode a, Map<String, String> target) {
    if (a.array != null) {
      throw UnimplementedError('array assignment is not in the MVP yet');
    }
    final value = a.value == null ? '' : _expander.expandToString(a.value!);
    if (a.append) {
      target[a.name] = (target[a.name] ?? '') + value;
    } else {
      target[a.name] = value;
    }
  }

  Future<ExecResult> _builtinCd(List<String> args) async {
    final target = args.isEmpty
        ? (state.env['HOME'] ?? '/home/user')
        : args.first;
    final resolved = paths.resolvePath(state.cwd, target);
    if (!await fs.exists(resolved)) {
      _stderr.write('dbash: cd: $target: No such file or directory\n');
      state.lastExitCode = 1;
      return const ExecResult();
    }
    state.cwd = resolved;
    state.env['PWD'] = resolved;
    state.lastExitCode = 0;
    return const ExecResult();
  }

  Future<ExecResult> _builtinExport(
    List<String> args,
    Map<String, String> env,
  ) async {
    for (final arg in args) {
      final eq = arg.indexOf('=');
      if (eq >= 0) {
        final name = arg.substring(0, eq);
        state.env[name] = arg.substring(eq + 1);
        state.exported.add(name);
      } else {
        state.exported.add(arg);
      }
    }
    state.lastExitCode = 0;
    return const ExecResult();
  }
}
