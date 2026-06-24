/// Command/arithmetic substitution boundary scanning.
///
/// Faithful port of `parser/parser-substitution.ts`. Finds the extent of a
/// `$(...)` or `` `...` `` substitution in a word string and recursively parses
/// the inner command text into a [ScriptNode]. Part of the `parser` library.
// ignore_for_file: lines_longer_than_80_chars, use_string_buffers
part of 'parser.dart';

final RegExp _substLetter = RegExp('[a-zA-Z_]');
final RegExp _substLeadingTabs = RegExp(r'^\t+');

/// Whether `$((` at [start] in [value] is a command substitution with a nested
/// subshell rather than arithmetic.
bool isDollarDparenSubshellHelper(String value, int start) {
  final len = value.length;
  var pos = start + 3;
  var depth = 2;
  var inSingleQuote = false;
  var inDoubleQuote = false;

  while (pos < len && depth > 0) {
    final c = value[pos];

    if (inSingleQuote) {
      if (c == "'") inSingleQuote = false;
      pos++;
      continue;
    }
    if (inDoubleQuote) {
      if (c == r'\') {
        pos += 2;
        continue;
      }
      if (c == '"') inDoubleQuote = false;
      pos++;
      continue;
    }

    if (c == "'") {
      inSingleQuote = true;
      pos++;
      continue;
    }
    if (c == '"') {
      inDoubleQuote = true;
      pos++;
      continue;
    }
    if (c == r'\') {
      pos += 2;
      continue;
    }
    if (c == '(') {
      depth++;
      pos++;
      continue;
    }
    if (c == ')') {
      depth--;
      if (depth == 1) {
        final nextPos = pos + 1;
        if (nextPos < len && value[nextPos] == ')') {
          return false;
        }
        return true;
      }
      if (depth == 0) return false;
      pos++;
      continue;
    }

    if (depth == 1) {
      if (c == '|' && pos + 1 < len && value[pos + 1] == '|') return true;
      if (c == '&' && pos + 1 < len && value[pos + 1] == '&') return true;
      if (c == '|' && pos + 1 < len && value[pos + 1] != '|') return true;
    }
    pos++;
  }
  return false;
}

int _skipHeredocBodies(
  String value,
  int nlIndex,
  List<({String delim, bool stripTabs})> heredocs,
) {
  var lineStart = nlIndex + 1;
  for (final h in heredocs) {
    while (true) {
      if (lineStart >= value.length) return value.length;
      var lineEnd = value.indexOf('\n', lineStart);
      if (lineEnd == -1) lineEnd = value.length;
      var line = _slice(value, lineStart, lineEnd);
      if (h.stripTabs) line = line.replaceFirst(_substLeadingTabs, '');
      if (line == h.delim) {
        lineStart = lineEnd + 1;
        break;
      }
      if (lineEnd >= value.length) return value.length;
      lineStart = lineEnd + 1;
    }
  }
  return lineStart < value.length ? lineStart : value.length;
}

/// Parse a `$(...)` command substitution from [value] starting at [start].
({CommandSubstitutionPart part, int endIndex}) parseCommandSubstitutionFromString(
  String value,
  int start,
  Parser Function() makeParser,
  Never Function(String) onError,
) {
  final cmdStart = start + 2;
  var depth = 1;
  var i = cmdStart;

  var inSingleQuote = false;
  var inDoubleQuote = false;
  var caseDepth = 0;
  var inCasePattern = false;
  var wordBuffer = '';
  final pendingHeredocs = <({String delim, bool stripTabs})>[];
  var arithDepth = 0;

  while (i < value.length && depth > 0) {
    final c = value[i];

    if (inSingleQuote) {
      if (c == "'") inSingleQuote = false;
    } else if (inDoubleQuote) {
      if (c == r'\' && i + 1 < value.length) {
        i++;
      } else if (c == '"') {
        inDoubleQuote = false;
      }
    } else {
      if (c == '(' && _charAt(value, i + 1) == '(') {
        arithDepth++;
      } else if (c == ')' && _charAt(value, i + 1) == ')' && arithDepth > 0) {
        arithDepth--;
      }

      if (arithDepth == 0 &&
          c == '<' &&
          _charAt(value, i + 1) == '<' &&
          _charAt(value, i + 2) != '<') {
        var p = i + 2;
        var stripTabs = false;
        if (_charAt(value, p) == '-') {
          stripTabs = true;
          p++;
        }
        while (_charAt(value, p) == ' ' || _charAt(value, p) == '\t') {
          p++;
        }
        final hd = readHeredocDelimiter(value, p);
        if (hd.delim.isNotEmpty) {
          pendingHeredocs.add((delim: hd.delim, stripTabs: stripTabs));
          wordBuffer = '';
          i = hd.endPos;
          continue;
        }
      }

      if (c == '\n' && pendingHeredocs.isNotEmpty) {
        final resume = _skipHeredocBodies(value, i, pendingHeredocs);
        pendingHeredocs.clear();
        wordBuffer = '';
        i = resume;
        continue;
      }

      if (c == "'") {
        inSingleQuote = true;
        wordBuffer = '';
      } else if (c == '"') {
        inDoubleQuote = true;
        wordBuffer = '';
      } else if (c == r'\' && i + 1 < value.length) {
        i++;
        wordBuffer = '';
      } else if (_substLetter.hasMatch(c)) {
        wordBuffer += c;
      } else {
        if (wordBuffer == 'case') {
          caseDepth++;
          inCasePattern = false;
        } else if (wordBuffer == 'in' && caseDepth > 0) {
          inCasePattern = true;
        } else if (wordBuffer == 'esac' && caseDepth > 0) {
          caseDepth--;
          inCasePattern = false;
        }
        wordBuffer = '';

        if (c == '(') {
          if (i > 0 && value[i - 1] == r'$') {
            depth++;
          } else if (!inCasePattern) {
            depth++;
          }
        } else if (c == ')') {
          if (inCasePattern) {
            inCasePattern = false;
          } else {
            depth--;
          }
        } else if (c == ';') {
          if (caseDepth > 0 && i + 1 < value.length && value[i + 1] == ';') {
            inCasePattern = true;
          }
        }
      }
    }

    if (depth > 0) i++;
  }

  if (depth > 0) {
    onError("unexpected EOF while looking for matching `)'");
  }

  final cmdStr = _slice(value, cmdStart, i);
  final body = makeParser().parse(cmdStr);
  return (
    part: CommandSubstitutionPart(body),
    endIndex: i + 1,
  );
}

/// Parse a backtick command substitution from [value] starting at [start].
({CommandSubstitutionPart part, int endIndex}) parseBacktickSubstitutionFromString(
  String value,
  int start, {
  required bool inDoubleQuotes,
  required Parser Function() makeParser,
  required Never Function(String) onError,
}) {
  final cmdStart = start + 1;
  var i = cmdStart;
  var cmdStr = '';

  while (i < value.length && value[i] != '`') {
    if (value[i] == r'\') {
      final next = _charAt(value, i + 1);
      final isSpecial = next == r'$' ||
          next == '`' ||
          next == r'\' ||
          next == '\n' ||
          (inDoubleQuotes && next == '"');
      if (isSpecial) {
        if (next != '\n') cmdStr += next;
        i += 2;
      } else {
        cmdStr += value[i];
        i++;
      }
    } else {
      cmdStr += value[i];
      i++;
    }
  }

  if (i >= value.length) {
    onError("unexpected EOF while looking for matching ``'");
  }

  final body = makeParser().parse(cmdStr);
  return (
    part: CommandSubstitutionPart(body, legacy: true),
    endIndex: i + 1,
  );
}
