/// Runtime word expansion (MVP subset).
///
/// Implements the bash expansion pipeline for the supported word forms:
/// brace expansion, tilde expansion, parameter expansion (simple plus the
/// default/assign/error/alternative/length operators), quote handling, and
/// IFS word splitting of unquoted expansions. Globbing, command/arithmetic
/// substitution, and the remaining parameter operators are not in the MVP and
/// throw [UnimplementedError] at their boundary.
library;

import 'package:dbash/src/ast/ast.dart';

/// An error raised during expansion (e.g. `${x:?msg}` on an unset variable).
class ExpansionError implements Exception {
  /// Creates an expansion error.
  ExpansionError(this.message, [this.exitCode = 1]);

  /// The message written to stderr.
  final String message;

  /// The exit code to surface.
  final int exitCode;

  @override
  String toString() => message;
}

/// The shell state the [Expander] reads and writes.
abstract class ExpansionHost {
  /// Look up a variable's value, or null if unset.
  String? getVar(String name);

  /// Assign a variable (used by `${x:=default}`).
  void setVar(String name, String value);

  /// The exit code of the last command (for `$?`).
  int get lastExitCode;

  /// Positional parameters `$1`, `$2`, … (index 0 is `$1`).
  List<String> get positionalParams;

  /// The shell/script name (`$0`).
  String get shellName;
}

/// Expands [WordNode]s into argument fields.
class Expander {
  /// Creates an expander backed by [host].
  Expander(this.host);

  /// The shell state.
  final ExpansionHost host;

  static final RegExp _ifsWs = RegExp(r'[ \t\n]+');

  /// Expand a list of [words] into argument fields.
  List<String> expandWords(List<WordNode> words) {
    final out = <String>[];
    for (final w in words) {
      out.addAll(expandWord(w));
    }
    return out;
  }

  /// Expand a single [word] into zero or more fields.
  List<String> expandWord(WordNode word) {
    final combos = _braceExpand(word.parts);
    final fields = <String>[];
    for (final parts in combos) {
      fields.addAll(_expandParts(parts));
    }
    return fields;
  }

  // --- brace expansion -------------------------------------------------------

  List<List<WordPart>> _braceExpand(List<WordPart> parts) {
    var combos = <List<WordPart>>[<WordPart>[]];
    for (final part in parts) {
      if (part is BraceExpansionPart) {
        final alternatives = _braceAlternatives(part);
        final next = <List<WordPart>>[];
        for (final combo in combos) {
          for (final alt in alternatives) {
            next.add([...combo, ...alt]);
          }
        }
        combos = next;
      } else {
        for (final combo in combos) {
          combo.add(part);
        }
      }
    }
    return combos;
  }

  List<List<WordPart>> _braceAlternatives(BraceExpansionPart brace) {
    final result = <List<WordPart>>[];
    for (final item in brace.items) {
      if (item is BraceWordItem) {
        result.add(item.word.parts);
      } else if (item is BraceRangeItem) {
        for (final v in _expandRange(item)) {
          result.add([LiteralPart(v)]);
        }
      }
    }
    return result;
  }

  List<String> _expandRange(BraceRangeItem item) {
    final start = item.start;
    final end = item.end;
    final step = (item.step ?? 1).abs().clamp(1, 1 << 30);
    final out = <String>[];
    if (start is int && end is int) {
      final width = _zeroPadWidth(item.startStr, item.endStr);
      if (start <= end) {
        for (var i = start; i <= end; i += step) {
          out.add(_pad(i, width));
        }
      } else {
        for (var i = start; i >= end; i -= step) {
          out.add(_pad(i, width));
        }
      }
    } else if (start is String && end is String) {
      final a = start.codeUnitAt(0);
      final b = end.codeUnitAt(0);
      if (a <= b) {
        for (var c = a; c <= b; c += step) {
          out.add(String.fromCharCode(c));
        }
      } else {
        for (var c = a; c >= b; c -= step) {
          out.add(String.fromCharCode(c));
        }
      }
    }
    return out;
  }

  int _zeroPadWidth(String? a, String? b) {
    var width = 0;
    for (final s in [a, b]) {
      if (s == null || s.length <= 1) continue;
      if (s.startsWith('0') || s.startsWith('-0')) {
        width = width > s.length ? width : s.length;
      }
    }
    return width;
  }

  String _pad(int value, int width) {
    if (width == 0) return '$value';
    final neg = value < 0;
    final digits = value.abs().toString();
    final padded = digits.padLeft(neg ? width - 1 : width, '0');
    return neg ? '-$padded' : padded;
  }

  // --- field building --------------------------------------------------------

