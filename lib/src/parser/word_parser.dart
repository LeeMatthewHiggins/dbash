/// Word parser helpers.
///
/// Port of `parser/word-parser.ts` in progress. Part of the `parser` library.
//
// TODO(dbash): port the full word-parser. The functions below are placeholders
// so the parser library compiles; they throw until ported.
part of 'parser.dart';

/// Map a redirection [type] token to its operator string.
String tokenToRedirectOp(Parser p, TokenType type) {
  throw UnimplementedError('tokenToRedirectOp: word-parser not yet ported');
}

/// Render a [word] back to its source string form.
String wordToString(Parser p, WordNode word) {
  throw UnimplementedError('wordToString: word-parser not yet ported');
}
