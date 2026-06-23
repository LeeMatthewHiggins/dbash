/// Expansion parser: parameter expansion, double-quote content, and the word
/// part dispatcher.
///
/// Faithful port of `parser/expansion-parser.ts`. Part of the `parser` library.
/// Calls into the still-unported arithmetic and command-substitution parsers
/// throw [UnimplementedError]; all other word forms parse fully.
// ignore_for_file: lines_longer_than_80_chars, use_string_buffers
// ignore_for_file: unnecessary_lambdas, unnecessary_raw_strings
part of 'parser.dart';

final RegExp _lengthOpFollow = RegExp(r'[}:#%/^,]');
final RegExp _opChars = RegExp(r'[:=\-+?#%/^,@]');
final RegExp _transformOps = RegExp('[QPaAEKkuUL]');
final RegExp _validAfterName = RegExp(r'[:\-+=?#%/^,@[]');
final RegExp _testOps = RegExp(r'[-+=?]');
final RegExp _arrayKeysRe = RegExp(r'^([a-zA-Z_][a-zA-Z0-9_]*)\[([@*])\]$');
final RegExp _expansionStart = RegExp(r'[a-zA-Z_0-9@*#?$!-]');
final RegExp _specialNameChars = RegExp(r'[@*#?$!-]');

List<WordPart> _ensureNonEmpty(List<WordPart> parts) =>
    parts.isNotEmpty ? parts : [LiteralPart('')];

int _findExtglobClose(String value, int openIdx) {
  var depth = 1;
  var i = openIdx + 1;
  while (i < value.length && depth > 0) {
    final c = value[i];
    if (c == r'\') {
      i += 2;
      continue;
    }
    if ('@*+?!'.contains(c) && i + 1 < value.length && value[i + 1] == '(') {
      i++;
      depth++;
      i++;
      continue;
    }
    if (c == '(') {
      depth++;
    } else if (c == ')') {
      depth--;
      if (depth == 0) return i;
    }
    i++;
  }
  return -1;
}

({ParameterExpansionPart part, int endIndex}) _parseSimpleParameter(
  Parser p,
  String value,
  int start,
) {
  var i = start + 1;
  final char = _charAt(value, i);

  if (r'@*#?$!-0123456789'.contains(char) && char.isNotEmpty) {
    return (part: ParameterExpansionPart(char), endIndex: i + 1);
  }

  var name = '';
  while (i < value.length && _alnumUnderscore.hasMatch(value[i])) {
    name += value[i];
    i++;
  }
  return (part: ParameterExpansionPart(name), endIndex: i);
}