  List<String> _expandParts(List<WordPart> parts) {
    final fields = <String>[];
    String? cur;

    void appendLiteral(String text) => cur = (cur ?? '') + text;

    void appendSplit(String value) {
      if (value.isEmpty) return;
      final pieces = value.split(_ifsWs);
      for (var i = 0; i < pieces.length; i++) {
        if (i == 0) {
          cur = (cur ?? '') + pieces[0];
        } else {
          fields.add(cur ?? '');
          cur = pieces[i];
        }
      }
    }

    for (final part in parts) {
      switch (part) {
        case LiteralPart():
          appendLiteral(part.value);
        case SingleQuotedPart():
          appendLiteral(part.value);
        case EscapedPart():
          appendLiteral(part.value);
        case DoubleQuotedPart():
          appendLiteral(_expandQuoted(part.parts));
        case TildeExpansionPart():
          appendLiteral(_expandTilde(part));
        case GlobPart():
          appendLiteral(part.pattern);
        case ParameterExpansionPart():
          appendSplit(_expandParameter(part));
        case CommandSubstitutionPart():
        case ArithmeticExpansionPart():
        case ProcessSubstitutionPart():
        case BraceExpansionPart():
          throw UnimplementedError(
            'runtime expansion of ${part.type} is not in the MVP yet',
          );
      }
    }

    if (cur != null) fields.add(cur!);
    return fields;
  }

  String _expandQuoted(List<WordPart> parts) {
    final sb = StringBuffer();
    for (final part in parts) {
      switch (part) {
        case LiteralPart():
          sb.write(part.value);
        case EscapedPart():
          sb.write(part.value);
        case SingleQuotedPart():
          sb.write(part.value);
        case ParameterExpansionPart():
          sb.write(_expandParameter(part));
        case DoubleQuotedPart():
          sb.write(_expandQuoted(part.parts));
        case CommandSubstitutionPart():
        case ArithmeticExpansionPart():
          throw UnimplementedError(
            'runtime expansion of ${part.type} is not in the MVP yet',
          );
        case ProcessSubstitutionPart():
        case BraceExpansionPart():
        case TildeExpansionPart():
        case GlobPart():
          // Not special inside double quotes — emit literally where possible.
          sb.write(_partLiteral(part));
      }
    }
    return sb.toString();
  }

  String _partLiteral(WordPart part) => switch (part) {
        GlobPart() => part.pattern,
        TildeExpansionPart() => '~${part.user ?? ''}',
        _ => '',
      };

  String _expandTilde(TildeExpansionPart part) {
    if (part.user != null && part.user!.isNotEmpty) {
      return '~${part.user}';
    }
    return host.getVar('HOME') ?? '/home/user';
  }

  // --- parameter expansion ---------------------------------------------------

  String _expandParameter(ParameterExpansionPart part) {
    final name = part.parameter;
    final raw = _resolveParameter(name);
    final op = part.operation;

    if (op == null) return raw ?? '';

    final isUnset = raw == null;
    final isEmpty = raw == null || raw.isEmpty;

    switch (op) {
      case DefaultValueOp():
        final cond = op.checkEmpty ? isEmpty : isUnset;
        return cond ? _expandOpWord(op.word) : raw;
      case AssignDefaultOp():
        final cond = op.checkEmpty ? isEmpty : isUnset;
        if (cond) {
          final v = _expandOpWord(op.word);
          host.setVar(name, v);
          return v;
        }
        return raw;
      case ErrorIfUnsetOp():
        final cond = op.checkEmpty ? isEmpty : isUnset;
        if (cond) {
          final msg = op.word != null
              ? _expandOpWord(op.word!)
              : 'parameter null or not set';
          throw ExpansionError('$name: $msg');
        }
        return raw;
      case UseAlternativeOp():
        final cond = op.checkEmpty ? !isEmpty : !isUnset;
        return cond ? _expandOpWord(op.word) : '';
      case LengthOp():
        return (raw ?? '').length.toString();
      default:
        throw UnimplementedError(
          'parameter operation ${op.type} is not in the MVP yet',
        );
    }
  }

  String _expandOpWord(WordNode word) => expandWord(word).join(' ');

  /// Expand [word] to a single string without word splitting (e.g. for the
  /// right-hand side of an assignment).
  String expandToString(WordNode word) {
    final sb = StringBuffer();
    for (final part in word.parts) {
      switch (part) {
        case LiteralPart():
          sb.write(part.value);
        case SingleQuotedPart():
          sb.write(part.value);
        case EscapedPart():
          sb.write(part.value);
        case DoubleQuotedPart():
          sb.write(_expandQuoted(part.parts));
        case ParameterExpansionPart():
          sb.write(_expandParameter(part));
        case TildeExpansionPart():
          sb.write(_expandTilde(part));
        case GlobPart():
          sb.write(part.pattern);
        case CommandSubstitutionPart():
        case ArithmeticExpansionPart():
        case ProcessSubstitutionPart():
        case BraceExpansionPart():
          throw UnimplementedError(
            'runtime expansion of ${part.type} is not in the MVP yet',
          );
      }
    }
    return sb.toString();
  }

  String? _resolveParameter(String name) {
    switch (name) {
      case '?':
        return host.lastExitCode.toString();
      case r'$':
        return '1';
      case '0':
        return host.shellName;
      case '#':
        return host.positionalParams.length.toString();
      case '@':
      case '*':
        return host.positionalParams.join(' ');
      case '!':
      case '-':
        return '';
    }
    final code = name.length == 1 ? name.codeUnitAt(0) : -1;
    if (code >= 0x31 && code <= 0x39) {
      final idx = int.parse(name) - 1;
      return idx < host.positionalParams.length
          ? host.positionalParams[idx]
          : null;
    }
    return host.getVar(name);
  }
}
