/// Arithmetic expression parser (`$((...))`, `(( ))`, `$[...]`).
///
/// Faithful port of `parser/arithmetic-parser.ts` + `arithmetic-primaries.ts`:
/// a precedence-climbing recursive-descent parser producing [ArithExpr] nodes.
/// Part of the `parser` library.
// ignore_for_file: lines_longer_than_80_chars, use_string_buffers
part of 'parser.dart';

const int _maxSafeInteger = 9007199254740991;

const List<String> _arithAssignOps = [
  '=',
  '+=',
  '-=',
  '*=',
  '/=',
  '%=',
  '<<=',
  '>>=',
  '&=',
  '|=',
  '^=',
];

final RegExp _arithWs = RegExp(r'\s');
final RegExp _arithDigit = RegExp('[0-9]');
final RegExp _arithHex = RegExp('[0-9a-fA-F]');
final RegExp _arithLetter = RegExp('[a-zA-Z_]');
final RegExp _arithAlnum = RegExp('[a-zA-Z0-9_]');
final RegExp _arithBase = RegExp('[0-9a-zA-Z@_]');
final RegExp _arithSpecial = RegExp(r'[*@#?\-!$]');
final RegExp _arithDigits = RegExp(r'^[0-9]+$');
final RegExp _arith89 = RegExp('[89]');

/// Skip whitespace (and `\`+newline line continuations) from [pos] in [input].
int _skipArithWs(String input, int pos) {
  var i = pos;
  while (i < input.length) {
    if (_charAt(input, i) == r'\' && _charAt(input, i + 1) == '\n') {
      i += 2;
      continue;
    }
    if (_arithWs.hasMatch(input[i])) {
      i++;
      continue;
    }
    break;
  }
  return i;
}

int _digitValue(String c) {
  if (c.isEmpty) return -1;
  final code = c.codeUnitAt(0);
  if (code >= 0x30 && code <= 0x39) return code - 0x30; // 0-9
  if (code >= 0x61 && code <= 0x7a) return code - 0x61 + 10; // a-z
  if (code >= 0x41 && code <= 0x5a) return code - 0x41 + 36; // A-Z
  if (c == '@') return 62;
  if (c == '_') return 63;
  return -1;
}

/// JS-`parseInt`-style prefix parse: consume valid digits for [radix], stop at
/// the first invalid one, clamp to [_maxSafeInteger], NaN if no digits.
num _jsParseInt(String s, int radix) {
  var i = 0;
  while (i < s.length && _arithWs.hasMatch(s[i])) {
    i++;
  }
  var sign = 1;
  if (i < s.length && (s[i] == '+' || s[i] == '-')) {
    if (s[i] == '-') sign = -1;
    i++;
  }
  final start = i;
  var result = 0;
  while (i < s.length) {
    final d = _digitValue(s[i]);
    if (d < 0 || d >= radix) break;
    result = result * radix + d;
    if (result > _maxSafeInteger) return _maxSafeInteger * sign;
    i++;
  }
  if (i == start) return double.nan;
  return sign * result;
}

/// Parse a number string in any bash base (decimal, `0x`, octal, `base#num`).
/// Returns NaN for an invalid number.
num parseArithNumber(String s) {
  if (s.contains('#')) {
    final hash = s.indexOf('#');
    final baseStr = s.substring(0, hash);
    final numStr = s.substring(hash + 1);
    final base = int.tryParse(baseStr) ?? -1;
    if (base < 2 || base > 64) return double.nan;
    return _jsParseInt(numStr, base);
  }
  if (s.startsWith('0x') || s.startsWith('0X')) {
    return _jsParseInt(s.substring(2), 16);
  }
  if (s.startsWith('0') && s.length > 1 && _arithDigits.hasMatch(s)) {
    if (_arith89.hasMatch(s)) return double.nan;
    return _jsParseInt(s, 8);
  }
  return _jsParseInt(s, 10);
}