({ParameterExpansionPart part, int endIndex}) _parseParameterExpansion(
  Parser p,
  String value,
  int start, {
  bool quoted = false,
}) {
  var i = start + 2;

  var indirection = false;
  if (_charAt(value, i) == '!') {
    indirection = true;
    i++;
  }

  var lengthOp = false;
  if (_charAt(value, i) == '#' &&
      !_lengthOpFollow.hasMatch(
        _charAt(value, i + 1).isEmpty ? '}' : _charAt(value, i + 1),
      )) {
    lengthOp = true;
    i++;
  }

  var name = '';
  final firstChar = _charAt(value, i);
  if (_specialNameChars.hasMatch(firstChar) &&
      !_alnumUnderscore.hasMatch(
        _charAt(value, i + 1).isEmpty ? '' : _charAt(value, i + 1),
      )) {
    name = firstChar;
    i++;
  } else {
    while (i < value.length && _alnumUnderscore.hasMatch(value[i])) {
      name += value[i];
      i++;
    }
  }

  if (_charAt(value, i) == '[') {
    final closeIdx = findMatchingBracket(p, value, i, '[', ']');
    name += _slice(value, i, closeIdx + 1);
    i = closeIdx + 1;

    if (_charAt(value, i) == '[') {
      var depth = 1;
      var j = i;
      while (j < value.length && depth > 0) {
        if (value[j] == '{') {
          depth++;
        } else if (value[j] == '}') {
          depth--;
        }
        if (depth > 0) j++;
      }
      final badText = _slice(value, start + 2, j);
      return (
        part: ParameterExpansionPart('', BadSubstitutionOp(badText)),
        endIndex: j + 1,
      );
    }
  }

  if (name == '' && !indirection && !lengthOp && _charAt(value, i) != '}') {
    var depth = 1;
    var j = i;
    while (j < value.length && depth > 0) {
      if (value[j] == '{') {
        depth++;
      } else if (value[j] == '}') {
        depth--;
      }
      if (depth > 0) j++;
    }
    if (depth > 0) {
      throw ParseException("unexpected EOF while looking for matching '}'", 0, 0);
    }
    final badText = _slice(value, start + 2, j);
    return (
      part: ParameterExpansionPart('', BadSubstitutionOp(badText)),
      endIndex: j + 1,
    );
  }

  ParameterOperation? operation;

  if (indirection) {
    final arrayKeysMatch = _arrayKeysRe.firstMatch(name);
    if (arrayKeysMatch != null) {
      if (i < value.length &&
          value[i] != '}' &&
          _opChars.hasMatch(value[i])) {
        final opResult = _parseParameterOperation(p, value, i, name, quoted: quoted);
        if (opResult.operation != null) {
          operation = IndirectionOp(
            opResult.operation! as InnerParameterOperation,
          );
          i = opResult.endIndex;
        } else {
          operation = ArrayKeysOp(
            arrayKeysMatch.group(1)!,
            arrayKeysMatch.group(2) == '*',
          );
          name = '';
        }
      } else {
        operation = ArrayKeysOp(
          arrayKeysMatch.group(1)!,
          arrayKeysMatch.group(2) == '*',
        );
        name = '';
      }
    } else if (_charAt(value, i) == '*' ||
        (_charAt(value, i) == '@' &&
            !_transformOps.hasMatch(
              _charAt(value, i + 1).isEmpty ? '' : _charAt(value, i + 1),
            ))) {
      final suffix = value[i];
      i++;
      operation = VarNamePrefixOp(name, suffix == '*');
      name = '';
    } else {
      if (i < value.length &&
          value[i] != '}' &&
          _opChars.hasMatch(value[i])) {
        final opResult = _parseParameterOperation(p, value, i, name, quoted: quoted);
        if (opResult.operation != null) {
          operation = IndirectionOp(
            opResult.operation! as InnerParameterOperation,
          );
          i = opResult.endIndex;
        } else {
          operation = IndirectionOp();
        }
      } else {
        operation = IndirectionOp();
      }
    }
  } else if (lengthOp) {
    if (_charAt(value, i) == ':') {
      operation = LengthSliceErrorOp();
      while (i < value.length && value[i] != '}') {
        i++;
      }
    } else if (_charAt(value, i) != '}' &&
        _testOps.hasMatch(_charAt(value, i))) {
      final close = value.indexOf('}', i);
      p.error('\${#$name${_slice(value, i, close)}}: bad substitution');
    } else if (_charAt(value, i) == '/') {
      final close = value.indexOf('}', i);
      p.error('\${#$name${_slice(value, i, close)}}: bad substitution');
    } else {
      operation = LengthOp();
    }
  }

  if (operation == null && i < value.length && value[i] != '}') {
    final opResult = _parseParameterOperation(p, value, i, name, quoted: quoted);
    operation = opResult.operation;
    i = opResult.endIndex;
  }

  if (i < value.length && value[i] != '}') {
    final c = value[i];
    if (!_validAfterName.hasMatch(c)) {
      var endIdx = i;
      while (endIdx < value.length && value[endIdx] != '}') {
        endIdx++;
      }
      final badExp = _slice(value, start, endIdx + 1);
      p.error('\${${_slice(badExp, 2, badExp.length - 1)}}: bad substitution');
    }
  }

  while (i < value.length && value[i] != '}') {
    i++;
  }

  if (i >= value.length) {
    throw ParseException("unexpected EOF while looking for matching '}'", 0, 0);
  }

  return (part: ParameterExpansionPart(name, operation), endIndex: i + 1);
}

