/// Recursive-descent parser for bash scripts.
///
/// Consumes tokens from the [Lexer] and produces an AST. Faithful port of
/// `parser/parser.ts` and its sibling sub-parser modules from upstream
/// just-bash. The sub-parsers live in `part` files of this library so they
/// share access to the [Parser] instance, mirroring the upstream module split.
///
/// The deeply nested grammar means a couple of stylistic lints are disabled
/// file-wide for this mechanical port.
// ignore_for_file: lines_longer_than_80_chars
// ignore_for_file: avoid_positional_boolean_parameters, cascade_invocations
library;

import 'package:dbash/src/ast/ast.dart';
import 'package:dbash/src/parser/lexer.dart';
import 'package:dbash/src/parser/parser_types.dart';
import 'package:dbash/src/parser/token.dart';

part 'command_parser.dart';
part 'compound_parser.dart';
part 'conditional_parser.dart';
part 'expansion_parser.dart';
part 'arithmetic_parser.dart';
part 'word_parser.dart';
part 'parser_substitution.dart';

class _PendingHeredoc {
  _PendingHeredoc(this.redirect, this.delimiter, this.stripTabs, this.quoted);
  final RedirectionNode redirect;
  final String delimiter;
  final bool stripTabs;
  final bool quoted;
}

/// Transforms a token stream into an AST.
class Parser {
  List<Token> _tokens = [];
  int _pos = 0;
  List<_PendingHeredoc> _pendingHeredocs = [];
  int _parseIterations = 0;
  int _parseDepth = 0;
  String _input = '';

  /// The raw input string being parsed (used by the conditional parser to
  /// extract exact whitespace in regex patterns).
  String getInput() => _input;

  /// Check the parse iteration limit to guard against infinite loops.
  void checkIterationLimit() {
    _parseIterations++;
    if (_parseIterations > maxParseIterations) {
      throw ParseException(
        'Maximum parse iterations exceeded (possible infinite loop)',
        current().line,
        current().column,
      );
    }
  }

  /// Increment parse depth (guarding against deep nesting) and return a
  /// function that decrements it.
  void Function() enterDepth() {
    _parseDepth++;
    if (_parseDepth > maxParserDepth) {
      throw ParseException(
        'Maximum parser nesting depth exceeded ($maxParserDepth)',
        current().line,
        current().column,
      );
    }
    return () => _parseDepth--;
  }

  /// Parse a bash script [input].
  ScriptNode parse(String input, {LexerOptions? options}) {
    if (input.length > maxInputSize) {
      throw ParseException(
        'Input too large: ${input.length} bytes exceeds limit of $maxInputSize',
        1,
        1,
      );
    }

    _input = input;
    final lexer = Lexer(input, options: options);
    _tokens = lexer.tokenize();

    if (_tokens.length > maxTokens) {
      throw ParseException(
        'Too many tokens: ${_tokens.length} exceeds limit of $maxTokens',
        1,
        1,
      );
    }

    _pos = 0;
    _pendingHeredocs = [];
    _parseIterations = 0;
    _parseDepth = 0;
    return _parseScript();
  }

  /// Parse from a pre-tokenized [tokens] list.
  ScriptNode parseTokens(List<Token> tokens) {
    _tokens = tokens;
    _pos = 0;
    _pendingHeredocs = [];
    _parseIterations = 0;
    _parseDepth = 0;
    return _parseScript();
  }

  // ===========================================================================
  // HELPER METHODS
  // ===========================================================================

  /// The current token (clamped to the final token).
  Token current() =>
      _pos < _tokens.length ? _tokens[_pos] : _tokens[_tokens.length - 1];

  /// The token at [offset] from the current position (clamped).
  Token peek([int offset = 0]) {
    final i = _pos + offset;
    return i < _tokens.length ? _tokens[i] : _tokens[_tokens.length - 1];
  }

  /// Advance past and return the current token.
  Token advance() {
    final token = current();
    if (_pos < _tokens.length - 1) _pos++;
    return token;
  }

  /// The current parse position.
  int getPos() => _pos;

  TokenType? get _currentType =>
      _pos < _tokens.length ? _tokens[_pos].type : null;

  /// Whether the current token matches any of [types].
  bool check(List<TokenType> types) {
    final type = _currentType;
    return type != null && types.contains(type);
  }

