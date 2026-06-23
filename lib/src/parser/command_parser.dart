/// Command parser: simple commands, redirections, and assignments.
///
/// Faithful port of `parser/command-parser.ts`. Part of the `parser` library.
// ignore_for_file: lines_longer_than_80_chars, cascade_invocations
part of 'parser.dart';

/// Whether the current token begins a redirection.
bool isRedirection(Parser p) {
  final currentToken = p.current();
  final t = currentToken.type;

  if (t == TokenType.number) {
    final nextToken = p.peek(1);
    if (currentToken.end != nextToken.start) return false;
    return redirectionAfterNumber.contains(nextToken.type);
  }

  if (t == TokenType.fdVariable) {
    final nextToken = p.peek(1);
    return redirectionAfterFdVariable.contains(nextToken.type);
  }

  return redirectionTokens.contains(t);
}

/// Parse a single redirection.
RedirectionNode parseRedirection(Parser p) {
  int? fd;
  String? fdVariable;

  if (p.check([TokenType.number])) {
    fd = int.parse(p.advance().value);
  } else if (p.check([TokenType.fdVariable])) {
    fdVariable = p.advance().value;
  }

  final opToken = p.advance();
  final operator = tokenToRedirectOp(p, opToken.type);

  if (opToken.type == TokenType.dless || opToken.type == TokenType.dlessdash) {
    return _parseHeredocStart(
      p,
      operator,
      fd,
      stripTabs: opToken.type == TokenType.dlessdash,
    );
  }

  if (!p.isWord()) p.error('Expected redirection target');
  final target = p.parseWord();
  return RedirectionNode(operator, target, fd: fd, fdVariable: fdVariable);
}

RedirectionNode _parseHeredocStart(
  Parser p,
  String operator,
  int? fd, {
  required bool stripTabs,
}) {
  if (!p.isWord()) p.error('Expected here-document delimiter');

  final delimToken = p.advance();
  var delimiter = delimToken.value;
  final quoted = delimToken.quoted;

  if (delimiter.startsWith("'") && delimiter.endsWith("'")) {
    delimiter = delimiter.substring(1, delimiter.length - 1);
  } else if (delimiter.startsWith('"') && delimiter.endsWith('"')) {
    delimiter = delimiter.substring(1, delimiter.length - 1);
  }

  final redirect = RedirectionNode(
    stripTabs ? '<<-' : '<<',
    HereDocNode(delimiter, WordNode([]), stripTabs: stripTabs, quoted: quoted),
    fd: fd,
  );

  p.addPendingHeredoc(redirect, delimiter, stripTabs: stripTabs, quoted: quoted);
  return redirect;
}

/// Parse a simple command (assignments, name, args, redirections).
SimpleCommandNode parseSimpleCommand(Parser p) {
  final startLine = p.current().line;

  final assignments = <AssignmentNode>[];
  WordNode? name;
  final args = <WordNode>[];
  final redirections = <RedirectionNode>[];

  while (p.check([TokenType.assignmentWord]) || isRedirection(p)) {
    p.checkIterationLimit();
    if (p.check([TokenType.assignmentWord])) {
      assignments.add(_parseAssignment(p));
    } else {
      redirections.add(parseRedirection(p));
    }
  }

  if (p.isWord()) {
    name = p.parseWord();
  } else if (assignments.isNotEmpty &&
      (p.check([TokenType.dbrackStart]) || p.check([TokenType.dparenStart]))) {
    final token = p.advance();
    name = WordNode([LiteralPart(token.value)]);
  }

  while ((!p.isStatementEnd() || p.check([TokenType.rbrace])) &&
      !p.check([TokenType.pipe, TokenType.pipeAmp])) {
    p.checkIterationLimit();

    if (isRedirection(p)) {
      redirections.add(parseRedirection(p));
    } else if (p.check([TokenType.rbrace])) {
      final token = p.advance();
      args.add(p.parseWordFromString(token.value));
    } else if (p.check([TokenType.lbrace])) {
      final token = p.advance();
      args.add(p.parseWordFromString(token.value));
    } else if (p.check([TokenType.dbrackEnd])) {
      final token = p.advance();
      args.add(p.parseWordFromString(token.value));
    } else if (p.isWord()) {
      args.add(p.parseWord());
    } else if (p.check([TokenType.assignmentWord])) {
      final token = p.advance();
      final tokenValue = token.value;

      final endsWithEq = tokenValue.endsWith('=');
      final endsWithEqParen = tokenValue.endsWith('=(');

      if ((endsWithEq || endsWithEqParen) &&
          (endsWithEqParen || p.check([TokenType.lparen]))) {
        final baseName = endsWithEqParen
            ? tokenValue.substring(0, tokenValue.length - 2)
            : tokenValue.substring(0, tokenValue.length - 1);
        if (!endsWithEqParen) {
          p.expect(TokenType.lparen);
        }
        final elements = _parseArrayElements(p);
        p.expect(TokenType.rparen);
        final elemStrings = elements.map((e) => wordToString(p, e));
        final arrayStr = '$baseName=(${elemStrings.join(' ')})';
        args.add(p.parseWordFromString(arrayStr));
      } else {
        args.add(
          p.parseWordFromString(
            tokenValue,
            quoted: token.quoted,
            singleQuoted: token.singleQuoted,
          ),
        );
      }
    } else if (p.check([TokenType.lparen])) {
      p.error("syntax error near unexpected token `('");
    } else {
      break;
    }
  }

  return SimpleCommandNode(
    name: name,
    args: args,
    assignments: assignments,
    redirections: redirections,
  )..line = startLine;
}