({ParameterOperation? operation, int endIndex}) _parseParameterOperation(
  Parser p,
  String value,
  int start,
  String paramName, {
  bool quoted = false,
}) {
  var i = start;
  final char = _charAt(value, i);
  final nextChar = _charAt(value, i + 1);

  if (char == ':') {
    final op = nextChar;
    if ('-=?+'.contains(op) && op.isNotEmpty) {
      const checkEmpty = true;
      i += 2;
      final wordEnd = findParameterOperationEnd(p, value, i);
      final wordStr = _slice(value, i, wordEnd);
      final wordParts = parseWordParts(
        p,
        wordStr,
        isAssignment: true,
        singleQuotesAreLiteral: quoted,
        inParameterExpansion: true,
      );
      final word = WordNode(_ensureNonEmpty(wordParts));
      if (op == '-') {
        return (operation: DefaultValueOp(word, checkEmpty), endIndex: wordEnd);
      }
      if (op == '=') {
        return (operation: AssignDefaultOp(word, checkEmpty), endIndex: wordEnd);
      }
      if (op == '?') {
        return (operation: ErrorIfUnsetOp(word, checkEmpty), endIndex: wordEnd);
      }
      if (op == '+') {
        return (operation: UseAlternativeOp(word, checkEmpty), endIndex: wordEnd);
      }
    }

    i++;
    final wordEnd = findParameterOperationEnd(p, value, i);
    final wordStr = _slice(value, i, wordEnd);

    var colonIdx = -1;
    var depth = 0;
    var ternaryDepth = 0;
    for (var j = 0; j < wordStr.length; j++) {
      final c = wordStr[j];
      if (c == '(' || c == '[') {
        depth++;
      } else if (c == ')' || c == ']') {
        depth--;
      } else if (c == '?' && depth == 0) {
        ternaryDepth++;
      } else if (c == ':' && depth == 0) {
        if (ternaryDepth > 0) {
          ternaryDepth--;
        } else {
          colonIdx = j;
          break;
        }
      }
    }

    final offsetStr = colonIdx >= 0 ? wordStr.substring(0, colonIdx) : wordStr;
    final lengthStr = colonIdx >= 0 ? wordStr.substring(colonIdx + 1) : null;
    return (
      operation: SubstringOp(
        parseArithExprFromString(p, offsetStr),
        lengthStr != null ? parseArithExprFromString(p, lengthStr) : null,
      ),
      endIndex: wordEnd,
    );
  }

  if ('-=?+'.contains(char) && char.isNotEmpty) {
    i++;
    final wordEnd = findParameterOperationEnd(p, value, i);
    final wordStr = _slice(value, i, wordEnd);
    final wordParts = parseWordParts(
      p,
      wordStr,
      isAssignment: true,
      singleQuotesAreLiteral: quoted,
      inParameterExpansion: true,
    );
    final word = WordNode(_ensureNonEmpty(wordParts));
    if (char == '-') {
      return (
        operation: DefaultValueOp(word, false),
        endIndex: wordEnd,
      );
    }
    if (char == '=') {
      return (operation: AssignDefaultOp(word, false), endIndex: wordEnd);
    }
    if (char == '?') {
      return (
        operation: ErrorIfUnsetOp(wordStr.isNotEmpty ? word : null, false),
        endIndex: wordEnd,
      );
    }
    if (char == '+') {
      return (operation: UseAlternativeOp(word, false), endIndex: wordEnd);
    }
  }

  if (char == '#' || char == '%') {
    final greedy = nextChar == char;
    final side = char == '#' ? 'prefix' : 'suffix';
    i += greedy ? 2 : 1;
    final patternEnd = findParameterOperationEnd(p, value, i);
    final patternStr = _slice(value, i, patternEnd);
    final pattern = WordNode(_ensureNonEmpty(parseWordParts(p, patternStr)));
    return (
      operation: PatternRemovalOp(pattern, side, greedy),
      endIndex: patternEnd,
    );
  }

  if (char == '/') {
    final all = nextChar == '/';
    i += all ? 2 : 1;
    String? anchor;
    if (_charAt(value, i) == '#') {
      anchor = 'start';
      i++;
    } else if (_charAt(value, i) == '%') {
      anchor = 'end';
      i++;
    }

    int patternEnd;
    if (anchor != null &&
        (_charAt(value, i) == '/' || _charAt(value, i) == '}')) {
      patternEnd = i;
    } else {
      patternEnd = findPatternEnd(p, value, i);
    }
    final patternStr = _slice(value, i, patternEnd);
    final pattern = WordNode(_ensureNonEmpty(parseWordParts(p, patternStr)));

    WordNode? replacement;
    var endIdx = patternEnd;
    if (_charAt(value, patternEnd) == '/') {
      final replaceStart = patternEnd + 1;
      final replaceEnd = findParameterOperationEnd(p, value, replaceStart);
      final replaceStr = _slice(value, replaceStart, replaceEnd);
      replacement = WordNode(_ensureNonEmpty(parseWordParts(p, replaceStr)));
      endIdx = replaceEnd;
    }

    return (
      operation: PatternReplacementOp(pattern, replacement, all, anchor),
      endIndex: endIdx,
    );
  }

  if (char == '^' || char == ',') {
    final all = nextChar == char;
    final direction = char == '^' ? 'upper' : 'lower';
    i += all ? 2 : 1;
    final patternEnd = findParameterOperationEnd(p, value, i);
    final patternStr = _slice(value, i, patternEnd);
    final pattern =
        patternStr.isNotEmpty ? WordNode([LiteralPart(patternStr)]) : null;
    return (
      operation: CaseModificationOp(direction, all, pattern),
      endIndex: patternEnd,
    );
  }

  if (char == '@' && _transformOps.hasMatch(nextChar)) {
    return (operation: TransformOp(nextChar), endIndex: i + 2);
  }

  return (operation: null, endIndex: i);
}