String _preprocessArithInput(String input) {
  var result = '';
  var i = 0;
  while (i < input.length) {
    if (input[i] == '"') {
      i++;
      while (i < input.length && input[i] != '"') {
        if (input[i] == r'\' && i + 1 < input.length) {
          result += input[i + 1];
          i += 2;
        } else {
          result += input[i];
          i++;
        }
      }
      if (i < input.length) i++;
    } else {
      result += input[i];
      i++;
    }
  }
  return result;
}

/// Parse [input] into an [ArithmeticExpressionNode].
ArithmeticExpressionNode parseArithmeticExpressionImpl(Parser p, String input) {
  final preprocessed = _preprocessArithInput(input);
  final r = _parseArithExpr(p, preprocessed, 0);
  final finalPos = _skipArithWs(preprocessed, r.pos);
  if (finalPos < preprocessed.length) {
    final remaining = _slice(input, finalPos, input.length).trim();
    if (remaining.isNotEmpty) {
      return ArithmeticExpressionNode(
        ArithSyntaxErrorNode(
          remaining,
          '$remaining: syntax error: invalid arithmetic operator (error token is "$remaining")',
        ),
        originalText: input,
      );
    }
  }
  return ArithmeticExpressionNode(r.expr, originalText: input);
}

typedef _ArithResult = ({ArithExpr expr, int pos});

_ArithResult _missingOperand(String op, int pos) => (
      expr: ArithSyntaxErrorNode(
        op,
        'syntax error: operand expected (error token is "$op")',
      ),
      pos: pos,
    );

bool _isMissingOperand(String input, int pos) =>
    _skipArithWs(input, pos) >= input.length;

_ArithResult _parseArithExpr(Parser p, String input, int pos) =>
    _parseArithComma(p, input, pos);

_ArithResult _parseArithComma(Parser p, String input, int pos) {
  var left = _parseArithTernary(p, input, pos);
  var cur = _skipArithWs(input, left.pos);
  while (_charAt(input, cur) == ',') {
    cur++;
    if (_isMissingOperand(input, cur)) return _missingOperand(',', cur);
    final right = _parseArithTernary(p, input, cur);
    left = (
      expr: ArithBinaryNode(',', left.expr, right.expr),
      pos: right.pos,
    );
    cur = _skipArithWs(input, right.pos);
  }
  return (expr: left.expr, pos: cur);
}

_ArithResult _parseArithTernary(Parser p, String input, int pos) {
  final condition = _parseArithLogicalOr(p, input, pos);
  var cur = _skipArithWs(input, condition.pos);
  if (_charAt(input, cur) == '?') {
    cur++;
    final consequent = _parseArithExpr(p, input, cur);
    cur = _skipArithWs(input, consequent.pos);
    if (_charAt(input, cur) == ':') {
      cur++;
      final alternate = _parseArithExpr(p, input, cur);
      return (
        expr: ArithTernaryNode(condition.expr, consequent.expr, alternate.expr),
        pos: alternate.pos,
      );
    }
  }
  return (expr: condition.expr, pos: cur);
}

_ArithResult _binaryLevel(
  Parser p,
  String input,
  int pos,
  _ArithResult Function(Parser, String, int) next,
  bool Function(String input, int pos) matches,
  String Function(String input, int pos) opAt,
) {
  var left = next(p, input, pos);
  var cur = _skipArithWs(input, left.pos);
  while (matches(input, cur)) {
    final op = opAt(input, cur);
    cur += op.length;
    if (_isMissingOperand(input, cur)) return _missingOperand(op, cur);
    final right = next(p, input, cur);
    left = (expr: ArithBinaryNode(op, left.expr, right.expr), pos: right.pos);
    cur = _skipArithWs(input, right.pos);
  }
  return (expr: left.expr, pos: cur);
}

_ArithResult _parseArithLogicalOr(Parser p, String input, int pos) =>
    _binaryLevel(p, input, pos, _parseArithLogicalAnd,
        (i, c) => _slice(i, c, c + 2) == '||', (i, c) => '||');

_ArithResult _parseArithLogicalAnd(Parser p, String input, int pos) =>
    _binaryLevel(p, input, pos, _parseArithBitwiseOr,
        (i, c) => _slice(i, c, c + 2) == '&&', (i, c) => '&&');

