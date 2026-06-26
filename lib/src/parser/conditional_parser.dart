/// Conditional expression parser (for `[[ ]]`).
///
/// Faithful port of `parser/conditional-parser.ts`. Part of the `parser`
/// library.
// ignore_for_file: lines_longer_than_80_chars, use_string_buffers
// ignore_for_file: cascade_invocations
part of 'parser.dart';

const List<String> _condUnaryOps = [
  '-a', '-b', '-c', '-d', '-e', '-f', '-g', '-h', '-k', '-p', '-r', '-s',
  '-t', '-u', '-w', '-x', '-G', '-L', '-N', '-O', '-S', '-z', '-n', '-o',
  '-v', '-R', //
];

const List<String> _condBinaryOps = [
  '==', '!=', '=~', '<', '>', '-eq', '-ne', '-lt', '-le', '-gt', '-ge',
  '-nt', '-ot', '-ef', //
];

bool _isCondOperand(Parser p) {
  return p.isWord() ||
      p.check([TokenType.lbrace]) ||
      p.check([TokenType.rbrace]) ||
      p.check([TokenType.assignmentWord]);
}

WordNode _parsePatternWord(Parser p) {
  // `!(...)` extglob pattern: BANG followed by LPAREN.
  if (p.check([TokenType.bang]) && p.peek(1).type == TokenType.lparen) {
    p.advance();
    p.advance();
    var depth = 1;
    var pattern = '!(';
    while (depth > 0 && !p.check([TokenType.eof])) {
      if (p.check([TokenType.lparen])) {
        depth++;
        pattern += '(';
        p.advance();
      } else if (p.check([TokenType.rparen])) {
        depth--;
        if (depth > 0) pattern += ')';
        p.advance();
      } else if (p.isWord()) {
        pattern += p.advance().value;
      } else if (p.check([TokenType.pipe])) {
        pattern += '|';
        p.advance();
      } else {
        break;
      }
    }
    pattern += ')';
    return p.parseWordFromString(pattern, noBraceExpansion: true);
  }
  return p.parseWordNoBraceExpansion();
}

/// Parse a conditional expression for `[[ ... ]]`.
ConditionalExpressionNode parseConditionalExpression(Parser p) {
  p.skipNewlines();
  return _parseCondOr(p);
}

ConditionalExpressionNode _parseCondOr(Parser p) {
  var left = _parseCondAnd(p);
  p.skipNewlines();
  while (p.check([TokenType.orOr])) {
    p.advance();
    p.skipNewlines();
    final right = _parseCondAnd(p);
    left = CondOrNode(left, right);
    p.skipNewlines();
  }
  return left;
}

ConditionalExpressionNode _parseCondAnd(Parser p) {
  var left = _parseCondNot(p);
  p.skipNewlines();
  while (p.check([TokenType.andAnd])) {
    p.advance();
    p.skipNewlines();
    final right = _parseCondNot(p);
    left = CondAndNode(left, right);
    p.skipNewlines();
  }
  return left;
}

ConditionalExpressionNode _parseCondNot(Parser p) {
  p.skipNewlines();
  if (p.check([TokenType.bang])) {
    p.advance();
    p.skipNewlines();
    final operand = _parseCondNot(p);
    return CondNotNode(operand);
  }
  return _parseCondPrimary(p);
}

ConditionalExpressionNode _parseCondPrimary(Parser p) {
  if (p.check([TokenType.lparen])) {
    p.advance();
    final expression = parseConditionalExpression(p);
    p.expect(TokenType.rparen);
    return CondGroupNode(expression);
  }

  if (_isCondOperand(p)) {
    final firstToken = p.current();
    final first = firstToken.value;

    if (_condUnaryOps.contains(first) && !firstToken.quoted) {
      p.advance();
      if (p.check([TokenType.dbrackEnd])) {
        p.error('Expected operand after $first');
      }
      if (_isCondOperand(p)) {
        final operand = p.parseWordNoBraceExpansion();
        return CondUnaryNode(first, operand);
      }
      final badToken = p.current();
      p.error(
        "unexpected argument `${badToken.value}' to conditional unary operator",
      );
    }

    final left = p.parseWordNoBraceExpansion();

    if (p.isWord() && _condBinaryOps.contains(p.current().value)) {
      final operator = p.advance().value;
      WordNode right;
      if (operator == '=~') {
        right = _parseRegexPattern(p);
      } else if (operator == '==' || operator == '!=') {
        right = _parsePatternWord(p);
      } else {
        right = p.parseWordNoBraceExpansion();
      }
      return CondBinaryNode(operator, left, right);
    }

    if (p.check([TokenType.less])) {
      p.advance();
      final right = p.parseWordNoBraceExpansion();
      return CondBinaryNode('<', left, right);
    }
    if (p.check([TokenType.great])) {
      p.advance();
      final right = p.parseWordNoBraceExpansion();
      return CondBinaryNode('>', left, right);
    }

    if (p.isWord() && p.current().value == '=') {
      p.advance();
      final right = _parsePatternWord(p);
      return CondBinaryNode('==', left, right);
    }

    return CondWordNode(left);
  }

  p.error('Expected conditional expression');
}