({WordPart? part, int endIndex}) _parseExpansion(
  Parser p,
  String value,
  int start, {
  bool quoted = false,
}) {
  final i = start + 1;
  if (i >= value.length) {
    return (part: LiteralPart(r'$'), endIndex: i);
  }

  final char = value[i];

  if (char == '(' && _charAt(value, i + 1) == '(') {
    if (p.isDollarDparenSubshell(value, start)) {
      final r = p.parseCommandSubstitution(value, start);
      return (part: r.part, endIndex: r.endIndex);
    }
    final r = p.parseArithmeticExpansion(value, start);
    return (part: r.part, endIndex: r.endIndex);
  }

  if (char == '[') {
    var depth = 1;
    var j = i + 1;
    while (j < value.length && depth > 0) {
      if (value[j] == '[') {
        depth++;
      } else if (value[j] == ']') {
        depth--;
      }
      if (depth > 0) j++;
    }
    if (depth == 0) {
      final expr = _slice(value, i + 1, j);
      final arithExpr = p.parseArithmeticExpression(expr);
      return (part: ArithmeticExpansionPart(arithExpr), endIndex: j + 1);
    }
  }

  if (char == '(') {
    final r = p.parseCommandSubstitution(value, start);
    return (part: r.part, endIndex: r.endIndex);
  }

  if (char == '{') {
    final r = _parseParameterExpansion(p, value, start, quoted: quoted);
    return (part: r.part, endIndex: r.endIndex);
  }

  if (_expansionStart.hasMatch(char)) {
    final r = _parseSimpleParameter(p, value, start);
    return (part: r.part, endIndex: r.endIndex);
  }

  return (part: LiteralPart(r'$'), endIndex: i);
}