_ArithResult _parseArithBitwiseOr(Parser p, String input, int pos) =>
    _binaryLevel(p, input, pos, _parseArithBitwiseXor,
        (i, c) => _charAt(i, c) == '|' && _charAt(i, c + 1) != '|',
        (i, c) => '|');

_ArithResult _parseArithBitwiseXor(Parser p, String input, int pos) =>
    _binaryLevel(p, input, pos, _parseArithBitwiseAnd,
        (i, c) => _charAt(i, c) == '^', (i, c) => '^');

_ArithResult _parseArithBitwiseAnd(Parser p, String input, int pos) =>
    _binaryLevel(p, input, pos, _parseArithEquality,
        (i, c) => _charAt(i, c) == '&' && _charAt(i, c + 1) != '&',
        (i, c) => '&');

_ArithResult _parseArithEquality(Parser p, String input, int pos) =>
    _binaryLevel(p, input, pos, _parseArithRelational, (i, c) {
      final two = _slice(i, c, c + 2);
      return two == '==' || two == '!=';
    }, (i, c) => _slice(i, c, c + 2));

_ArithResult _parseArithRelational(Parser p, String input, int pos) {
  var left = _parseArithShift(p, input, pos);
  var cur = _skipArithWs(input, left.pos);
  while (true) {
    final two = _slice(input, cur, cur + 2);
    if (two == '<=' || two == '>=') {
      cur += 2;
      if (_isMissingOperand(input, cur)) return _missingOperand(two, cur);
      final right = _parseArithShift(p, input, cur);
      left = (expr: ArithBinaryNode(two, left.expr, right.expr), pos: right.pos);
      cur = _skipArithWs(input, right.pos);
    } else if (_charAt(input, cur) == '<' || _charAt(input, cur) == '>') {
      final op = input[cur];
      cur++;
      if (_isMissingOperand(input, cur)) return _missingOperand(op, cur);
      final right = _parseArithShift(p, input, cur);
      left = (expr: ArithBinaryNode(op, left.expr, right.expr), pos: right.pos);
      cur = _skipArithWs(input, right.pos);
    } else {
      break;
    }
  }
  return (expr: left.expr, pos: cur);
}

_ArithResult _parseArithShift(Parser p, String input, int pos) =>
    _binaryLevel(p, input, pos, _parseArithAdditive, (i, c) {
      final two = _slice(i, c, c + 2);
      return two == '<<' || two == '>>';
    }, (i, c) => _slice(i, c, c + 2));

_ArithResult _parseArithAdditive(Parser p, String input, int pos) =>
    _binaryLevel(p, input, pos, _parseArithMultiplicative, (i, c) {
      final ch = _charAt(i, c);
      return (ch == '+' || ch == '-') && _charAt(i, c + 1) != ch;
    }, (i, c) => input[c]);

_ArithResult _parseArithMultiplicative(Parser p, String input, int pos) {
  var left = _parseArithPower(p, input, pos);
  var cur = _skipArithWs(input, left.pos);
  while (true) {
    final ch = _charAt(input, cur);
    if (ch == '*' && _charAt(input, cur + 1) != '*') {
      cur++;
      if (_isMissingOperand(input, cur)) return _missingOperand('*', cur);
      final right = _parseArithPower(p, input, cur);
      left = (expr: ArithBinaryNode('*', left.expr, right.expr), pos: right.pos);
      cur = _skipArithWs(input, right.pos);
    } else if (ch == '/' || ch == '%') {
      cur++;
      if (_isMissingOperand(input, cur)) return _missingOperand(ch, cur);
      final right = _parseArithPower(p, input, cur);
      left = (expr: ArithBinaryNode(ch, left.expr, right.expr), pos: right.pos);
      cur = _skipArithWs(input, right.pos);
    } else {
      break;
    }
  }
  return (expr: left.expr, pos: cur);
}

