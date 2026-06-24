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
import 'package:dbash/src/runtime/arithmetic.dart';
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
  }) {
    _arith = ArithEvaluator(getVar: state.getVar, setVar: state.setVar);
    _expander = Expander(
      state,
      commandSubstitution: _runCommandSubstitution,
      arithmetic: _arith.evaluate,
    );
  }

  /// The virtual filesystem.
  final FileSystem fs;

  /// The shell state.
  final ShellState state;

  /// The command registry (built-ins + host commands).
  final CommandRegistry commands;

  late final Expander _expander;
  late final ArithEvaluator _arith;
  final StringBuffer _stderr = StringBuffer();
  int _cmdSubsRun = 0;

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
    // Single chokepoint: any ExpansionError raised while expanding argv,
    // assignment RHS, for-word lists, or redirection targets anywhere beneath
    // this statement becomes a shell-like stderr + exit code instead of an
    // uncaught exception escaping Bash.exec.
    try {
      for (var i = 0; i < stmt.pipelines.length; i++) {
        if (i > 0) {
          final op = stmt.operators[i - 1];
          if (op == '&&') run = state.lastExitCode == 0;
          if (op == '||') run = state.lastExitCode != 0;
          if (op == ';') run = true;
        }
        if (!run) continue;
        final r = await _execPipeline(stmt.pipelines[i], stdin);
        stdout += r.stdout;
      }
    } on ExpansionError catch (e) {
      _stderr.write('dbash: ${e.message}\n');
      state.lastExitCode = e.exitCode;
      return ExecResult(stdout: stdout, exitCode: e.exitCode);
    } on ArithmeticError catch (e) {
      _stderr.write('dbash: ${e.message}\n');
      state.lastExitCode = 1;
      return ExecResult(stdout: stdout, exitCode: 1);
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
        _rejectRedirections(node.redirections, node.type);
        return _execIf(node, stdin);
      case ForNode():
        _rejectRedirections(node.redirections, node.type);
        return _execFor(node, stdin);
      case WhileNode():
        _rejectRedirections(node.redirections, node.type);
        return _execWhileUntil(node.condition, node.body, until: false);
      case UntilNode():
        _rejectRedirections(node.redirections, node.type);
        return _execWhileUntil(node.condition, node.body, until: true);
      case ArithmeticCommandNode():
        _rejectRedirections(node.redirections, node.type);
        return _execArithmeticCommand(node);
      case CStyleForNode():
        _rejectRedirections(node.redirections, node.type);
        return _execCStyleFor(node);
      default:
        throw UnimplementedError(
          'execution of ${node.type} is not in the MVP yet',
        );
    }
  }

  /// Compound-command redirections are not in the MVP. Reject them visibly
  /// rather than silently dropping them (see review of PR #4).
  void _rejectRedirections(List<RedirectionNode> redirs, String nodeType) {
    if (redirs.isNotEmpty) {
      throw UnimplementedError(
        'redirections on $nodeType are not in the MVP yet',
      );
    }
  }

  Future<ExecResult> _execSimpleCommand(
    SimpleCommandNode node,
    String stdin,
  ) async {
    // Standalone assignments persist to shell state. Their exit status is the
    // status of the last command substitution they ran, else 0 (POSIX 2.9.1).
    // We must NOT reset $? before expanding the RHS — `x=$?` has to read the
    // previous command's status — so default to 0 only when no substitution
    // actually ran (tracked by _cmdSubsRun); otherwise _runCommandSubstitution
    // has already set lastExitCode to the substitution's status.
    if (node.name == null) {
      final subsBefore = _cmdSubsRun;
      for (final a in node.assignments) {
        await _applyAssignment(a, state.env);
      }
      // A bare redirection (e.g. `> file`) still creates/truncates the target.
      final plan = await _planRedirections(node.redirections, stdin);
      final out = await _route(const ExecResult(), plan);
      if (_cmdSubsRun == subsBefore) state.lastExitCode = 0;
      return ExecResult(stdout: out, exitCode: state.lastExitCode);
    }

    // Same POSIX rule for a command whose name/args expand to nothing: count
    // substitutions across the expansion so an empty `argv` keeps the last
    // substitution's status (`$(false)`) but a bare `$emptyvar` still yields 0.
    final subsBefore = _cmdSubsRun;
    // Prefix assignments apply to a temp env for this command only.
    final env = Map<String, String>.of(state.env);
    for (final a in node.assignments) {
      await _applyAssignment(a, env);
    }

    final argv = [
      ...await _expander.expandWord(node.name!),
      ...await _expander.expandWords(node.args),
    ];

    // Redirections are planned (and validated) before the command runs so it
    // sees the right stdin; outputs are routed afterwards.
    final plan = await _planRedirections(node.redirections, stdin);

    if (argv.isEmpty) {
      final out = await _route(const ExecResult(), plan);
      if (_cmdSubsRun == subsBefore) state.lastExitCode = 0;
      return ExecResult(stdout: out, exitCode: state.lastExitCode);
    }

    final cmdResult =
        await _runNamed(argv.first, argv.sublist(1), env, plan.stdin);
    final out = await _route(cmdResult, plan);
    state.lastExitCode = cmdResult.exitCode;
    return ExecResult(stdout: out, exitCode: cmdResult.exitCode);
  }

  /// Run a resolved command name, returning its raw result (stdout/stderr/exit
  /// captured, not yet routed through redirections).
  Future<ExecResult> _runNamed(
    String name,
    List<String> args,
    Map<String, String> env,
    String stdin,
  ) async {
    switch (name) {
      case ':':
      case 'true':
        return const ExecResult();
      case 'false':
        return const ExecResult(exitCode: 1);
      case 'cd':
        return _builtinCd(args);
      case 'export':
        return _builtinExport(args, env);
      case 'unset':
        for (final n in args) {
          state.env.remove(n);
        }
        return const ExecResult();
    }

    final command = commands[name];
    if (command == null) {
      return ExecResult(
        stderr: 'dbash: $name: command not found\n',
        exitCode: 127,
      );
    }

    final ctx = CommandContext(
      fs: fs,
      cwd: state.cwd,
      env: env,
      stdin: stdin,
      exec: (cmd, {cwd, stdin}) =>
          Interpreter(fs: fs, state: state, commands: commands).run(parse(cmd)),
      getRegisteredCommands: () => commands.keys.toList(),
    );
    return command.execute(args, ctx);
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
        : await _expander.expandWords(node.words!);
    var stdout = '';
    for (final v in values) {
      state.env[node.variable] = v;
      stdout += await _runStatements(node.body);
    }
    return ExecResult(stdout: stdout, exitCode: state.lastExitCode);
  }

  Future<ExecResult> _execArithmeticCommand(ArithmeticCommandNode node) async {
    // `(( expr ))`: success (exit 0) when the result is non-zero, else 1.
    // An ArithmeticError (e.g. division by zero) propagates to the statement
    // chokepoint, which reports it and sets exit 1.
    final value = _arith.evaluate(node.expression);
    state.lastExitCode = value != 0 ? 0 : 1;
    return ExecResult(exitCode: state.lastExitCode);
  }

  Future<ExecResult> _execCStyleFor(CStyleForNode node) async {
    var stdout = '';
    if (node.init != null) _arith.evaluate(node.init!);
    var guard = 0;
    while (guard++ < 1000000) {
      // An empty condition is treated as true (infinite loop until break).
      final cond =
          node.condition == null ? 1 : _arith.evaluate(node.condition!);
      if (cond == 0) break;
      stdout += await _runStatements(node.body);
      if (node.update != null) _arith.evaluate(node.update!);
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

  /// Run a command-substitution body in a subshell sharing the filesystem,
  /// returning its stdout with trailing newlines stripped (bash semantics).
  /// Assignments inside `$(...)` do not leak to the parent; `$?` and any
  /// stderr do propagate.
  Future<String> _runCommandSubstitution(ScriptNode body) async {
    _cmdSubsRun++;
    final childState = ShellState(
      env: Map<String, String>.of(state.env),
      cwd: state.cwd,
      exported: {...state.exported},
      // Copy (not share) so a future `set`/`shift` in the subshell cannot
      // leak back to the parent — env/exported are already copied above.
      positionalParams: List.of(state.positionalParams),
      shellName: state.shellName,
    );
    final child = Interpreter(fs: fs, state: childState, commands: commands);
    final result = await child.run(body);
    state.lastExitCode = result.exitCode;
    if (result.stderr.isNotEmpty) _stderr.write(result.stderr);
    return result.stdout.replaceFirst(RegExp(r'\n+$'), '');
  }

  Future<String> _runStatements(List<StatementNode> statements) async {
    var stdout = '';
    for (final s in statements) {
      final r = await _execStatement(s, '');
      stdout += r.stdout;
    }
    return stdout;
  }

  Future<void> _applyAssignment(
    AssignmentNode a,
    Map<String, String> target,
  ) async {
    if (a.array != null) {
      throw UnimplementedError('array assignment is not in the MVP yet');
    }
    final value =
        a.value == null ? '' : await _expander.expandToString(a.value!);
    if (a.append) {
      target[a.name] = (target[a.name] ?? '') + value;
    } else {
      target[a.name] = value;
    }
  }

  // --- redirections ----------------------------------------------------------

  /// Validate and plan [redirs], reading any input file for stdin and computing
  /// where fd 1 and fd 2 point. Throws [UnimplementedError] for redirection
  /// forms outside the MVP (here-docs, `{fd}` vars, here-strings, unusual fds)
  /// so the gap is visible rather than silent.
  Future<_RedirPlan> _planRedirections(
    List<RedirectionNode> redirs,
    String stdin,
  ) async {
    var inStdin = stdin;
    _FileTarget? dest1;
    _FileTarget? dest2;
    for (final r in redirs) {
      final target = r.target;
      if (target is! WordNode) {
        throw UnimplementedError('here-doc redirection is not in the MVP yet');
      }
      if (r.fdVariable != null) {
        throw UnimplementedError('{fd} redirections are not in the MVP yet');
      }
      final word = await _expander.expandToString(target);
      final path = paths.resolvePath(state.cwd, word);
      switch (r.operator) {
        case '<':
          if (r.fd != null && r.fd != 0) {
            throw UnimplementedError(
              'input redirection on fd ${r.fd} is not in the MVP yet',
            );
          }
          if (!await fs.exists(path)) {
            throw ExpansionError('$word: No such file or directory');
          }
          inStdin = await fs.readFile(path);
        case '>':
        case '>|':
          (dest1, dest2) = _assignFd(
              r.fd ?? 1, _FileTarget(path, append: false), dest1, dest2);
        case '>>':
          (dest1, dest2) = _assignFd(
              r.fd ?? 1, _FileTarget(path, append: true), dest1, dest2);
        case '&>':
          final t = _FileTarget(path, append: false);
          dest1 = t;
          dest2 = t;
        case '&>>':
          final t = _FileTarget(path, append: true);
          dest1 = t;
          dest2 = t;
        case '>&':
          final fd = r.fd ?? 1;
          if (word == '1') {
            if (fd == 2) {
              dest2 = dest1;
            } else if (fd != 1) {
              _unsupportedFd(fd);
            }
          } else if (word == '2') {
            if (fd == 1) {
              dest1 = dest2;
            } else if (fd != 2) {
              _unsupportedFd(fd);
            }
          } else {
            throw UnimplementedError(
              'fd duplication to "$word" is not in the MVP yet',
            );
          }
        default:
          throw UnimplementedError(
            'redirection operator ${r.operator} is not in the MVP yet',
          );
      }
    }
    return _RedirPlan(inStdin, dest1, dest2);
  }

  (_FileTarget?, _FileTarget?) _assignFd(
    int fd,
    _FileTarget t,
    _FileTarget? d1,
    _FileTarget? d2,
  ) {
    if (fd == 1) return (t, d2);
    if (fd == 2) return (d1, t);
    _unsupportedFd(fd);
  }

  Never _unsupportedFd(int fd) =>
      throw UnimplementedError('redirection on fd $fd is not in the MVP yet');

  /// Route a command [result] through the [plan]: file-bound streams are
  /// written to the virtual FS, terminal stderr is buffered, and terminal
  /// stdout is returned (to flow on to a pipe or the caller).
  Future<String> _route(ExecResult result, _RedirPlan plan) async {
    final sinks = <_FileTarget, StringBuffer>{};
    var termOut = '';
    var termErr = '';
    void send(_FileTarget? dest, String content, {required bool isErr}) {
      if (dest == null) {
        if (isErr) {
          termErr += content;
        } else {
          termOut += content;
        }
      } else {
        (sinks[dest] ??= StringBuffer()).write(content);
      }
    }

    send(plan.dest1, result.stdout, isErr: false);
    send(plan.dest2, result.stderr, isErr: true);
    for (final entry in sinks.entries) {
      if (entry.key.append) {
        await fs.appendFile(entry.key.path, entry.value.toString());
      } else {
        await fs.writeFile(entry.key.path, entry.value.toString());
      }
    }
    if (termErr.isNotEmpty) _stderr.write(termErr);
    return termOut;
  }

  Future<ExecResult> _builtinCd(List<String> args) async {
    final target =
        args.isEmpty ? (state.env['HOME'] ?? '/home/user') : args.first;
    final resolved = paths.resolvePath(state.cwd, target);
    if (!await fs.exists(resolved)) {
      return ExecResult(
        stderr: 'dbash: cd: $target: No such file or directory\n',
        exitCode: 1,
      );
    }
    state.cwd = resolved;
    state.env['PWD'] = resolved;
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
    return const ExecResult();
  }
}

class _FileTarget {
  _FileTarget(this.path, {required this.append});
  final String path;
  final bool append;
}

class _RedirPlan {
  _RedirPlan(this.stdin, this.dest1, this.dest2);
  final String stdin;
  final _FileTarget? dest1;
  final _FileTarget? dest2;
}