List<WordPart> _parseDoubleQuotedContent(Parser p, String value) {
  final parts = <WordPart>[];
  var i = 0;
  var literal = '';

  void flushLiteral() {
    if (literal.isNotEmpty) {
      parts.add(LiteralPart(literal));
      literal = '';
    }
  }

  while (i < value.length) {
    final char = value[i];
    if (char == r'\' && i + 1 < value.length) {
      final next = value[i + 1];
      if (next == r'$' || next == '`' || next == '"' || next == r'\') {
        literal += next;
        i += 2;
        continue;
      }
      literal += char;
      i++;
      continue;
    }
    if (char == r'$') {
      flushLiteral();
      final r = _parseExpansion(p, value, i, quoted: true);
      if (r.part != null) parts.add(r.part!);
      i = r.endIndex;
      continue;
    }
    if (char == '`') {
      flushLiteral();
      final r = p.parseBacktickSubstitution(value, i, inDoubleQuotes: true);
      parts.add(r.part);
      i = r.endIndex;
      continue;
    }
    literal += char;
    i++;
  }

  flushLiteral();
  return parts;
}

({WordPart part, int endIndex}) _parseDoubleQuoted(
  Parser p,
  String value,
  int start,
) {
  final innerParts = <WordPart>[];
  var i = start;
  var literal = '';

  void flushLiteral() {
    if (literal.isNotEmpty) {
      innerParts.add(LiteralPart(literal));
      literal = '';
    }
  }

  while (i < value.length && value[i] != '"') {
    final char = value[i];
    if (char == r'\' && i + 1 < value.length) {
      final next = value[i + 1];
      if ('"\\\$`\n'.contains(next)) {
        literal += next;
        i += 2;
        continue;
      }
      literal += char;
      i++;
      continue;
    }
    if (char == r'$') {
      flushLiteral();
      final r = _parseExpansion(p, value, i, quoted: true);
      if (r.part != null) innerParts.add(r.part!);
      i = r.endIndex;
      continue;
    }
    if (char == '`') {
      flushLiteral();
      final r = p.parseBacktickSubstitution(value, i, inDoubleQuotes: true);
      innerParts.add(r.part);
      i = r.endIndex;
      continue;
    }
    literal += char;
    i++;
  }

  flushLiteral();
  return (part: DoubleQuotedPart(innerParts), endIndex: i);
}