  /// Consume a token of [type], or throw a [ParseException].
  Token expect(TokenType type, [String? message]) {
    if (check([type])) return advance();
    final token = current();
    throw ParseException(
      message ?? 'Expected $type, got ${token.type}',
      token.line,
      token.column,
      token,
    );
  }

  /// Throw a [ParseException] at the current token.
  Never error(String message) {
    final token = current();
    throw ParseException(message, token.line, token.column, token);
  }

  /// Skip newline and comment tokens, processing pending heredocs.
  void skipNewlines() {
    while (check([TokenType.newline, TokenType.comment])) {
      if (check([TokenType.newline])) {
        advance();
        _processHeredocs();
      } else {
        advance();
      }
    }
  }

  /// Skip statement separators (newlines, `;`, comments, optionally case
  /// terminators).
  void skipSeparators([bool includeCaseTerminators = true]) {
    while (true) {
      if (check([TokenType.newline])) {
        advance();
        _processHeredocs();
        continue;
      }
      if (check([TokenType.semicolon, TokenType.comment])) {
        advance();
        continue;
      }
      if (includeCaseTerminators &&
          check([
            TokenType.dsemi,
            TokenType.semiAnd,
            TokenType.semiSemiAnd,
          ])) {
        advance();
        continue;
      }
      break;
    }
  }

  /// Register a pending here-document whose content fills in [redirect].
  void addPendingHeredoc(
    RedirectionNode redirect,
    String delimiter, {
    required bool stripTabs,
    required bool quoted,
  }) {
    _pendingHeredocs.add(
      _PendingHeredoc(redirect, delimiter, stripTabs, quoted),
    );
  }

  void _processHeredocs() {
    for (final heredoc in _pendingHeredocs) {
      if (check([TokenType.heredocContent])) {
        final content = advance();
        WordNode contentWord;
        if (heredoc.quoted) {
          contentWord = WordNode([LiteralPart(content.value)]);
        } else {
          contentWord = parseWordFromString(
            content.value,
            hereDoc: true,
          );
        }
        heredoc.redirect.target = HereDocNode(
          heredoc.delimiter,
          contentWord,
          stripTabs: heredoc.stripTabs,
          quoted: heredoc.quoted,
        );
      }
    }
    _pendingHeredocs = [];
  }

  /// Whether the current token ends a statement.
  bool isStatementEnd() {
    return check([
      TokenType.eof,
      TokenType.newline,
      TokenType.semicolon,
      TokenType.amp,
      TokenType.andAnd,
      TokenType.orOr,
      TokenType.rparen,
      TokenType.rbrace,
      TokenType.dsemi,
      TokenType.semiAnd,
      TokenType.semiSemiAnd,
    ]);
  }

  bool _isCommandStart() {
    final t = current().type;
    return t == TokenType.word ||
        t == TokenType.name ||
        t == TokenType.number ||
        t == TokenType.assignmentWord ||
        t == TokenType.ifKw ||
        t == TokenType.forKw ||
        t == TokenType.whileKw ||
        t == TokenType.until ||
        t == TokenType.caseKw ||
        t == TokenType.lparen ||
        t == TokenType.lbrace ||
        t == TokenType.dparenStart ||
        t == TokenType.dbrackStart ||
        t == TokenType.function ||
        t == TokenType.bang ||
        t == TokenType.time ||
        t == TokenType.inKw ||
        t == TokenType.less ||
        t == TokenType.great ||
        t == TokenType.dless ||
        t == TokenType.dgreat ||
        t == TokenType.lessand ||
        t == TokenType.greatand ||
        t == TokenType.lessgreat ||
        t == TokenType.dlessdash ||
        t == TokenType.clobber ||
        t == TokenType.tless ||
        t == TokenType.andGreat ||
        t == TokenType.andDgreat;
  }

  // ===========================================================================
  // SCRIPT PARSING
  // ===========================================================================

