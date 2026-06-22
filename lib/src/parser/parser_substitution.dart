/// Command/arithmetic substitution parsing helpers.
///
/// Port of `parser/parser-substitution.ts` in progress. Part of the `parser`
/// library.
//
// TODO(dbash): port command/backtick substitution string parsing. Placeholders
// until then. `readHeredocDelimiter` and the lexer-level helpers already live
// in lexer.dart.
// ignore_for_file: lines_longer_than_80_chars
part of 'parser.dart';

/// Whether `$((` at [start] in [value] is a command substitution with a nested
/// subshell rather than arithmetic.
bool isDollarDparenSubshellHelper(String value, int start) {
  throw UnimplementedError(
    'isDollarDparenSubshell: substitution parser not yet ported',
  );
}

/// Parse a `$(...)` command substitution from [value] starting at [start].
({CommandSubstitutionPart part, int endIndex}) parseCommandSubstitutionFromString(
  String value,
  int start,
  Parser Function() makeParser,
  Never Function(String) onError,
) {
  throw UnimplementedError(
    'parseCommandSubstitutionFromString: substitution parser not yet ported',
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
  throw UnimplementedError(
    'parseBacktickSubstitutionFromString: substitution parser not yet ported',
  );
}
