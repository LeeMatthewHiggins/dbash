/// Compound command parser: if, for, while, until, case, subshell, group.
///
/// Faithful port of `parser/compound-parser.ts`. Part of the `parser` library.
// ignore_for_file: lines_longer_than_80_chars, cascade_invocations
part of 'parser.dart';

/// Parse an `if` statement.
IfNode parseIf(Parser p, {bool skipRedirections = false}) {
  p.expect(TokenType.ifKw);
  final clauses = <IfClause>[];

  final condition = p.parseCompoundList();
  p.expect(TokenType.then);
  final body = p.parseCompoundList();
  if (body.isEmpty) {
    final nextTok = p.check([TokenType.fi])
        ? 'fi'
        : p.check([TokenType.elseKw])
            ? 'else'
            : p.check([TokenType.elif])
                ? 'elif'
                : 'fi';
    p.error("syntax error near unexpected token `$nextTok'");
  }
  clauses.add(IfClause(condition, body));

  while (p.check([TokenType.elif])) {
    p.advance();
    final elifCondition = p.parseCompoundList();
    p.expect(TokenType.then);
    final elifBody = p.parseCompoundList();
    if (elifBody.isEmpty) {
      final nextTok = p.check([TokenType.fi])
          ? 'fi'
          : p.check([TokenType.elseKw])
              ? 'else'
              : p.check([TokenType.elif])
                  ? 'elif'
                  : 'fi';
      p.error("syntax error near unexpected token `$nextTok'");
    }
    clauses.add(IfClause(elifCondition, elifBody));
  }

  List<StatementNode>? elseBody;
  if (p.check([TokenType.elseKw])) {
    p.advance();
    elseBody = p.parseCompoundList();
    if (elseBody.isEmpty) {
      p.error("syntax error near unexpected token `fi'");
    }
  }

  p.expect(TokenType.fi);

  final redirections =
      skipRedirections ? <RedirectionNode>[] : p.parseOptionalRedirections();
  return IfNode(clauses, elseBody: elseBody, redirections: redirections);
}

/// Parse a `for` loop (regular or C-style).
CompoundCommandNode parseFor(Parser p, {bool skipRedirections = false}) {
  final forToken = p.expect(TokenType.forKw);

  if (p.check([TokenType.dparenStart])) {
    return _parseCStyleFor(p, forToken.line, skipRedirections: skipRedirections);
  }

  if (!p.isWord()) p.error('Expected variable name in for loop');
  final varToken = p.advance();
  final variable = varToken.value;

  List<WordNode>? words;

  p.skipNewlines();
  if (p.check([TokenType.inKw])) {
    p.advance();
    words = [];
    while (!p.check([
      TokenType.semicolon,
      TokenType.newline,
      TokenType.doKw,
      TokenType.eof,
    ])) {
      if (p.isWord()) {
        words.add(p.parseWord());
      } else {
        break;
      }
    }
  }

  if (p.check([TokenType.semicolon])) p.advance();
  p.skipNewlines();

  p.expect(TokenType.doKw);
  final body = p.parseCompoundList();
  p.expect(TokenType.done);

  final redirections =
      skipRedirections ? <RedirectionNode>[] : p.parseOptionalRedirections();
  return ForNode(variable, words, body, redirections: redirections);
}

CStyleForNode _parseCStyleFor(
  Parser p,
  int? startLine, {
  bool skipRedirections = false,
}) {
  p.expect(TokenType.dparenStart);

  ArithmeticExpressionNode? init;
  ArithmeticExpressionNode? condition;
  ArithmeticExpressionNode? update;

  final parts = ['', '', ''];
  var partIdx = 0;
  var depth = 0;

  while (!p.check([TokenType.dparenEnd, TokenType.eof])) {
    final token = p.advance();
    if (token.type == TokenType.semicolon && depth == 0) {
      partIdx++;
      if (partIdx > 2) break;
    } else {
      if (token.value == '(') depth++;
      if (token.value == ')') depth--;
      parts[partIdx] += token.value;
    }
  }

  p.expect(TokenType.dparenEnd);

  if (parts[0].trim().isNotEmpty) {
    init = p.parseArithmeticExpression(parts[0].trim());
  }
  if (parts[1].trim().isNotEmpty) {
    condition = p.parseArithmeticExpression(parts[1].trim());
  }
  if (parts[2].trim().isNotEmpty) {
    update = p.parseArithmeticExpression(parts[2].trim());
  }

  p.skipNewlines();
  if (p.check([TokenType.semicolon])) p.advance();
  p.skipNewlines();

  List<StatementNode> body;
  if (p.check([TokenType.lbrace])) {
    p.advance();
    body = p.parseCompoundList();
    p.expect(TokenType.rbrace);
  } else {
    p.expect(TokenType.doKw);
    body = p.parseCompoundList();
    p.expect(TokenType.done);
  }

  final redirections =
      skipRedirections ? <RedirectionNode>[] : p.parseOptionalRedirections();

  return CStyleForNode(
    init: init,
    condition: condition,
    update: update,
    body: body,
    redirections: redirections,
  )..line = startLine;
}