  ScriptNode _parseScript() {
    final statements = <StatementNode>[];
    const maxIterations = 10000;
    var iterations = 0;

    skipNewlines();

    while (!check([TokenType.eof])) {
      iterations++;
      if (iterations > maxIterations) {
        error('Parser stuck: too many iterations (>$maxIterations)');
      }

      final deferredErrorStmt = _checkUnexpectedToken();
      if (deferredErrorStmt != null) {
        statements.add(deferredErrorStmt);
        skipSeparators(false);
        continue;
      }

      final posBefore = _pos;
      final stmt = parseStatement();
      if (stmt != null) statements.add(stmt);
      skipSeparators(false);

      if (check([
        TokenType.dsemi,
        TokenType.semiAnd,
        TokenType.semiSemiAnd,
      ])) {
        error("syntax error near unexpected token `${current().value}'");
      }

      if (_pos == posBefore && !check([TokenType.eof])) {
        advance();
      }
    }

    return ScriptNode(statements);
  }

  StatementNode? _checkUnexpectedToken() {
    final t = current().type;
    final v = current().value;

    if (t == TokenType.doKw ||
        t == TokenType.done ||
        t == TokenType.then ||
        t == TokenType.elseKw ||
        t == TokenType.elif ||
        t == TokenType.fi ||
        t == TokenType.esac) {
      error("syntax error near unexpected token `$v'");
    }

    if (t == TokenType.rbrace || t == TokenType.rparen) {
      final errorMsg = "syntax error near unexpected token `$v'";
      advance();
      return StatementNode(
        [
          PipelineNode([SimpleCommandNode(name: null)]),
        ],
        deferredError: DeferredError(errorMsg, v),
      );
    }

    if (t == TokenType.dsemi ||
        t == TokenType.semiAnd ||
        t == TokenType.semiSemiAnd) {
      error("syntax error near unexpected token `$v'");
    }

    if (t == TokenType.semicolon) {
      error("syntax error near unexpected token `$v'");
    }

    if (t == TokenType.pipe || t == TokenType.pipeAmp) {
      error("syntax error near unexpected token `$v'");
    }

    return null;
  }

  // ===========================================================================
  // STATEMENT PARSING
  // ===========================================================================

  /// Parse a single statement, or null if no command starts here.
  StatementNode? parseStatement() {
    skipNewlines();

    if (!_isCommandStart()) return null;

    final startOffset = current().start;

    final pipelines = <PipelineNode>[];
    final operators = <String>[];
    var background = false;

    pipelines.add(_parsePipeline());

    while (check([TokenType.andAnd, TokenType.orOr])) {
      final op = advance();
      operators.add(op.type == TokenType.andAnd ? '&&' : '||');
      skipNewlines();
      pipelines.add(_parsePipeline());
    }

    if (check([TokenType.amp])) {
      advance();
      background = true;
    }

    final endOffset = _pos > 0 ? _tokens[_pos - 1].end : startOffset;
    final sourceText = _sliceInput(startOffset, endOffset);

    return StatementNode(
      pipelines,
      operators: operators,
      background: background,
      sourceText: sourceText,
    );
  }

  String _sliceInput(int start, int end) {
    final lo = start.clamp(0, _input.length);
    final hi = end.clamp(lo, _input.length);
    return _input.substring(lo, hi);
  }

  // ===========================================================================
  // PIPELINE PARSING
  // ===========================================================================

  PipelineNode _parsePipeline() {
    var timed = false;
    var timePosix = false;
    if (check([TokenType.time])) {
      advance();
      timed = true;
      if (check([TokenType.word, TokenType.name]) &&
          current().value == '-p') {
        advance();
        timePosix = true;
      }
    }

    var negationCount = 0;
    while (check([TokenType.bang])) {
      advance();
      negationCount++;
    }
    final negated = negationCount.isOdd;

    final commands = <CommandNode>[];
    final pipeStderr = <bool>[];

    commands.add(_parseCommand());

    while (check([TokenType.pipe, TokenType.pipeAmp])) {
      final pipeToken = advance();
      skipNewlines();
      pipeStderr.add(pipeToken.type == TokenType.pipeAmp);
      commands.add(_parseCommand());
    }

    return PipelineNode(
      commands,
      negated: negated,
      timed: timed,
      timePosix: timePosix,
      pipeStderr: pipeStderr.isNotEmpty ? pipeStderr : null,
    );
  }

  // ===========================================================================
  // COMMAND PARSING
  // ===========================================================================

