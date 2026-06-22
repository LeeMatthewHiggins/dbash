/// Word-part expansion parser.
///
/// Port of `parser/expansion-parser.ts` in progress. Part of the `parser`
/// library.
//
// TODO(dbash): port parseWordParts (parameter expansion, command/arith
// substitution, brace/tilde/glob detection). Placeholder until then.
part of 'parser.dart';

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
}) {
  throw UnimplementedError('parseWordParts: expansion parser not yet ported');
}
