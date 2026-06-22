/// Token definitions shared by the lexer and parser.
///
/// Ported from `parser/lexer.ts` in upstream just-bash.
library;

/// The kind of a lexer [Token].
enum TokenType {
  /// End of input.
  eof,

  /// A newline separator.
  newline,

  /// A `;` separator.
  semicolon,

  /// A `&` (background/control) operator.
  amp,

  /// A `|` pipe.
  pipe,

  /// A `|&` pipe-with-stderr.
  pipeAmp,

  /// A `&&` logical-and.
  andAnd,

  /// A `||` logical-or.
  orOr,

  /// A `!` negation.
  bang,

  /// A `<` redirection.
  less,

  /// A `>` redirection.
  great,

  /// A `<<` heredoc redirection.
  dless,

  /// A `>>` append redirection.
  dgreat,

  /// A `<&` fd-duplication redirection.
  lessand,

  /// A `>&` fd-duplication redirection.
  greatand,

  /// A `<>` read-write redirection.
  lessgreat,

  /// A `<<-` tab-stripping heredoc redirection.
  dlessdash,

  /// A `>|` clobbering redirection.
  clobber,

  /// A `<<<` here-string redirection.
  tless,

  /// A `&>` redirect-both redirection.
  andGreat,

  /// A `&>>` append-both redirection.
  andDgreat,

  /// A `(` open paren.
  lparen,

  /// A `)` close paren.
  rparen,

  /// A `{` open brace.
  lbrace,

  /// A `}` close brace.
  rbrace,

  /// A `;;` case terminator.
  dsemi,

  /// A `;&` case fall-through terminator.
  semiAnd,

  /// A `;;&` case continue terminator.
  semiSemiAnd,

  /// A `[[` conditional-expression start.
  dbrackStart,

  /// A `]]` conditional-expression end.
  dbrackEnd,

  /// A `((` arithmetic-command start.
  dparenStart,

  /// A `))` arithmetic-command end.
  dparenEnd,

  /// The `if` reserved word.
  ifKw,

  /// The `then` reserved word.
  then,

  /// The `else` reserved word.
  elseKw,

  /// The `elif` reserved word.
  elif,

  /// The `fi` reserved word.
  fi,

  /// The `for` reserved word.
  forKw,

  /// The `while` reserved word.
  whileKw,

  /// The `until` reserved word.
  until,

  /// The `do` reserved word.
  doKw,

  /// The `done` reserved word.
  done,

  /// The `case` reserved word.
  caseKw,

  /// The `esac` reserved word.
  esac,

  /// The `in` reserved word.
  inKw,

  /// The `function` reserved word.
  function,

  /// The `select` reserved word.
  select,

  /// The `time` reserved word.
  time,

  /// The `coproc` reserved word.
  coproc,

  /// A general word.
  word,

  /// A valid variable name.
  name,

  /// A number (e.g. the fd in `2>&1`).
  number,

  /// An assignment word (`VAR=value`).
  assignmentWord,

  /// An `{varname}` fd variable before a redirect operator.
  fdVariable,

  /// A comment.
  comment,

  /// Here-document content.
  heredocContent,
}

/// A single lexer token.
class Token {
  /// Creates a token.
  const Token({
    required this.type,
    required this.value,
    required this.start,
    required this.end,
    required this.line,
    required this.column,
    this.quoted = false,
    this.singleQuoted = false,
  });

  /// The token kind.
  final TokenType type;

  /// The raw token text.
  final String value;

  /// The start offset in the input.
  final int start;

  /// The end offset in the input.
  final int end;

  /// The 1-based line number.
  final int line;

  /// The 1-based column number.
  final int column;

  /// Whether the word contained double-quoted text.
  final bool quoted;

  /// Whether the word was single-quoted.
  final bool singleQuoted;
}

/// Error thrown when the lexer encounters invalid input.
class LexerError implements Exception {
  /// Creates a lexer error at the given [line] and [column].
  LexerError(this.rawMessage, this.line, this.column);

  /// The error message without the line prefix.
  final String rawMessage;

  /// The 1-based line number where the error occurred.
  final int line;

  /// The 1-based column number where the error occurred.
  final int column;

  @override
  String toString() => 'line $line: $rawMessage';
}

/// Reserved words mapped to their token types.
const Map<String, TokenType> reservedWords = {
  'if': TokenType.ifKw,
  'then': TokenType.then,
  'else': TokenType.elseKw,
  'elif': TokenType.elif,
  'fi': TokenType.fi,
  'for': TokenType.forKw,
  'while': TokenType.whileKw,
  'until': TokenType.until,
  'do': TokenType.doKw,
  'done': TokenType.done,
  'case': TokenType.caseKw,
  'esac': TokenType.esac,
  'in': TokenType.inKw,
  'function': TokenType.function,
  'select': TokenType.select,
  'time': TokenType.time,
  'coproc': TokenType.coproc,
};