  CommandNode _parseCommand() {
    if (check([TokenType.ifKw])) return parseIf(this);
    if (check([TokenType.forKw])) return parseFor(this);
    if (check([TokenType.whileKw])) return parseWhile(this);
    if (check([TokenType.until])) return parseUntil(this);
    if (check([TokenType.caseKw])) return parseCase(this);
    if (check([TokenType.lparen])) return parseSubshell(this);
    if (check([TokenType.lbrace])) return parseGroup(this);
    if (check([TokenType.dparenStart])) {
      if (_dparenClosesWithSpacedParens()) {
        return _parseNestedSubshellsFromDparen();
      }
      return _parseArithmeticCommand();
    }
    if (check([TokenType.dbrackStart])) return _parseConditionalCommand();
    if (check([TokenType.function])) return _parseFunctionDef();

    if (check([TokenType.name, TokenType.word]) &&
        peek(1).type == TokenType.lparen &&
        peek(2).type == TokenType.rparen) {
      return _parseFunctionDef();
    }

    return parseSimpleCommand(this);
  }

  bool _dparenClosesWithSpacedParens() {
    var depth = 1;
    var offset = 1;

    while (offset < _tokens.length - _pos) {
      final tok = peek(offset);
      if (tok.type == TokenType.eof) return false;

      if (tok.type == TokenType.dparenStart || tok.type == TokenType.lparen) {
        depth++;
      } else if (tok.type == TokenType.dparenEnd) {
        depth -= 2;
        if (depth <= 0) return false;
      } else if (tok.type == TokenType.rparen) {
        depth--;
        if (depth == 0) {
          if (peek(offset + 1).type == TokenType.rparen) return true;
        }
      }
      offset++;
    }
    return false;
  }

  SubshellNode _parseNestedSubshellsFromDparen() {
    advance();
    final innerBody = parseCompoundList();
    expect(TokenType.rparen);
    expect(TokenType.rparen);
    final redirections = parseOptionalRedirections();
    final innerSubshell = SubshellNode(innerBody);
    return SubshellNode(
      [
        StatementNode([
          PipelineNode([innerSubshell]),
        ]),
      ],
      redirections: redirections,
    );
  }

  // ===========================================================================
  // WORD PARSING
  // ===========================================================================

  /// Whether the current token can be parsed as a word.
  bool isWord() {
    final t = current().type;
    return t == TokenType.word ||
        t == TokenType.name ||
        t == TokenType.number ||
        t == TokenType.ifKw ||
        t == TokenType.forKw ||
        t == TokenType.whileKw ||
        t == TokenType.until ||
        t == TokenType.caseKw ||
        t == TokenType.function ||
        t == TokenType.elseKw ||
        t == TokenType.elif ||
        t == TokenType.fi ||
        t == TokenType.then ||
        t == TokenType.doKw ||
        t == TokenType.done ||
        t == TokenType.esac ||
        t == TokenType.inKw ||
        t == TokenType.select ||
        t == TokenType.time ||
        t == TokenType.coproc ||
        t == TokenType.bang;
  }

  /// Parse a word from the current token.
  WordNode parseWord() {
    final token = advance();
    return parseWordFromString(
      token.value,
      quoted: token.quoted,
      singleQuoted: token.singleQuoted,
    );
  }

  /// Parse a word with brace expansion disabled (for `[[ ]]`).
  WordNode parseWordNoBraceExpansion() {
    final token = advance();
    return parseWordFromString(
      token.value,
      quoted: token.quoted,
      singleQuoted: token.singleQuoted,
      noBraceExpansion: true,
    );
  }

  /// Parse a word for a regex pattern (in `[[ =~ ]]`).
  WordNode parseWordForRegex() {
    final token = advance();
    return parseWordFromString(
      token.value,
      quoted: token.quoted,
      singleQuoted: token.singleQuoted,
      noBraceExpansion: true,
      regexPattern: true,
    );
  }

  /// Parse a word from a raw string [value].
  WordNode parseWordFromString(
    String value, {
    bool quoted = false,
    bool singleQuoted = false,
    bool isAssignment = false,
    bool hereDoc = false,
    bool noBraceExpansion = false,
    bool regexPattern = false,
  }) {
    final parts = parseWordParts(
      this,
      value,
      quoted: quoted,
      singleQuoted: singleQuoted,
      isAssignment: isAssignment,
      hereDoc: hereDoc,
      noBraceExpansion: noBraceExpansion,
      regexPattern: regexPattern,
    );
    return WordNode(parts);
  }

