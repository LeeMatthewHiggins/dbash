/// Parser support types and constants.
///
/// Ported from `parser/types.ts` in upstream just-bash.
library;

import 'package:dbash/src/parser/token.dart';

/// Maximum input size (1MB).
const int maxInputSize = 1000000;

/// Maximum number of tokens to parse.
const int maxTokens = 100000;

/// Maximum iterations in parsing loops.
const int maxParseIterations = 1000000;

/// Maximum recursion depth for nested constructs.
const int maxParserDepth = 200;

/// Redirection operator tokens.
const Set<TokenType> redirectionTokens = {
  TokenType.less,
  TokenType.great,
  TokenType.dless,
  TokenType.dgreat,
  TokenType.lessand,
  TokenType.greatand,
  TokenType.lessgreat,
  TokenType.dlessdash,
  TokenType.clobber,
  TokenType.tless,
  TokenType.andGreat,
  TokenType.andDgreat,
};

/// Redirection operators that may follow a leading fd number (e.g. `2>&1`).
const Set<TokenType> redirectionAfterNumber = {
  TokenType.less,
  TokenType.great,
  TokenType.dless,
  TokenType.dgreat,
  TokenType.lessand,
  TokenType.greatand,
  TokenType.lessgreat,
  TokenType.dlessdash,
  TokenType.clobber,
  TokenType.tless,
};

/// Redirection operators that may follow a `{varname}` fd variable.
const Set<TokenType> redirectionAfterFdVariable = {
  TokenType.less,
  TokenType.great,
  TokenType.dless,
  TokenType.dgreat,
  TokenType.lessand,
  TokenType.greatand,
  TokenType.lessgreat,
  TokenType.dlessdash,
  TokenType.clobber,
  TokenType.tless,
  TokenType.andGreat,
  TokenType.andDgreat,
};

/// A structured parse error.
class ParseError {
  /// Creates a parse error.
  const ParseError(this.message, this.line, this.column, [this.token]);

  /// The error message.
  final String message;

  /// The 1-based line number.
  final int line;

  /// The 1-based column number.
  final int column;

  /// The offending token, if any.
  final Token? token;
}

/// Exception thrown by the parser on a syntax error.
class ParseException implements Exception {
  /// Creates a parse exception.
  ParseException(this.rawMessage, this.line, this.column, [this.token]);

  /// The message without the location prefix.
  final String rawMessage;

  /// The 1-based line number.
  final int line;

  /// The 1-based column number.
  final int column;

  /// The offending token, if any.
  final Token? token;

  @override
  String toString() => 'Parse error at $line:$column: $rawMessage';
}