WordNode _parseRegexPattern(Parser p) {
  final parts = <WordPart>[];
  var parenDepth = 0;
  var lastTokenEnd = -1;
  final input = p.getInput();

  bool isTerminator() =>
      p.check([TokenType.dbrackEnd]) ||
      p.check([TokenType.andAnd]) ||
      p.check([TokenType.orOr]) ||
      p.check([TokenType.newline]) ||
      p.check([TokenType.eof]);

  while (!isTerminator()) {
    final currentToken = p.current();
    final hasGap = lastTokenEnd >= 0 && currentToken.start > lastTokenEnd;

    if (parenDepth == 0 && hasGap) break;

    if (parenDepth > 0 && hasGap) {
      parts.add(LiteralPart(_slice(input, lastTokenEnd, currentToken.start)));
    }

    if (p.isWord() || p.check([TokenType.assignmentWord])) {
      final word = p.parseWordForRegex();
      parts.addAll(word.parts);
      lastTokenEnd = p.peek(-1).end;
    } else if (p.check([TokenType.lparen])) {
      final token = p.advance();
      parts.add(LiteralPart('('));
      parenDepth++;
      lastTokenEnd = token.end;
    } else if (p.check([TokenType.dparenStart])) {
      final token = p.advance();
      parts.add(LiteralPart('(('));
      parenDepth += 2;
      lastTokenEnd = token.end;
    } else if (p.check([TokenType.dparenEnd])) {
      if (parenDepth >= 2) {
        final token = p.advance();
        parts.add(LiteralPart('))'));
        parenDepth -= 2;
        lastTokenEnd = token.end;
      } else {
        break;
      }
    } else if (p.check([TokenType.rparen])) {
      if (parenDepth > 0) {
        final token = p.advance();
        parts.add(LiteralPart(')'));
        parenDepth--;
        lastTokenEnd = token.end;
      } else {
        break;
      }
    } else if (p.check([TokenType.pipe])) {
      final token = p.advance();
      parts.add(LiteralPart('|'));
      lastTokenEnd = token.end;
    } else if (p.check([TokenType.semicolon])) {
      if (parenDepth > 0) {
        final token = p.advance();
        parts.add(LiteralPart(';'));
        lastTokenEnd = token.end;
      } else {
        break;
      }
    } else if (parenDepth > 0 && p.check([TokenType.less])) {
      final token = p.advance();
      parts.add(LiteralPart('<'));
      lastTokenEnd = token.end;
    } else if (parenDepth > 0 && p.check([TokenType.great])) {
      final token = p.advance();
      parts.add(LiteralPart('>'));
      lastTokenEnd = token.end;
    } else if (parenDepth > 0 && p.check([TokenType.dgreat])) {
      final token = p.advance();
      parts.add(LiteralPart('>>'));
      lastTokenEnd = token.end;
    } else if (parenDepth > 0 && p.check([TokenType.dless])) {
      final token = p.advance();
      parts.add(LiteralPart('<<'));
      lastTokenEnd = token.end;
    } else if (parenDepth > 0 && p.check([TokenType.lessand])) {
      final token = p.advance();
      parts.add(LiteralPart('<&'));
      lastTokenEnd = token.end;
    } else if (parenDepth > 0 && p.check([TokenType.greatand])) {
      final token = p.advance();
      parts.add(LiteralPart('>&'));
      lastTokenEnd = token.end;
    } else if (parenDepth > 0 && p.check([TokenType.lessgreat])) {
      final token = p.advance();
      parts.add(LiteralPart('<>'));
      lastTokenEnd = token.end;
    } else if (parenDepth > 0 && p.check([TokenType.clobber])) {
      final token = p.advance();
      parts.add(LiteralPart('>|'));
      lastTokenEnd = token.end;
    } else if (parenDepth > 0 && p.check([TokenType.tless])) {
      final token = p.advance();
      parts.add(LiteralPart('<<<'));
      lastTokenEnd = token.end;
    } else if (parenDepth > 0 && p.check([TokenType.amp])) {
      final token = p.advance();
      parts.add(LiteralPart('&'));
      lastTokenEnd = token.end;
    } else if (parenDepth > 0 && p.check([TokenType.lbrace])) {
      final token = p.advance();
      parts.add(LiteralPart('{'));
      lastTokenEnd = token.end;
    } else if (parenDepth > 0 && p.check([TokenType.rbrace])) {
      final token = p.advance();
      parts.add(LiteralPart('}'));
      lastTokenEnd = token.end;
    } else {
      break;
    }
  }

  if (parts.isEmpty) {
    p.error('Expected regex pattern after =~');
  }

  return WordNode(parts);
}