  /// Parse a `$(...)` command substitution starting at [start] in [value].
  ({CommandSubstitutionPart part, int endIndex}) parseCommandSubstitution(
    String value,
    int start,
  ) {
    return parseCommandSubstitutionFromString(
      value,
      start,
      Parser.new,
      error,
    );
  }

  /// Parse a backtick command substitution starting at [start] in [value].
  ({CommandSubstitutionPart part, int endIndex}) parseBacktickSubstitution(
    String value,
    int start, {
    bool inDoubleQuotes = false,
  }) {
    return parseBacktickSubstitutionFromString(
      value,
      start,
      inDoubleQuotes: inDoubleQuotes,
      makeParser: Parser.new,
      onError: error,
    );
  }

  /// Whether `$((` at [start] in [value] is a command substitution with a
  /// nested subshell rather than arithmetic.
  bool isDollarDparenSubshell(String value, int start) =>
      isDollarDparenSubshellHelper(value, start);

  /// Parse a `$((...))` arithmetic expansion starting at [start] in [value].
  ({ArithmeticExpansionPart part, int endIndex}) parseArithmeticExpansion(
    String value,
    int start,
  ) {
    final exprStart = start + 3;
    var arithDepth = 1;
    var parenDepth = 0;
    var i = exprStart;

    while (i < value.length - 1 && arithDepth > 0) {
      if (value[i] == r'$' && value[i + 1] == '(') {
        if (i + 2 < value.length && value[i + 2] == '(') {
          arithDepth++;
          i += 3;
        } else {
          parenDepth++;
          i += 2;
        }
      } else if (value[i] == '(' && value[i + 1] == '(') {
        arithDepth++;
        i += 2;
      } else if (value[i] == ')' && value[i + 1] == ')') {
        if (parenDepth > 0) {
          parenDepth--;
          i++;
        } else {
          arithDepth--;
          if (arithDepth > 0) i += 2;
        }
      } else if (value[i] == '(') {
        parenDepth++;
        i++;
      } else if (value[i] == ')') {
        if (parenDepth > 0) parenDepth--;
        i++;
      } else {
        i++;
      }
    }

    final exprStr = value.substring(exprStart, i.clamp(exprStart, value.length));
    final expression = parseArithmeticExpression(exprStr);
    return (part: ArithmeticExpansionPart(expression), endIndex: i + 2);
  }

  ArithmeticCommandNode _parseArithmeticCommand() {
    final startToken = expect(TokenType.dparenStart);

    var exprStr = '';
    var dparenDepth = 1;
    var parenDepth = 0;
    var pendingRparen = false;
    var foundClosing = false;

    final compoundEqRe = RegExp(r'[|&^+\-*/%<>]$');

    while (dparenDepth > 0 && !check([TokenType.eof])) {
      if (pendingRparen) {
        pendingRparen = false;
        if (parenDepth > 0) {
          parenDepth--;
          exprStr += ')';
          continue;
        }
        if (check([TokenType.rparen])) {
          dparenDepth--;
          foundClosing = true;
          advance();
          continue;
        }
        if (check([TokenType.dparenEnd])) {
          dparenDepth--;
          foundClosing = true;
          continue;
        }
        exprStr += ')';
        continue;
      }

      if (check([TokenType.dparenStart])) {
        dparenDepth++;
        exprStr += '((';
        advance();
      } else if (check([TokenType.dparenEnd])) {
        if (parenDepth >= 2) {
          parenDepth -= 2;
          exprStr += '))';
          advance();
        } else if (parenDepth == 1) {
          parenDepth--;
          exprStr += ')';
          pendingRparen = true;
          advance();
        } else {
          dparenDepth--;
          foundClosing = true;
          if (dparenDepth > 0) exprStr += '))';
          advance();
        }
      } else if (check([TokenType.lparen])) {
        parenDepth++;
        exprStr += '(';
        advance();
      } else if (check([TokenType.rparen])) {
        if (parenDepth > 0) parenDepth--;
        exprStr += ')';
        advance();
      } else {
        final value = current().value;
        final lastChar = exprStr.isNotEmpty ? exprStr[exprStr.length - 1] : '';
        final needsSpace = exprStr.isNotEmpty &&
            !exprStr.endsWith(' ') &&
            !(value == '=' && compoundEqRe.hasMatch(exprStr)) &&
            !(value == '<' && lastChar == '<') &&
            !(value == '>' && lastChar == '>');
        if (needsSpace) exprStr += ' ';
        exprStr += value;
        advance();
      }
    }

    if (!foundClosing) expect(TokenType.dparenEnd);

    final expression = parseArithmeticExpression(exprStr.trim());
    final redirections = parseOptionalRedirections();
    return ArithmeticCommandNode(expression, redirections: redirections)
      ..line = startToken.line;
  }