_ArithResult _parseArithPower(Parser p, String input, int pos) {
  final base = _parseArithUnary(p, input, pos);
  var p2 = _skipArithWs(input, base.pos);
  if (_slice(input, p2, p2 + 2) == '**') {
    p2 += 2;
    if (_isMissingOperand(input, p2)) return _missingOperand('**', p2);
    final exponent = _parseArithPower(p, input, p2); // right-associative
    return (
      expr: ArithBinaryNode('**', base.expr, exponent.expr),
      pos: exponent.pos,
    );
  }
  return (expr: base.expr, pos: base.pos);
}

_ArithResult _parseArithUnary(Parser p, String input, int pos) {
  var cur = _skipArithWs(input, pos);
  final two = _slice(input, cur, cur + 2);
  if (two == '++' || two == '--') {
    cur += 2;
    final operand = _parseArithUnary(p, input, cur);
    return (
      expr: ArithUnaryNode(two, operand.expr, prefix: true),
      pos: operand.pos,
    );
  }
  final ch = _charAt(input, cur);
  if (ch == '+' || ch == '-' || ch == '!' || ch == '~') {
    cur++;
    final operand = _parseArithUnary(p, input, cur);
    return (
      expr: ArithUnaryNode(ch, operand.expr, prefix: true),
      pos: operand.pos,
    );
  }
  return _parseArithPostfix(p, input, cur);
}

bool _canStartConcatPrimary(String input, int pos) {
  final c = _charAt(input, pos);
  return c == r'$' || c == '`';
}

_ArithResult _parseArithPostfix(Parser p, String input, int pos) {
  final first = _parseArithPrimary(p, input, pos, skipAssignment: false);
  var expr = first.expr;
  var cur = first.pos;

  final parts = <ArithExpr>[expr];
  while (_canStartConcatPrimary(input, cur)) {
    final next = _parseArithPrimary(p, input, cur, skipAssignment: true);
    parts.add(next.expr);
    cur = next.pos;
  }
  if (parts.length > 1) expr = ArithConcatNode(parts);

  ArithExpr? subscript;
  if (_charAt(input, cur) == '[' && expr is ArithConcatNode) {
    cur++;
    final index = _parseArithExpr(p, input, cur);
    subscript = index.expr;
    cur = index.pos;
    if (_charAt(input, cur) == ']') cur++;
  }

  if (subscript != null && expr is ArithConcatNode) {
    expr = ArithDynamicElementNode(expr, subscript);
    subscript = null;
  }

  cur = _skipArithWs(input, cur);

  if (expr is ArithConcatNode ||
      expr is ArithVariableNode ||
      expr is ArithDynamicElementNode) {
    for (final op in _arithAssignOps) {
      if (_slice(input, cur, cur + op.length) == op &&
          _slice(input, cur, cur + op.length + 1) != '==') {
        cur += op.length;
        final value = _parseArithTernary(p, input, cur);
        if (expr is ArithDynamicElementNode) {
          return (
            expr: ArithDynamicAssignmentNode(
              op,
              expr.nameExpr,
              value.expr,
              subscript: expr.subscript,
            ),
            pos: value.pos,
          );
        }
        if (expr is ArithConcatNode) {
          return (
            expr: ArithDynamicAssignmentNode(op, expr, value.expr),
            pos: value.pos,
          );
        }
        return (
          expr: ArithAssignmentNode(
            op,
            (expr as ArithVariableNode).name,
            value.expr,
          ),
          pos: value.pos,
        );
      }
    }
  }

  final post = _slice(input, cur, cur + 2);
  if (post == '++' || post == '--') {
    cur += 2;
    return (
      expr: ArithUnaryNode(post, expr, prefix: false),
      pos: cur,
    );
  }

  return (expr: expr, pos: cur);
}

_ArithResult? _parseNestedArithmetic(Parser p, String input, int cur) {
  if (_slice(input, cur, cur + 3) != r'$((') return null;
  var pos = cur + 3;
  var depth = 1;
  final exprStart = pos;
  while (pos < input.length - 1 && depth > 0) {
    if (input[pos] == '(' && input[pos + 1] == '(') {
      depth++;
      pos += 2;
    } else if (input[pos] == ')' && input[pos + 1] == ')') {
      depth--;
      if (depth > 0) pos += 2;
    } else {
      pos++;
    }
  }
  final nested = _slice(input, exprStart, pos);
  final inner = _parseArithExpr(p, nested, 0);
  pos += 2;
  return (expr: ArithNestedNode(inner.expr), pos: pos);
}