/// Parse a `while` loop.
WhileNode parseWhile(Parser p, {bool skipRedirections = false}) {
  p.expect(TokenType.whileKw);
  final condition = p.parseCompoundList();
  p.expect(TokenType.doKw);
  final body = p.parseCompoundList();
  if (body.isEmpty) {
    p.error("syntax error near unexpected token `done'");
  }
  p.expect(TokenType.done);

  final redirections =
      skipRedirections ? <RedirectionNode>[] : p.parseOptionalRedirections();
  return WhileNode(condition, body, redirections: redirections);
}

/// Parse an `until` loop.
UntilNode parseUntil(Parser p, {bool skipRedirections = false}) {
  p.expect(TokenType.until);
  final condition = p.parseCompoundList();
  p.expect(TokenType.doKw);
  final body = p.parseCompoundList();
  if (body.isEmpty) {
    p.error("syntax error near unexpected token `done'");
  }
  p.expect(TokenType.done);

  final redirections =
      skipRedirections ? <RedirectionNode>[] : p.parseOptionalRedirections();
  return UntilNode(condition, body, redirections: redirections);
}

/// Parse a `case` statement.
CaseNode parseCase(Parser p, {bool skipRedirections = false}) {
  p.expect(TokenType.caseKw);

  if (!p.isWord()) p.error("Expected word after 'case'");
  final word = p.parseWord();

  p.skipNewlines();
  p.expect(TokenType.inKw);
  p.skipNewlines();

  final items = <CaseItemNode>[];

  while (!p.check([TokenType.esac, TokenType.eof])) {
    p.checkIterationLimit();
    final posBefore = p.getPos();
    final item = _parseCaseItem(p);
    if (item != null) items.add(item);
    p.skipNewlines();
    if (p.getPos() == posBefore && item == null) break;
  }

  p.expect(TokenType.esac);

  final redirections =
      skipRedirections ? <RedirectionNode>[] : p.parseOptionalRedirections();
  return CaseNode(word, items, redirections: redirections);
}

CaseItemNode? _parseCaseItem(Parser p) {
  if (p.check([TokenType.lparen])) p.advance();

  final patterns = <WordNode>[];
  while (p.isWord()) {
    patterns.add(p.parseWord());
    if (p.check([TokenType.pipe])) {
      p.advance();
    } else {
      break;
    }
  }

  if (patterns.isEmpty) return null;

  p.expect(TokenType.rparen);
  p.skipNewlines();

  final body = <StatementNode>[];
  while (!p.check([
    TokenType.dsemi,
    TokenType.semiAnd,
    TokenType.semiSemiAnd,
    TokenType.esac,
    TokenType.eof,
  ])) {
    p.checkIterationLimit();

    if (p.isWord() && p.peek(1).type == TokenType.rparen) {
      p.error("syntax error near unexpected token `)'");
    }
    if (p.check([TokenType.lparen]) && p.peek(1).type == TokenType.word) {
      p.error("syntax error near unexpected token `${p.peek(1).value}'");
    }

    final posBefore = p.getPos();
    final stmt = p.parseStatement();
    if (stmt != null) body.add(stmt);
    p.skipSeparators(false);
    if (p.getPos() == posBefore && stmt == null) break;
  }

  var terminator = ';;';
  if (p.check([TokenType.dsemi])) {
    p.advance();
    terminator = ';;';
  } else if (p.check([TokenType.semiAnd])) {
    p.advance();
    terminator = ';&';
  } else if (p.check([TokenType.semiSemiAnd])) {
    p.advance();
    terminator = ';;&';
  }

  return CaseItemNode(patterns, body, terminator: terminator);
}

/// Parse a subshell `( ... )`.
SubshellNode parseSubshell(Parser p, {bool skipRedirections = false}) {
  p.expect(TokenType.lparen);
  final body = p.parseCompoundList();
  p.expect(TokenType.rparen);

  final redirections =
      skipRedirections ? <RedirectionNode>[] : p.parseOptionalRedirections();
  return SubshellNode(body, redirections: redirections);
}

/// Parse a command group `{ ...; }`.
GroupNode parseGroup(Parser p, {bool skipRedirections = false}) {
  p.expect(TokenType.lbrace);
  final body = p.parseCompoundList();
  p.expect(TokenType.rbrace);

  final redirections =
      skipRedirections ? <RedirectionNode>[] : p.parseOptionalRedirections();
  return GroupNode(body, redirections: redirections);
}