  ConditionalCommandNode _parseConditionalCommand() {
    final startToken = expect(TokenType.dbrackStart);
    final expression = parseConditionalExpression(this);
    expect(TokenType.dbrackEnd);
    final redirections = parseOptionalRedirections();
    return ConditionalCommandNode(
      expression,
      redirections: redirections,
      line: startToken.line,
    );
  }

  FunctionDefNode _parseFunctionDef() {
    String name;

    if (check([TokenType.function])) {
      advance();
      if (check([TokenType.name]) || check([TokenType.word])) {
        name = advance().value;
      } else {
        final token = current();
        throw ParseException(
          'Expected function name',
          token.line,
          token.column,
          token,
        );
      }
      if (check([TokenType.lparen])) {
        advance();
        expect(TokenType.rparen);
      }
    } else {
      name = advance().value;
      if (name.contains(r'$')) {
        error("`$name': not a valid identifier");
      }
      expect(TokenType.lparen);
      expect(TokenType.rparen);
    }

    skipNewlines();
    final body = _parseCompoundCommandBody(forFunctionBody: true);
    final redirections = parseOptionalRedirections();
    return FunctionDefNode(name, body, redirections: redirections);
  }

  CompoundCommandNode _parseCompoundCommandBody({
    bool forFunctionBody = false,
  }) {
    final skipRedirections = forFunctionBody;
    if (check([TokenType.lbrace])) {
      return parseGroup(this, skipRedirections: skipRedirections);
    }
    if (check([TokenType.lparen])) {
      return parseSubshell(this, skipRedirections: skipRedirections);
    }
    if (check([TokenType.ifKw])) {
      return parseIf(this, skipRedirections: skipRedirections);
    }
    if (check([TokenType.forKw])) {
      return parseFor(this, skipRedirections: skipRedirections);
    }
    if (check([TokenType.whileKw])) {
      return parseWhile(this, skipRedirections: skipRedirections);
    }
    if (check([TokenType.until])) {
      return parseUntil(this, skipRedirections: skipRedirections);
    }
    if (check([TokenType.caseKw])) {
      return parseCase(this, skipRedirections: skipRedirections);
    }
    error('Expected compound command for function body');
  }

  // ===========================================================================
  // HELPER PARSING
  // ===========================================================================

  /// Parse a list of statements until a block-closing keyword.
  List<StatementNode> parseCompoundList() {
    final exitDepth = enterDepth();
    final statements = <StatementNode>[];

    skipNewlines();

    while (!check([
          TokenType.eof,
          TokenType.fi,
          TokenType.elseKw,
          TokenType.elif,
          TokenType.then,
          TokenType.doKw,
          TokenType.done,
          TokenType.esac,
          TokenType.rparen,
          TokenType.rbrace,
          TokenType.dsemi,
          TokenType.semiAnd,
          TokenType.semiSemiAnd,
        ]) &&
        _isCommandStart()) {
      checkIterationLimit();
      final posBefore = _pos;
      final stmt = parseStatement();
      if (stmt != null) statements.add(stmt);
      skipSeparators();
      if (_pos == posBefore && stmt == null) break;
    }

    exitDepth();
    return statements;
  }

  /// Parse a run of optional redirections.
  List<RedirectionNode> parseOptionalRedirections() {
    final redirections = <RedirectionNode>[];
    while (isRedirection(this)) {
      checkIterationLimit();
      final posBefore = _pos;
      redirections.add(parseRedirection(this));
      if (_pos == posBefore) break;
    }
    return redirections;
  }

  // ===========================================================================
  // ARITHMETIC EXPRESSION PARSING
  // ===========================================================================

  /// Parse the arithmetic expression in [input].
  ArithmeticExpressionNode parseArithmeticExpression(String input) =>
      parseArithmeticExpressionImpl(this, input);
}

/// Convenience function: parse a bash script string into an AST.
ScriptNode parse(String input, {LexerOptions? options}) {
  return Parser().parse(input, options: options);
}