_ArithResult? _parseArithAnsiC(String input, int cur) {
  if (_slice(input, cur, cur + 2) != r"$'") return null;
  var pos = cur + 2;
  var content = '';
  while (pos < input.length && input[pos] != "'") {
    if (input[pos] == r'\' && pos + 1 < input.length) {
      final next = input[pos + 1];
      content += switch (next) {
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        r'\' => r'\',
        "'" => "'",
        _ => next,
      };
      pos += 2;
    } else {
      content += input[pos];
      pos++;
    }
  }
  if (_charAt(input, pos) == "'") pos++;
  final v = _jsParseInt(content, 10);
  return (expr: ArithNumberNode(v.isNaN ? 0 : v), pos: pos);
}

_ArithResult? _parseArithLocalization(String input, int cur) {
  if (_slice(input, cur, cur + 2) != r'$"') return null;
  var pos = cur + 2;
  var content = '';
  while (pos < input.length && input[pos] != '"') {
    if (input[pos] == r'\' && pos + 1 < input.length) {
      content += input[pos + 1];
      pos += 2;
    } else {
      content += input[pos];
      pos++;
    }
  }
  if (_charAt(input, pos) == '"') pos++;
  final v = _jsParseInt(content, 10);
  return (expr: ArithNumberNode(v.isNaN ? 0 : v), pos: pos);
}