final RegExp _assignNameRe = RegExp('^[a-zA-Z_][a-zA-Z0-9_]*');

AssignmentNode _parseAssignment(Parser p) {
  final token = p.expect(TokenType.assignmentWord);
  final value = token.value;

  final nameMatch = _assignNameRe.firstMatch(value);
  if (nameMatch == null) p.error('Invalid assignment: $value');

  final name = nameMatch.group(0)!;
  String? subscript;
  var pos = name.length;

  if (pos < value.length && value[pos] == '[') {
    var depth = 0;
    final subscriptStart = pos + 1;
    for (; pos < value.length; pos++) {
      if (value[pos] == '[') {
        depth++;
      } else if (value[pos] == ']') {
        depth--;
        if (depth == 0) break;
      }
    }
    if (depth != 0) p.error('Invalid assignment: $value');
    subscript = value.substring(subscriptStart, pos);
    pos++;
  }

  final append = pos < value.length && value[pos] == '+';
  if (append) pos++;
  if (pos >= value.length || value[pos] != '=') {
    p.error('Invalid assignment: $value');
  }
  pos++;

  final valueStr = value.substring(pos);

  if (valueStr == '(') {
    final elements = _parseArrayElements(p);
    p.expect(TokenType.rparen);
    final assignName = subscript != null ? '$name[$subscript]' : name;
    return AssignmentNode(assignName, null, append: append, array: elements);
  }

  if (valueStr == '' && p.check([TokenType.lparen])) {
    final currentToken = p.current();
    if (token.end == currentToken.start) {
      p.advance();
      final elements = _parseArrayElements(p);
      p.expect(TokenType.rparen);
      final assignName = subscript != null ? '$name[$subscript]' : name;
      return AssignmentNode(assignName, null, append: append, array: elements);
    }
  }

  final wordValue = valueStr.isNotEmpty
      ? p.parseWordFromString(
          valueStr,
          quoted: token.quoted,
          singleQuoted: token.singleQuoted,
          isAssignment: true,
        )
      : null;

  final assignName = subscript != null ? '$name[$subscript]' : name;
  return AssignmentNode(assignName, wordValue, append: append);
}

const Set<TokenType> _invalidArrayTokens = {
  TokenType.amp,
  TokenType.pipe,
  TokenType.pipeAmp,
  TokenType.semicolon,
  TokenType.andAnd,
  TokenType.orOr,
  TokenType.dsemi,
  TokenType.semiAnd,
  TokenType.semiSemiAnd,
};

List<WordNode> _parseArrayElements(Parser p) {
  final elements = <WordNode>[];
  p.skipNewlines();

  while (!p.check([TokenType.rparen, TokenType.eof])) {
    p.checkIterationLimit();
    if (p.isWord()) {
      elements.add(p.parseWord());
    } else if (_invalidArrayTokens.contains(p.current().type)) {
      p.error("syntax error near unexpected token `${p.current().value}'");
    } else {
      p.advance();
    }
    p.skipNewlines();
  }

  return elements;
}