/// Parse the parts of a single shell word from [value].
List<WordPart> parseWordParts(
  Parser p,
  String value, {
  bool quoted = false,
  bool singleQuoted = false,
  bool isAssignment = false,
  bool hereDoc = false,
  bool singleQuotesAreLiteral = false,
  bool noBraceExpansion = false,
  bool regexPattern = false,
  bool inParameterExpansion = false,
}) {
  if (singleQuoted) {
    return [SingleQuotedPart(value)];
  }

  if (quoted) {
    return [DoubleQuotedPart(_parseDoubleQuotedContent(p, value))];
  }

  if (value.length >= 2 &&
      value[0] == '"' &&
      value[value.length - 1] == '"') {
    final inner = value.substring(1, value.length - 1);
    var hasUnescapedQuote = false;
    for (var j = 0; j < inner.length; j++) {
      if (inner[j] == '"') {
        hasUnescapedQuote = true;
        break;
      }
      if (inner[j] == r'\' && j + 1 < inner.length) {
        j++;
      }
    }
    if (!hasUnescapedQuote) {
      return [DoubleQuotedPart(_parseDoubleQuotedContent(p, inner))];
    }
  }

  final parts = <WordPart>[];
  var i = 0;
  var literal = '';

  void flushLiteral() {
    if (literal.isNotEmpty) {
      parts.add(LiteralPart(literal));
      literal = '';
    }
  }

  while (i < value.length) {
    final char = value[i];

    if (char == r'\' && i + 1 < value.length) {
      final next = value[i + 1];

      if (regexPattern) {
        flushLiteral();
        parts.add(EscapedPart(next));
        i += 2;
        continue;
      }

      final isEscapable = hereDoc
          ? next == r'$' || next == '`' || next == '\n'
          : next == r'$' ||
              next == '`' ||
              next == '"' ||
              next == "'" ||
              next == '\n' ||
              (inParameterExpansion && next == '}');
      final isGlobMetaOrBackslash = singleQuotesAreLiteral
          ? r'*?[]\'.contains(next)
          : r'*?[]\(){}.^+'.contains(next);
      if (isEscapable) {
        literal += next;
      } else if (isGlobMetaOrBackslash) {
        flushLiteral();
        parts.add(EscapedPart(next));
      } else {
        literal += '\\$next';
      }
      i += 2;
      continue;
    }

    if (char == "'" && !singleQuotesAreLiteral && !hereDoc) {
      flushLiteral();
      final closeQuote = value.indexOf("'", i + 1);
      if (closeQuote == -1) {
        literal += value.substring(i);
        break;
      }
      parts.add(SingleQuotedPart(value.substring(i + 1, closeQuote)));
      i = closeQuote + 1;
      continue;
    }

    if (char == '"' && !hereDoc) {
      flushLiteral();
      final r = _parseDoubleQuoted(p, value, i + 1);
      parts.add(r.part);
      i = r.endIndex + 1;
      continue;
    }

    if (char == r'$' && _charAt(value, i + 1) == "'") {
      flushLiteral();
      final r = parseAnsiCQuoted(p, value, i + 2);
      parts.add(r.part);
      i = r.endIndex;
      continue;
    }

    if (char == r'$') {
      flushLiteral();
      final r = _parseExpansion(p, value, i);
      if (r.part != null) parts.add(r.part!);
      i = r.endIndex;
      continue;
    }

    if (char == '`') {
      flushLiteral();
      final r = p.parseBacktickSubstitution(value, i);
      parts.add(r.part);
      i = r.endIndex;
      continue;
    }

    if (char == '~') {
      final prevChar = i > 0 ? value[i - 1] : '';
      final canExpandAfterColon = isAssignment && prevChar == ':';
      if (i == 0 || prevChar == '=' || canExpandAfterColon) {
        final tildeEnd = findTildeEnd(p, value, i);
        final afterTilde = _charAt(value, tildeEnd);
        if (afterTilde.isEmpty || afterTilde == '/' || afterTilde == ':') {
          flushLiteral();
          final userStr = value.substring(i + 1, tildeEnd);
          parts.add(TildeExpansionPart(userStr.isEmpty ? null : userStr));
          i = tildeEnd;
          continue;
        }
      }
    }

    if ('@*+?!'.contains(char) &&
        i + 1 < value.length &&
        value[i + 1] == '(') {
      final closeIdx = _findExtglobClose(value, i + 1);
      if (closeIdx != -1) {
        flushLiteral();
        parts.add(GlobPart(_slice(value, i, closeIdx + 1)));
        i = closeIdx + 1;
        continue;
      }
    }

    if (char == '*' || char == '?' || char == '[') {
      flushLiteral();
      final r = parseGlobPattern(p, value, i);
      parts.add(GlobPart(r.pattern));
      i = r.endIndex;
      continue;
    }

    if (char == '{' && !isAssignment && !noBraceExpansion && !hereDoc) {
      final braceResult = tryParseBraceExpansion(
        p,
        value,
        i,
        (pp, s) => parseWordParts(pp, s),
      );
      if (braceResult != null) {
        flushLiteral();
        parts.add(braceResult.part);
        i = braceResult.endIndex;
        continue;
      }
    }

    literal += char;
    i++;
  }

  flushLiteral();
  return parts;
}