_ArithResult _parseArithPrimary(
  Parser p,
  String input,
  int pos, {
  required bool skipAssignment,
}) {
  var cur = _skipArithWs(input, pos);

  final nested = _parseNestedArithmetic(p, input, cur);
  if (nested != null) return nested;
  final ansi = _parseArithAnsiC(input, cur);
  if (ansi != null) return ansi;
  final loc = _parseArithLocalization(input, cur);
  if (loc != null) return loc;

  // Command substitution: $(cmd)
  if (_slice(input, cur, cur + 2) == r'$(' && _charAt(input, cur + 2) != '(') {
    cur += 2;
    var depth = 1;
    final cmdStart = cur;
    while (cur < input.length && depth > 0) {
      if (input[cur] == '(') {
        depth++;
      } else if (input[cur] == ')') {
        depth--;
      }
      if (depth > 0) cur++;
    }
    final cmd = _slice(input, cmdStart, cur);
    cur++;
    return (expr: ArithCommandSubstNode(cmd), pos: cur);
  }

  // Backtick command substitution
  if (_charAt(input, cur) == '`') {
    cur++;
    final cmdStart = cur;
    while (cur < input.length && input[cur] != '`') {
      cur++;
    }
    final cmd = _slice(input, cmdStart, cur);
    if (_charAt(input, cur) == '`') cur++;
    return (expr: ArithCommandSubstNode(cmd), pos: cur);
  }

  // Grouped expression
  if (_charAt(input, cur) == '(') {
    cur++;
    final inner = _parseArithExpr(p, input, cur);
    cur = _skipArithWs(input, inner.pos);
    if (_charAt(input, cur) == ')') cur++;
    return (expr: ArithGroupNode(inner.expr), pos: cur);
  }

  // Single-quoted string
  if (_charAt(input, cur) == "'") {
    cur++;
    var content = '';
    while (cur < input.length && input[cur] != "'") {
      content += input[cur];
      cur++;
    }
    if (_charAt(input, cur) == "'") cur++;
    final v = _jsParseInt(content, 10);
    return (
      expr: ArithSingleQuoteNode(content, v.isNaN ? 0 : v),
      pos: cur,
    );
  }

  // Double-quoted string: content text-inserted and parsed inline
  if (_charAt(input, cur) == '"') {
    cur++;
    var content = '';
    while (cur < input.length && input[cur] != '"') {
      if (input[cur] == r'\' && cur + 1 < input.length) {
        content += input[cur + 1];
        cur += 2;
      } else {
        content += input[cur];
        cur++;
      }
    }
    if (_charAt(input, cur) == '"') cur++;
    final trimmed = content.trim();
    if (trimmed.isEmpty) return (expr: ArithNumberNode(0), pos: cur);
    final inner = _parseArithExpr(p, trimmed, 0);
    return (expr: inner.expr, pos: cur);
  }

  // Number
  if (_arithDigit.hasMatch(_charAt(input, cur))) {
    var numStr = '';
    var seenHash = false;
    var isHex = false;
    while (cur < input.length) {
      final ch = input[cur];
      if (seenHash) {
        if (_arithBase.hasMatch(ch)) {
          numStr += ch;
          cur++;
        } else {
          break;
        }
      } else if (ch == '#') {
        seenHash = true;
        numStr += ch;
        cur++;
      } else if (numStr == '0' &&
          (ch == 'x' || ch == 'X') &&
          cur + 1 < input.length &&
          _arithHex.hasMatch(input[cur + 1])) {
        isHex = true;
        numStr += ch;
        cur++;
      } else if (isHex && _arithHex.hasMatch(ch)) {
        numStr += ch;
        cur++;
      } else if (!isHex && _arithDigit.hasMatch(ch)) {
        numStr += ch;
        cur++;
      } else {
        break;
      }
    }
    if (cur < input.length && _arithLetter.hasMatch(input[cur])) {
      var invalidToken = numStr;
      while (cur < input.length && _arithAlnum.hasMatch(input[cur])) {
        invalidToken += input[cur];
        cur++;
      }
      return (
        expr: ArithSyntaxErrorNode(
          invalidToken,
          '$invalidToken: value too great for base (error token is "$invalidToken")',
        ),
        pos: cur,
      );
    }
    if (_charAt(input, cur) == '.' && _arithDigit.hasMatch(_charAt(input, cur + 1))) {
      throw ArithmeticError(
        '$numStr.${input[cur + 1]}...: syntax error: invalid arithmetic operator',
      );
    }
    if (_charAt(input, cur) == '[') {
      final errorToken = _slice(input, cur, input.length).trim();
      return (
        expr: ArithNumberSubscriptNode(numStr, errorToken),
        pos: input.length,
      );
    }
    return (expr: ArithNumberNode(parseArithNumber(numStr)), pos: cur);
  }

  // ${...} braced parameter expansion (+ dynamic base/number forms)
  if (_charAt(input, cur) == r'$' && _charAt(input, cur + 1) == '{') {
    final braceStart = cur + 2;
    var braceDepth = 1;
    var i = braceStart;
    while (i < input.length && braceDepth > 0) {
      if (input[i] == '{') {
        braceDepth++;
      } else if (input[i] == '}') {
        braceDepth--;
      }
      if (braceDepth > 0) i++;
    }
    final content = _slice(input, braceStart, i);
    final afterBrace = i + 1;

    if (_charAt(input, afterBrace) == '#') {
      var valueEnd = afterBrace + 1;
      while (valueEnd < input.length && _arithBase.hasMatch(input[valueEnd])) {
        valueEnd++;
      }
      final valueStr = _slice(input, afterBrace + 1, valueEnd);
      return (
        expr: ArithDynamicBaseNode(content, valueStr),
        pos: valueEnd,
      );
    }
    final ab = _charAt(input, afterBrace);
    if (_arithDigit.hasMatch(ab) || ab == 'x' || ab == 'X') {
      var numEnd = afterBrace;
      if (ab == 'x' || ab == 'X') {
        numEnd++;
        while (numEnd < input.length && _arithHex.hasMatch(input[numEnd])) {
          numEnd++;
        }
      } else {
        while (numEnd < input.length && _arithDigit.hasMatch(input[numEnd])) {
          numEnd++;
        }
      }
      final suffix = _slice(input, afterBrace, numEnd);
      return (expr: ArithDynamicNumberNode(content, suffix), pos: numEnd);
    }

    return (expr: ArithBracedExpansionNode(content), pos: afterBrace);
  }

  // $1, $2 positional parameters
  if (_charAt(input, cur) == r'$' &&
      cur + 1 < input.length &&
      _arithDigit.hasMatch(input[cur + 1])) {
    cur++;
    var name = '';
    while (cur < input.length && _arithDigit.hasMatch(input[cur])) {
      name += input[cur];
      cur++;
    }
    return (expr: ArithVariableNode(name, hasDollarPrefix: true), pos: cur);
  }

  // Special variables $*, $@, $#, $?, $-, $!, $$
  if (_charAt(input, cur) == r'$' &&
      cur + 1 < input.length &&
      _arithSpecial.hasMatch(input[cur + 1])) {
    final name = input[cur + 1];
    cur += 2;
    return (expr: ArithSpecialVarNode(name), pos: cur);
  }

  // $name regular variable with $ prefix
  var hasDollarPrefix = false;
  if (_charAt(input, cur) == r'$' &&
      cur + 1 < input.length &&
      _arithLetter.hasMatch(input[cur + 1])) {
    hasDollarPrefix = true;
    cur++;
  }
  if (cur < input.length && _arithLetter.hasMatch(input[cur])) {
    var name = '';
    while (cur < input.length && _arithAlnum.hasMatch(input[cur])) {
      name += input[cur];
      cur++;
    }

    if (_charAt(input, cur) == '[' && !skipAssignment) {
      cur++;
      String? stringKey;
      if (_charAt(input, cur) == "'" || _charAt(input, cur) == '"') {
        final quote = input[cur];
        cur++;
        final sb = StringBuffer();
        while (cur < input.length && input[cur] != quote) {
          sb.write(input[cur]);
          cur++;
        }
        stringKey = sb.toString();
        if (_charAt(input, cur) == quote) cur++;
        cur = _skipArithWs(input, cur);
        if (_charAt(input, cur) == ']') cur++;
      }

      ArithExpr? indexExpr;
      if (stringKey == null) {
        final idx = _parseArithExpr(p, input, cur);
        indexExpr = idx.expr;
        cur = idx.pos;
        if (_charAt(input, cur) == ']') cur++;
      }

      cur = _skipArithWs(input, cur);
      if (_charAt(input, cur) == '[' && indexExpr != null) {
        return (
          expr: ArithDoubleSubscriptNode(name, indexExpr),
          pos: cur,
        );
      }

      if (!skipAssignment) {
        for (final op in _arithAssignOps) {
          if (_slice(input, cur, cur + op.length) == op &&
              _slice(input, cur, cur + op.length + 1) != '==') {
            cur += op.length;
            final value = _parseArithTernary(p, input, cur);
            return (
              expr: ArithAssignmentNode(
                op,
                name,
                value.expr,
                subscript: indexExpr,
                stringKey: stringKey,
              ),
              pos: value.pos,
            );
          }
        }
      }

      return (
        expr: ArithArrayElementNode(name, index: indexExpr, stringKey: stringKey),
        pos: cur,
      );
    }

    cur = _skipArithWs(input, cur);

    if (!skipAssignment) {
      for (final op in _arithAssignOps) {
        if (_slice(input, cur, cur + op.length) == op &&
            _slice(input, cur, cur + op.length + 1) != '==') {
          cur += op.length;
          final value = _parseArithTernary(p, input, cur);
          return (
            expr: ArithAssignmentNode(op, name, value.expr),
            pos: value.pos,
          );
        }
      }
    }

    return (
      expr: ArithVariableNode(name, hasDollarPrefix: hasDollarPrefix),
      pos: cur,
    );
  }

  // Bare # is a syntax error in bash arithmetic
  if (_charAt(input, cur) == '#') {
    var errorEnd = cur + 1;
    while (errorEnd < input.length && input[errorEnd] != '\n') {
      errorEnd++;
    }
    final errorToken = _slice(input, cur, errorEnd).trim();
    final token = errorToken.isEmpty ? '#' : errorToken;
    return (
      expr: ArithSyntaxErrorNode(
        token,
        '$token: syntax error: invalid arithmetic operator (error token is "$token")',
      ),
      pos: input.length,
    );
  }

  return (expr: ArithNumberNode(0), pos: cur);
}
