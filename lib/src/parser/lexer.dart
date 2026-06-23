/// Lexer for bash scripts.
///
/// Tokenizes input into a stream of [Token]s the parser consumes. Handles
/// operators, words and quoting, comments, here-documents, and escape
/// sequences. Ported faithfully from `parser/lexer.ts` in upstream just-bash.
///
/// The mechanical fidelity of this port means a few purely stylistic lints are
/// disabled file-wide: the tokenizer builds words with `+=` accumulators it
/// must index into, and many branches are long.
// ignore_for_file: lines_longer_than_80_chars, use_string_buffers
// ignore_for_file: cascade_invocations
library;

import 'package:dbash/src/parser/token.dart';

/// Default max heredoc size to prevent memory exhaustion (10MB).
const int _defaultMaxHeredocSize = 10485760;

/// Options controlling lexer behavior.
class LexerOptions {
  /// Creates lexer options.
  const LexerOptions({this.maxHeredocSize = _defaultMaxHeredocSize});

  /// Maximum heredoc size in bytes (default: 10MB).
  final int maxHeredocSize;
}

final RegExp _nameRe = RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$');
final RegExp _namePrefixRe = RegExp('^[a-zA-Z_][a-zA-Z0-9_]*');
final RegExp _digitsRe = RegExp(r'^[0-9]+$');
final RegExp _letterRe = RegExp('[a-zA-Z_]');
final RegExp _wordCharRe = RegExp(r'[a-zA-Z0-9_\-.]');
final RegExp _arithOpRe = RegExp(r'[+\-*/%<>&|^!~?:]');
final RegExp _cmdStartRe = RegExp('[a-zA-Z_/.]');
final RegExp _wsRe = RegExp(r'\s');
final RegExp _delimEndRe = RegExp(r'[\s;<>&|()]');
final RegExp _leadingTabsRe = RegExp(r'^\t+');

/// Check whether [s] is a valid variable name.
bool _isValidName(String s) => _nameRe.hasMatch(s);

/// Check whether [str] is a valid assignment LHS with optional nested array
/// subscript (e.g. `VAR`, `a[0]`, `a[x+1]`, `a[a[0]]`).
bool _isValidAssignmentLHS(String str) {
  final match = _namePrefixRe.firstMatch(str);
  if (match == null) return false;

  final afterName = str.substring(match.group(0)!.length);
  if (afterName == '' || afterName == '+') return true;

  if (afterName.isNotEmpty && afterName[0] == '[') {
    var depth = 0;
    var i = 0;
    for (; i < afterName.length; i++) {
      if (afterName[i] == '[') {
        depth++;
      } else if (afterName[i] == ']') {
        depth--;
        if (depth == 0) break;
      }
    }
    if (depth != 0 || i >= afterName.length) return false;
    final afterBracket = afterName.substring(i + 1);
    return afterBracket == '' || afterBracket == '+';
  }
  return false;
}

/// Find the index of assignment `=` (or `=` after `+`) outside of brackets,
/// or -1 if not found.
int _findAssignmentEq(String str) {
  var depth = 0;
  for (var i = 0; i < str.length; i++) {
    final c = str[i];
    if (c == '[') {
      depth++;
    } else if (c == ']') {
      depth--;
    } else if (depth == 0 && c == '=') {
      return i;
    } else if (depth == 0 && c == '+' && _charAt(str, i + 1) == '=') {
      return i + 1;
    }
  }
  return -1;
}

/// Safe character access: returns '' when [i] is out of range (mirrors the
/// `undefined` comparisons of the TypeScript original).
String _charAt(String s, int i) =>
    (i >= 0 && i < s.length) ? s[i] : '';

/// Safe slice that clamps [end] to the string length (mirrors JS `slice`).
String _slice(String s, int start, int end) {
  final lo = start < 0 ? 0 : (start > s.length ? s.length : start);
  final hi = end < lo ? lo : (end > s.length ? s.length : end);
  return s.substring(lo, hi);
}

bool _isWordBoundary(String char) {
  return char == ' ' ||
      char == '\t' ||
      char == '\n' ||
      char == ';' ||
      char == '&' ||
      char == '|' ||
      char == '(' ||
      char == ')' ||
      char == '<' ||
      char == '>';
}

/// Three-character operators (first, second, third, type).
const List<List<Object>> _threeCharOps = [
  [';', ';', '&', TokenType.semiSemiAnd],
  ['<', '<', '<', TokenType.tless],
  ['&', '>', '>', TokenType.andDgreat],
];

/// Two-character operators (first, second, type). `<<`, `((` and `))` have
/// special handling and are not in this table.
const List<List<Object>> _twoCharOps = [
  ['[', '[', TokenType.dbrackStart],
  [']', ']', TokenType.dbrackEnd],
  ['(', '(', TokenType.dparenStart],
  [')', ')', TokenType.dparenEnd],
  ['&', '&', TokenType.andAnd],
  ['|', '|', TokenType.orOr],
  [';', ';', TokenType.dsemi],
  [';', '&', TokenType.semiAnd],
  ['|', '&', TokenType.pipeAmp],
  ['>', '>', TokenType.dgreat],
  ['<', '&', TokenType.lessand],
  ['>', '&', TokenType.greatand],
  ['<', '>', TokenType.lessgreat],
  ['>', '|', TokenType.clobber],
  ['&', '>', TokenType.andGreat],
];

const Map<String, TokenType> _singleCharOps = {
  '|': TokenType.pipe,
  '&': TokenType.amp,
  ';': TokenType.semicolon,
  '(': TokenType.lparen,
  ')': TokenType.rparen,
  '<': TokenType.less,
  '>': TokenType.great,
};

class _PendingHeredoc {
  // Positional flags mirror the upstream record shape.
  // ignore: avoid_positional_boolean_parameters
  _PendingHeredoc(this.delimiter, this.stripTabs, this.quoted);
  final String delimiter;
  final bool stripTabs;
  final bool quoted;
}

/// Read a here-doc delimiter starting at [pos] in [value]. Returns the
/// delimiter text and the end position.
({String delim, int endPos}) readHeredocDelimiter(String value, int pos) {
  var delim = '';
  var i = pos;
  bool isWordEnd(String c) =>
      c == ' ' ||
      c == '\t' ||
      c == '\n' ||
      c == ';' ||
      c == '&' ||
      c == '|' ||
      c == '<' ||
      c == '>' ||
      c == '(' ||
      c == ')';
  while (i < value.length) {
    final c = value[i];
    if (c == "'") {
      i++;
      while (i < value.length && value[i] != "'") {
        delim += value[i];
        i++;
      }
      if (i < value.length) i++;
      continue;
    }
    if (c == '"') {
      i++;
      while (i < value.length && value[i] != '"') {
        if (value[i] == r'\' && i + 1 < value.length) {
          i++;
        }
        delim += value[i];
        i++;
      }
      if (i < value.length) i++;
      continue;
    }
    if (c == r'\' && i + 1 < value.length) {
      delim += value[i + 1];
      i += 2;
      continue;
    }
    if (isWordEnd(c)) break;
    delim += c;
    i++;
  }
  return (delim: delim, endPos: i);
}

/// The bash lexer.
class Lexer {
  /// Creates a lexer over [input] with optional [options].
  Lexer(this.input, {LexerOptions? options})
      : _maxHeredocSize = options?.maxHeredocSize ?? _defaultMaxHeredocSize;

  /// The input being tokenized.
  final String input;
  int _pos = 0;
  int _line = 1;
  int _column = 1;
  final List<Token> _tokens = [];
  final List<_PendingHeredoc> _pendingHeredocs = [];
  int _dparenDepth = 0;
  final int _maxHeredocSize;

  /// Tokenize the entire input and return the token list (ending in EOF).
  List<Token> tokenize() {
    final len = input.length;

    while (_pos < len) {
      if (_pendingHeredocs.isNotEmpty &&
          _tokens.isNotEmpty &&
          _tokens.last.type == TokenType.newline) {
        _readHeredocContent();
        continue;
      }

      _skipWhitespace();
      if (_pos >= len) break;

      final token = _nextToken();
      if (token != null) _tokens.add(token);
    }

    _tokens.add(Token(
      type: TokenType.eof,
      value: '',
      start: _pos,
      end: _pos,
      line: _line,
      column: _column,
    ));
    return _tokens;
  }

  void _skipWhitespace() {
    final len = input.length;
    var pos = _pos;
    var col = _column;
    var ln = _line;
    while (pos < len) {
      final char = input[pos];
      if (char == ' ' || char == '\t') {
        pos++;
        col++;
      } else if (char == r'\' && _charAt(input, pos + 1) == '\n') {
        pos += 2;
        ln++;
        col = 1;
      } else {
        break;
      }
    }
    _pos = pos;
    _column = col;
    _line = ln;
  }

  Token _make(TokenType type, String value, int start, int line, int column) {
    return Token(
      type: type,
      value: value,
      start: start,
      end: _pos,
      line: line,
      column: column,
    );
  }

  Token? _nextToken() {
    final pos = _pos;
    final startLine = _line;
    final startColumn = _column;
    final c0 = _charAt(input, pos);
    final c1 = _charAt(input, pos + 1);
    final c2 = _charAt(input, pos + 2);

    if (c0 == '#' && _dparenDepth == 0) {
      return _readComment(pos, startLine, startColumn);
    }

    if (c0 == '\n') {
      _pos = pos + 1;
      _line++;
      _column = 1;
      return Token(
        type: TokenType.newline,
        value: '\n',
        start: pos,
        end: pos + 1,
        line: startLine,
        column: startColumn,
      );
    }

    if (c0 == '<' && c1 == '<' && c2 == '-') {
      _pos = pos + 3;
      _column = startColumn + 3;
      _registerHeredocFromLookahead(stripTabs: true);
      return _make(TokenType.dlessdash, '<<-', pos, startLine, startColumn);
    }
    for (final op in _threeCharOps) {
      if (c0 == op[0] && c1 == op[1] && c2 == op[2]) {
        _pos = pos + 3;
        _column = startColumn + 3;
        return _make(
          op[3] as TokenType,
          '${op[0]}${op[1]}${op[2]}',
          pos,
          startLine,
          startColumn,
        );
      }
    }

    if (c0 == '<' && c1 == '<') {
      _pos = pos + 2;
      _column = startColumn + 2;
      _registerHeredocFromLookahead(stripTabs: false);
      return _make(TokenType.dless, '<<', pos, startLine, startColumn);
    }

    if (c0 == '(' && c1 == '(') {
      if (_dparenDepth > 0) {
        _pos = pos + 1;
        _column = startColumn + 1;
        _dparenDepth++;
        return _make(TokenType.lparen, '(', pos, startLine, startColumn);
      }
      if (_looksLikeNestedSubshells(pos + 2) ||
          _dparenClosesWithSpacedParens(pos + 2)) {
        _pos = pos + 1;
        _column = startColumn + 1;
        return _make(TokenType.lparen, '(', pos, startLine, startColumn);
      }
      _pos = pos + 2;
      _column = startColumn + 2;
      _dparenDepth = 1;
      return _make(TokenType.dparenStart, '((', pos, startLine, startColumn);
    }
    if (c0 == ')' && c1 == ')') {
      if (_dparenDepth == 1) {
        _pos = pos + 2;
        _column = startColumn + 2;
        _dparenDepth = 0;
        return _make(TokenType.dparenEnd, '))', pos, startLine, startColumn);
      } else if (_dparenDepth > 1) {
        _pos = pos + 1;
        _column = startColumn + 1;
        _dparenDepth--;
        return _make(TokenType.rparen, ')', pos, startLine, startColumn);
      }
      _pos = pos + 1;
      _column = startColumn + 1;
      return _make(TokenType.rparen, ')', pos, startLine, startColumn);
    }

    for (final op in _twoCharOps) {
      final first = op[0] as String;
      final second = op[1] as String;
      final type = op[2] as TokenType;
      if ((first == '(' && second == '(') ||
          (first == ')' && second == ')')) {
        continue;
      }
      if (_dparenDepth > 0 &&
          first == ';' &&
          (type == TokenType.dsemi ||
              type == TokenType.semiAnd ||
              type == TokenType.semiSemiAnd)) {
        continue;
      }
      if (c0 == first && c1 == second) {
        if (type == TokenType.dbrackStart || type == TokenType.dbrackEnd) {
          final afterOp = _charAt(input, pos + 2);
          if (afterOp != '' &&
              afterOp != ' ' &&
              afterOp != '\t' &&
              afterOp != '\n' &&
              afterOp != ';' &&
              afterOp != '&' &&
              afterOp != '|' &&
              afterOp != '(' &&
              afterOp != ')' &&
              afterOp != '<' &&
              afterOp != '>') {
            break;
          }
        }
        _pos = pos + 2;
        _column = startColumn + 2;
        return _make(type, '$first$second', pos, startLine, startColumn);
      }
    }

    if (c0 == '(' && _dparenDepth > 0) {
      _pos = pos + 1;
      _column = startColumn + 1;
      _dparenDepth++;
      return _make(TokenType.lparen, '(', pos, startLine, startColumn);
    }
    if (c0 == ')' && _dparenDepth > 1) {
      _pos = pos + 1;
      _column = startColumn + 1;
      _dparenDepth--;
      return _make(TokenType.rparen, ')', pos, startLine, startColumn);
    }
    final singleCharType = _singleCharOps[c0];
    if (singleCharType != null) {
      _pos = pos + 1;
      _column = startColumn + 1;
      return _make(singleCharType, c0, pos, startLine, startColumn);
    }

    if (c0 == '{') {
      final fdVarResult = _scanFdVariable(pos);
      if (fdVarResult != null) {
        _pos = fdVarResult.end;
        _column = startColumn + (fdVarResult.end - pos);
        return Token(
          type: TokenType.fdVariable,
          value: fdVarResult.varname,
          start: pos,
          end: fdVarResult.end,
          line: startLine,
          column: startColumn,
        );
      }
      if (c1 == '}') {
        _pos = pos + 2;
        _column = startColumn + 2;
        return Token(
          type: TokenType.word,
          value: '{}',
          start: pos,
          end: pos + 2,
          line: startLine,
          column: startColumn,
        );
      }
      final braceContent = _scanBraceExpansion(pos);
      if (braceContent != null) {
        return _readWordWithBraceExpansion(pos, startLine, startColumn);
      }
      final literalBrace = _scanLiteralBraceWord(pos);
      if (literalBrace != null) {
        return _readWordWithBraceExpansion(pos, startLine, startColumn);
      }
      if (c1 != '' && c1 != ' ' && c1 != '\t' && c1 != '\n') {
        return _readWord(pos, startLine, startColumn);
      }
      _pos = pos + 1;
      _column = startColumn + 1;
      return _make(TokenType.lbrace, '{', pos, startLine, startColumn);
    }
    if (c0 == '}') {
      if (_isWordCharFollowing(pos + 1)) {
        return _readWord(pos, startLine, startColumn);
      }
      _pos = pos + 1;
      _column = startColumn + 1;
      return _make(TokenType.rbrace, '}', pos, startLine, startColumn);
    }
    if (c0 == '!') {
      if (c1 == '=') {
        _pos = pos + 2;
        _column = startColumn + 2;
        return _make(TokenType.word, '!=', pos, startLine, startColumn);
      }
      _pos = pos + 1;
      _column = startColumn + 1;
      return _make(TokenType.bang, '!', pos, startLine, startColumn);
    }

    return _readWord(pos, startLine, startColumn);
  }

  bool _looksLikeNestedSubshells(int startPos) {
    final len = input.length;
    var pos = startPos;
    while (pos < len && (input[pos] == ' ' || input[pos] == '\t')) {
      pos++;
    }
    if (pos >= len) return false;
    final c = input[pos];
    if (c == '(') return _looksLikeNestedSubshells(pos + 1);

    final isLetter = _letterRe.hasMatch(c);
    final isSpecialCommand = c == '!' || c == '[';
    if (!isLetter && !isSpecialCommand) return false;

    var wordEnd = pos;
    while (wordEnd < len && _wordCharRe.hasMatch(input[wordEnd])) {
      wordEnd++;
    }
    if (wordEnd == pos) return isSpecialCommand;

    var afterWord = wordEnd;
    while (afterWord < len &&
        (input[afterWord] == ' ' || input[afterWord] == '\t')) {
      afterWord++;
    }
    if (afterWord >= len) return false;
    final nextChar = input[afterWord];

    if (nextChar == '=' && _charAt(input, afterWord + 1) != '=') return false;
    if (nextChar == '\n') return false;
    if (wordEnd == afterWord &&
        _arithOpRe.hasMatch(nextChar) &&
        nextChar != '-') {
      return false;
    }
    if (nextChar == ')' && _charAt(input, afterWord + 1) == ')') return false;

    if (afterWord > wordEnd &&
        (nextChar == '-' ||
            nextChar == '"' ||
            nextChar == "'" ||
            nextChar == r'$' ||
            _cmdStartRe.hasMatch(nextChar))) {
      var scanPos = afterWord;
      while (scanPos < len && input[scanPos] != '\n') {
        if (input[scanPos] == ')') return true;
        scanPos++;
      }
      return false;
    }

    if (nextChar == ')') {
      var afterParen = afterWord + 1;
      while (afterParen < len &&
          (input[afterParen] == ' ' || input[afterParen] == '\t')) {
        afterParen++;
      }
      if ((_charAt(input, afterParen) == '|' &&
              _charAt(input, afterParen + 1) == '|') ||
          (_charAt(input, afterParen) == '&' &&
              _charAt(input, afterParen + 1) == '&') ||
          _charAt(input, afterParen) == ';' ||
          (_charAt(input, afterParen) == '|' &&
              _charAt(input, afterParen + 1) != '|')) {
        return true;
      }
    }
    return false;
  }

  Token _readComment(int start, int line, int column) {
    final len = input.length;
    var pos = _pos;
    while (pos < len && input[pos] != '\n') {
      pos++;
    }
    final value = _slice(input, start, pos);
    _pos = pos;
    _column = column + (pos - start);
    return Token(
      type: TokenType.comment,
      value: value,
      start: start,
      end: pos,
      line: line,
      column: column,
    );
  }

  Token _readWord(int start, int line, int column) {
    final len = input.length;
    var pos = _pos;

    final fastStart = pos;
    while (pos < len) {
      final c = input[pos];
      if (c == ' ' ||
          c == '\t' ||
          c == '\n' ||
          c == ';' ||
          c == '&' ||
          c == '|' ||
          c == '(' ||
          c == ')' ||
          c == '<' ||
          c == '>' ||
          c == "'" ||
          c == '"' ||
          c == r'\' ||
          c == r'$' ||
          c == '`' ||
          c == '{' ||
          c == '}' ||
          c == '~' ||
          c == '*' ||
          c == '?' ||
          c == '[') {
        break;
      }
      pos++;
    }

    if (pos > fastStart) {
      final c = _charAt(input, pos);
      if (c == '(' &&
          pos > fastStart &&
          '@*+?!'.contains(input[pos - 1])) {
        // Extglob pattern - fall through to slow path.
      } else if (pos >= len ||
          c == ' ' ||
          c == '\t' ||
          c == '\n' ||
          c == ';' ||
          c == '&' ||
          c == '|' ||
          c == '(' ||
          c == ')' ||
          c == '<' ||
          c == '>') {
        final value = _slice(input, fastStart, pos);
        _pos = pos;
        _column = column + (pos - fastStart);

        final reservedType = reservedWords[value];
        if (reservedType != null) {
          return Token(
            type: reservedType,
            value: value,
            start: start,
            end: pos,
            line: line,
            column: column,
          );
        }

        final eqIdx = _findAssignmentEq(value);
        if (eqIdx > 0 &&
            _isValidAssignmentLHS(value.substring(0, eqIdx))) {
          return Token(
            type: TokenType.assignmentWord,
            value: value,
            start: start,
            end: pos,
            line: line,
            column: column,
          );
        }

        if (_digitsRe.hasMatch(value)) {
          return Token(
            type: TokenType.number,
            value: value,
            start: start,
            end: pos,
            line: line,
            column: column,
          );
        }

        if (_nameRe.hasMatch(value)) {
          return Token(
            type: TokenType.name,
            value: value,
            start: start,
            end: pos,
            line: line,
            column: column,
          );
        }

        return Token(
          type: TokenType.word,
          value: value,
          start: start,
          end: pos,
          line: line,
          column: column,
        );
      }
    }

    // Slow path.
    pos = _pos;
    var col = _column;
    var ln = _line;

    var value = '';
    var quoted = false;
    var singleQuoted = false;
    var inSingleQuote = false;
    var inDoubleQuote = false;
    var startsWithQuote =
        _charAt(input, pos) == '"' || _charAt(input, pos) == "'";
    var hasContentAfterQuote = false;
    var bracketDepth = 0;

    while (pos < len) {
      final char = input[pos];

      if (!inSingleQuote && !inDoubleQuote) {
        if (char == '(' &&
            value.isNotEmpty &&
            '@*+?!'.contains(value[value.length - 1])) {
          final extglobResult = _scanExtglobPattern(pos);
          if (extglobResult != null) {
            value += extglobResult.content;
            pos = extglobResult.end;
            col += extglobResult.content.length;
            continue;
          }
        }
        if (char == '[' && bracketDepth == 0) {
          if (_nameRe.hasMatch(value)) {
            final afterBracket = pos + 1 < len ? input[pos + 1] : '';
            if (afterBracket == '^' || afterBracket == '!') {
              value += char;
              pos++;
              col++;
              continue;
            }
            bracketDepth = 1;
            value += char;
            pos++;
            col++;
            continue;
          }
        } else if (char == '[' && bracketDepth > 0) {
          if (value.isNotEmpty && value[value.length - 1] != r'\') {
            bracketDepth++;
          }
          value += char;
          pos++;
          col++;
          continue;
        } else if (char == ']' && bracketDepth > 0) {
          if (value.isNotEmpty && value[value.length - 1] != r'\') {
            bracketDepth--;
          }
          value += char;
          pos++;
          col++;
          continue;
        }

        if (bracketDepth > 0) {
          if (char == '\n') break;
          value += char;
          pos++;
          col++;
          continue;
        }

        if (char == ' ' ||
            char == '\t' ||
            char == '\n' ||
            char == ';' ||
            char == '&' ||
            char == '|' ||
            char == '(' ||
            char == ')' ||
            char == '<' ||
            char == '>') {
          break;
        }
      }

      // $'' ANSI-C quoting.
      if (char == r'$' &&
          pos + 1 < len &&
          input[pos + 1] == "'" &&
          !inSingleQuote &&
          !inDoubleQuote) {
        value += r"$'";
        pos += 2;
        col += 2;
        while (pos < len && input[pos] != "'") {
          if (input[pos] == r'\' && pos + 1 < len) {
            value += input[pos] + input[pos + 1];
            pos += 2;
            col += 2;
          } else {
            value += input[pos];
            pos++;
            col++;
          }
        }
        if (pos < len) {
          value += "'";
          pos++;
          col++;
        }
        continue;
      }

      // $"..." locale quoting.
      if (char == r'$' &&
          pos + 1 < len &&
          input[pos + 1] == '"' &&
          !inSingleQuote &&
          !inDoubleQuote) {
        pos++;
        col++;
        inDoubleQuote = true;
        quoted = true;
        if (value == '') startsWithQuote = true;
        pos++;
        col++;
        continue;
      }

      if (char == "'" && !inDoubleQuote) {
        if (inSingleQuote) {
          inSingleQuote = false;
          if (!startsWithQuote || hasContentAfterQuote) {
            value += char;
          } else {
            final nextChar = pos + 1 < len ? input[pos + 1] : '';
            if (nextChar != '' &&
                !_isWordBoundary(nextChar) &&
                nextChar != "'") {
              if (nextChar == '"') {
                hasContentAfterQuote = true;
                value += char;
                singleQuoted = false;
                quoted = false;
              } else {
                hasContentAfterQuote = true;
                value += char;
              }
            }
          }
        } else {
          inSingleQuote = true;
          if (startsWithQuote && !hasContentAfterQuote) {
            singleQuoted = true;
            quoted = true;
          } else {
            value += char;
          }
        }
        pos++;
        col++;
        continue;
      }

      if (char == '"' && !inSingleQuote) {
        if (inDoubleQuote) {
          inDoubleQuote = false;
          if (!startsWithQuote || hasContentAfterQuote) {
            value += char;
          } else {
            final nextChar = pos + 1 < len ? input[pos + 1] : '';
            if (nextChar != '' &&
                !_isWordBoundary(nextChar) &&
                nextChar != '"') {
              if (nextChar == "'") {
                hasContentAfterQuote = true;
                value += char;
                singleQuoted = false;
                quoted = false;
              } else {
                hasContentAfterQuote = true;
                value += char;
              }
            }
          }
        } else {
          inDoubleQuote = true;
          if (startsWithQuote && !hasContentAfterQuote) {
            quoted = true;
          } else {
            value += char;
          }
        }
        pos++;
        col++;
        continue;
      }

      // Escapes.
      if (char == r'\' && !inSingleQuote && pos + 1 < len) {
        final nextChar = input[pos + 1];
        if (nextChar == '\n') {
          pos += 2;
          ln++;
          col = 1;
          continue;
        }
        if (inDoubleQuote) {
          if (nextChar == '"' ||
              nextChar == r'\' ||
              nextChar == r'$' ||
              nextChar == '`' ||
              nextChar == '\n') {
            if (nextChar == '\n') {
              pos += 2;
              col = 1;
              ln++;
              continue;
            }
            value += char + nextChar;
            pos += 2;
            col += 2;
            continue;
          }
        } else {
          if (nextChar == r'\' ||
              nextChar == '"' ||
              nextChar == "'" ||
              nextChar == '`' ||
              nextChar == '*' ||
              nextChar == '?' ||
              nextChar == '[' ||
              nextChar == ']' ||
              nextChar == '(' ||
              nextChar == ')' ||
              nextChar == r'$' ||
              nextChar == '-' ||
              nextChar == '.' ||
              nextChar == '^' ||
              nextChar == '+' ||
              nextChar == '{' ||
              nextChar == '}') {
            value += char + nextChar;
          } else {
            value += nextChar;
          }
          pos += 2;
          col += 2;
          continue;
        }
      }

      // $(...) command substitution.
      if (char == r'$' &&
          pos + 1 < len &&
          input[pos + 1] == '(' &&
          !inSingleQuote) {
        value += char;
        pos++;
        col++;
        value += input[pos];
        pos++;
        col++;
        var depth = 1;
        var csSingle = false;
        var csDouble = false;
        var caseDepth = 0;
        var inCasePattern = false;
        var wordBuffer = '';
        final csHeredocs = <({String delim, bool stripTabs})>[];
        final isArithmetic =
            input[pos] == '(' && !_dollarDparenIsSubshell(pos);
        var arithDepth = isArithmetic ? 1 : 0;
        while (depth > 0 && pos < len) {
          final c = input[pos];
          value += c;

          if (csSingle) {
            if (c == "'") csSingle = false;
          } else if (csDouble) {
            if (c == r'\' && pos + 1 < len) {
              value += input[pos + 1];
              pos++;
              col++;
            } else if (c == '"') {
              csDouble = false;
            }
          } else {
            if (c == '(' && _charAt(input, pos + 1) == '(') {
              arithDepth++;
            } else if (c == ')' &&
                _charAt(input, pos + 1) == ')' &&
                arithDepth > 0) {
              arithDepth--;
            }

            if (arithDepth == 0 &&
                c == '<' &&
                _charAt(input, pos + 1) == '<' &&
                _charAt(input, pos + 2) != '<') {
              var p = pos + 2;
              var stripTabs = false;
              if (_charAt(input, p) == '-') {
                stripTabs = true;
                p++;
              }
              while (_charAt(input, p) == ' ' || _charAt(input, p) == '\t') {
                p++;
              }
              final hd = readHeredocDelimiter(input, p);
              if (hd.delim.isNotEmpty) {
                value += _slice(input, pos + 1, hd.endPos);
                col += hd.endPos - pos;
                csHeredocs.add((delim: hd.delim, stripTabs: stripTabs));
                pos = hd.endPos;
                continue;
              }
            }

            if (c == '\n' && csHeredocs.isNotEmpty) {
              ln++;
              col = 0;
              var bodyPos = pos + 1;
              for (final h in csHeredocs) {
                while (true) {
                  if (bodyPos >= len) break;
                  var lineEnd = input.indexOf('\n', bodyPos);
                  if (lineEnd == -1) lineEnd = len;
                  final rawLine = _slice(input, bodyPos, lineEnd);
                  final cmp = h.stripTabs
                      ? rawLine.replaceFirst(_leadingTabsRe, '')
                      : rawLine;
                  value += _slice(input, bodyPos, lineEnd + 1 < len
                      ? lineEnd + 1
                      : len);
                  if (lineEnd < len) ln++;
                  final reachedEnd = lineEnd >= len;
                  bodyPos = lineEnd + 1;
                  if (cmp == h.delim || reachedEnd) break;
                }
              }
              csHeredocs.clear();
              col = 0;
              pos = bodyPos < len ? bodyPos : len;
              continue;
            }

            if (c == "'") {
              csSingle = true;
              wordBuffer = '';
            } else if (c == '"') {
              csDouble = true;
              wordBuffer = '';
            } else if (c == r'\' && pos + 1 < len) {
              value += input[pos + 1];
              pos++;
              col++;
              wordBuffer = '';
            } else if (c == r'$' &&
                pos + 1 < len &&
                input[pos + 1] == '{') {
              pos++;
              col++;
              value += input[pos];
              pos++;
              col++;
              var braceDepth = 1;
              var inBraceSingleQuote = false;
              var inBraceDoubleQuote = false;
              while (braceDepth > 0 && pos < len) {
                final bc = input[pos];
                if (bc == r'\' && pos + 1 < len && !inBraceSingleQuote) {
                  value += bc;
                  pos++;
                  col++;
                  value += input[pos];
                  pos++;
                  col++;
                  continue;
                }
                value += bc;
                if (inBraceSingleQuote) {
                  if (bc == "'") inBraceSingleQuote = false;
                } else if (inBraceDoubleQuote) {
                  if (bc == '"') inBraceDoubleQuote = false;
                } else {
                  if (bc == "'") {
                    inBraceSingleQuote = true;
                  } else if (bc == '"') {
                    inBraceDoubleQuote = true;
                  } else if (bc == '{') {
                    braceDepth++;
                  } else if (bc == '}') {
                    braceDepth--;
                  }
                }
                if (bc == '\n') {
                  ln++;
                  col = 0;
                } else {
                  col++;
                }
                pos++;
              }
              wordBuffer = '';
              continue;
            } else if (c == '#' &&
                !isArithmetic &&
                (wordBuffer == '' || _wsRe.hasMatch(_charAt(input, pos - 1)))) {
              while (pos + 1 < len && input[pos + 1] != '\n') {
                pos++;
                col++;
                value += input[pos];
              }
              wordBuffer = '';
            } else if (_letterRe.hasMatch(c)) {
              wordBuffer += c;
            } else {
              if (wordBuffer == 'case') {
                caseDepth++;
                inCasePattern = false;
              } else if (wordBuffer == 'in' && caseDepth > 0) {
                inCasePattern = true;
              } else if (wordBuffer == 'esac' && caseDepth > 0) {
                caseDepth--;
                inCasePattern = false;
              }
              wordBuffer = '';

              if (c == '(') {
                if (pos > 0 && input[pos - 1] == r'$') {
                  depth++;
                } else if (!inCasePattern) {
                  depth++;
                }
              } else if (c == ')') {
                if (inCasePattern) {
                  inCasePattern = false;
                } else {
                  depth--;
                }
              } else if (c == ';') {
                if (caseDepth > 0) {
                  if (pos + 1 < len && input[pos + 1] == ';') {
                    inCasePattern = true;
                  } else if (pos + 1 < len && input[pos + 1] == '&') {
                    inCasePattern = true;
                  }
                }
              }
            }
          }

          if (c == '\n') {
            ln++;
            col = 0;
            wordBuffer = '';
          }
          pos++;
          col++;
        }
        continue;
      }

      // $[...] old-style arithmetic.
      if (char == r'$' &&
          pos + 1 < len &&
          input[pos + 1] == '[' &&
          !inSingleQuote) {
        value += char;
        pos++;
        col++;
        value += input[pos];
        pos++;
        col++;
        var depth = 1;
        while (depth > 0 && pos < len) {
          final c = input[pos];
          value += c;
          if (c == '[') {
            depth++;
          } else if (c == ']') {
            depth--;
          } else if (c == '\n') {
            ln++;
            col = 0;
          }
          pos++;
          col++;
        }
        continue;
      }

      // ${...} parameter expansion.
      if (char == r'$' &&
          pos + 1 < len &&
          input[pos + 1] == '{' &&
          !inSingleQuote) {
        value += char;
        pos++;
        col++;
        value += input[pos];
        pos++;
        col++;
        var depth = 1;
        var inParamSingleQuote = false;
        var inParamDoubleQuote = false;
        var singleQuoteStartLine = ln;
        var singleQuoteStartCol = col;
        var doubleQuoteStartLine = ln;
        var doubleQuoteStartCol = col;
        while (depth > 0 && pos < len) {
          final c = input[pos];
          if (c == r'\' && pos + 1 < len && input[pos + 1] == '\n') {
            pos += 2;
            ln++;
            col = 1;
            continue;
          }
          if (c == r'\' && pos + 1 < len && !inParamSingleQuote) {
            value += c;
            pos++;
            col++;
            value += input[pos];
            pos++;
            col++;
            continue;
          }
          value += c;
          if (inParamSingleQuote) {
            if (c == "'") inParamSingleQuote = false;
          } else if (inParamDoubleQuote) {
            if (c == '"') inParamDoubleQuote = false;
          } else {
            if (c == "'") {
              inParamSingleQuote = true;
              singleQuoteStartLine = ln;
              singleQuoteStartCol = col;
            } else if (c == '"') {
              inParamDoubleQuote = true;
              doubleQuoteStartLine = ln;
              doubleQuoteStartCol = col;
            } else if (c == '{') {
              depth++;
            } else if (c == '}') {
              depth--;
            }
          }
          if (c == '\n') {
            ln++;
            col = 0;
          }
          pos++;
          col++;
        }
        if (inParamSingleQuote) {
          throw LexerError(
            "unexpected EOF while looking for matching `''",
            singleQuoteStartLine,
            singleQuoteStartCol,
          );
        }
        if (inParamDoubleQuote) {
          throw LexerError(
            'unexpected EOF while looking for matching `"\'',
            doubleQuoteStartLine,
            doubleQuoteStartCol,
          );
        }
        continue;
      }

      // Special variables $#, $?, $$, $!, $0-$9, $@, $*, $-.
      if (char == r'$' && pos + 1 < len && !inSingleQuote) {
        final next = input[pos + 1];
        if (next == '#' ||
            next == '?' ||
            next == r'$' ||
            next == '!' ||
            next == '@' ||
            next == '*' ||
            next == '-' ||
            (next.compareTo('0') >= 0 && next.compareTo('9') <= 0)) {
          value += char + next;
          pos += 2;
          col += 2;
          continue;
        }
      }

      // Backtick command substitution.
      if (char == '`' && !inSingleQuote) {
        value += char;
        pos++;
        col++;
        while (pos < len && input[pos] != '`') {
          final c = input[pos];
          value += c;
          if (c == r'\' && pos + 1 < len) {
            value += input[pos + 1];
            pos++;
            col++;
          }
          if (c == '\n') {
            ln++;
            col = 0;
          }
          pos++;
          col++;
        }
        if (pos < len) {
          value += input[pos];
          pos++;
          col++;
        }
        continue;
      }

      // Regular character.
      value += char;
      pos++;
      if (char == '\n') {
        ln++;
        col = 1;
      } else {
        col++;
      }
    }

    _pos = pos;
    _column = col;
    _line = ln;

    if (hasContentAfterQuote && startsWithQuote) {
      final openQuote = input[start];
      value = openQuote + value;
      quoted = false;
      singleQuoted = false;
    }

    if (inSingleQuote || inDoubleQuote) {
      final quoteType = inSingleQuote ? "'" : '"';
      throw LexerError(
        "unexpected EOF while looking for matching `$quoteType'",
        line,
        column,
      );
    }

    if (!startsWithQuote && value.length >= 2) {
      if (value[0] == "'" && value[value.length - 1] == "'") {
        final inner = value.substring(1, value.length - 1);
        if (!inner.contains("'") && !inner.contains('"')) {
          value = inner;
          quoted = true;
          singleQuoted = true;
        }
      } else if (value[0] == '"' && value[value.length - 1] == '"') {
        final inner = value.substring(1, value.length - 1);
        var hasUnescapedQuote = false;
        for (var i = 0; i < inner.length; i++) {
          if (inner[i] == '"') {
            hasUnescapedQuote = true;
            break;
          }
          if (inner[i] == r'\' && i + 1 < inner.length) {
            i++;
          }
        }
        if (!hasUnescapedQuote) {
          value = inner;
          quoted = true;
          singleQuoted = false;
        }
      }
    }

    if (value == '') {
      return Token(
        type: TokenType.word,
        value: '',
        start: start,
        end: pos,
        line: line,
        column: column,
        quoted: quoted,
        singleQuoted: singleQuoted,
      );
    }

    final reservedType2 = reservedWords[value];
    if (!quoted && reservedType2 != null) {
      return Token(
        type: reservedType2,
        value: value,
        start: start,
        end: pos,
        line: line,
        column: column,
      );
    }

    if (!startsWithQuote) {
      final eqIdx = _findAssignmentEq(value);
      if (eqIdx > 0 && _isValidAssignmentLHS(value.substring(0, eqIdx))) {
        return Token(
          type: TokenType.assignmentWord,
          value: value,
          start: start,
          end: pos,
          line: line,
          column: column,
          quoted: quoted,
          singleQuoted: singleQuoted,
        );
      }
    }

    if (_digitsRe.hasMatch(value)) {
      return Token(
        type: TokenType.number,
        value: value,
        start: start,
        end: pos,
        line: line,
        column: column,
      );
    }

    if (_isValidName(value)) {
      return Token(
        type: TokenType.name,
        value: value,
        start: start,
        end: pos,
        line: line,
        column: column,
        quoted: quoted,
        singleQuoted: singleQuoted,
      );
    }

    return Token(
      type: TokenType.word,
      value: value,
      start: start,
      end: pos,
      line: line,
      column: column,
      quoted: quoted,
      singleQuoted: singleQuoted,
    );
  }

  void _readHeredocContent() {
    while (_pendingHeredocs.isNotEmpty) {
      final heredoc = _pendingHeredocs.removeAt(0);
      final start = _pos;
      final startLine = _line;
      final startColumn = _column;
      var content = '';

      while (_pos < input.length) {
        var line = '';
        while (_pos < input.length && input[_pos] != '\n') {
          line += input[_pos];
          _pos++;
          _column++;
        }

        final lineToCheck =
            heredoc.stripTabs ? line.replaceFirst(_leadingTabsRe, '') : line;
        if (lineToCheck == heredoc.delimiter) {
          if (_pos < input.length && input[_pos] == '\n') {
            _pos++;
            _line++;
            _column = 1;
          }
          break;
        }

        content += line;
        if (content.length > _maxHeredocSize) {
          throw LexerError(
            'Heredoc size limit exceeded ($_maxHeredocSize bytes)',
            startLine,
            startColumn,
          );
        }
        if (_pos < input.length && input[_pos] == '\n') {
          content += '\n';
          _pos++;
          _line++;
          _column = 1;
        }
      }

      _tokens.add(Token(
        type: TokenType.heredocContent,
        value: content,
        start: start,
        end: _pos,
        line: startLine,
        column: startColumn,
      ));
    }
  }

  /// Register a here-document to be read after the next newline.
  // Signature mirrors the upstream Lexer.addPendingHeredoc method.
  // ignore: avoid_positional_boolean_parameters
  void addPendingHeredoc(String delimiter, bool stripTabs, bool quoted) {
    _pendingHeredocs.add(_PendingHeredoc(delimiter, stripTabs, quoted));
  }

  void _registerHeredocFromLookahead({required bool stripTabs}) {
    final savedPos = _pos;
    final savedColumn = _column;

    while (_pos < input.length &&
        (input[_pos] == ' ' || input[_pos] == '\t')) {
      _pos++;
      _column++;
    }

    var delimiter = '';
    var quoted = false;

    while (_pos < input.length) {
      final char = input[_pos];
      if (_delimEndRe.hasMatch(char)) break;

      if (char == "'" || char == '"') {
        quoted = true;
        final quoteChar = char;
        _pos++;
        _column++;
        while (_pos < input.length && input[_pos] != quoteChar) {
          delimiter += input[_pos];
          _pos++;
          _column++;
        }
        if (_pos < input.length && input[_pos] == quoteChar) {
          _pos++;
          _column++;
        }
      } else if (char == r'\') {
        quoted = true;
        _pos++;
        _column++;
        if (_pos < input.length) {
          delimiter += input[_pos];
          _pos++;
          _column++;
        }
      } else {
        delimiter += char;
        _pos++;
        _column++;
      }
    }

    _pos = savedPos;
    _column = savedColumn;

    if (delimiter.isNotEmpty) {
      _pendingHeredocs.add(_PendingHeredoc(delimiter, stripTabs, quoted));
    }
  }

  bool _isWordCharFollowing(int pos) {
    if (pos >= input.length) return false;
    final c = input[pos];
    return !(c == ' ' ||
        c == '\t' ||
        c == '\n' ||
        c == ';' ||
        c == '&' ||
        c == '|' ||
        c == '(' ||
        c == ')' ||
        c == '<' ||
        c == '>');
  }

  Token _readWordWithBraceExpansion(int start, int line, int column) {
    final len = input.length;
    var pos = start;
    var col = column;

    while (pos < len) {
      final c = input[pos];
      if (c == ' ' ||
          c == '\t' ||
          c == '\n' ||
          c == ';' ||
          c == '&' ||
          c == '|' ||
          c == '(' ||
          c == ')' ||
          c == '<' ||
          c == '>') {
        break;
      }

      if (c == '{') {
        final braceExp = _scanBraceExpansion(pos);
        if (braceExp != null) {
          var depth = 1;
          pos++;
          col++;
          while (pos < len && depth > 0) {
            if (input[pos] == '{') {
              depth++;
            } else if (input[pos] == '}') {
              depth--;
            }
            pos++;
            col++;
          }
          continue;
        }
        pos++;
        col++;
        continue;
      }

      if (c == '}') {
        pos++;
        col++;
        continue;
      }

      if (c == r'$' && pos + 1 < len && input[pos + 1] == '(') {
        pos++;
        col++;
        pos++;
        col++;
        var depth = 1;
        while (depth > 0 && pos < len) {
          if (input[pos] == '(') {
            depth++;
          } else if (input[pos] == ')') {
            depth--;
          }
          pos++;
          col++;
        }
        continue;
      }

      if (c == r'$' && pos + 1 < len && input[pos + 1] == '{') {
        pos++;
        col++;
        pos++;
        col++;
        var depth = 1;
        while (depth > 0 && pos < len) {
          if (input[pos] == '{') {
            depth++;
          } else if (input[pos] == '}') {
            depth--;
          }
          pos++;
          col++;
        }
        continue;
      }

      if (c == '`') {
        pos++;
        col++;
        while (pos < len && input[pos] != '`') {
          if (input[pos] == r'\' && pos + 1 < len) {
            pos += 2;
            col += 2;
          } else {
            pos++;
            col++;
          }
        }
        if (pos < len) {
          pos++;
          col++;
        }
        continue;
      }

      pos++;
      col++;
    }

    final value = _slice(input, start, pos);
    _pos = pos;
    _column = col;
    return Token(
      type: TokenType.word,
      value: value,
      start: start,
      end: pos,
      line: line,
      column: column,
    );
  }

  String? _scanBraceExpansion(int startPos) {
    final len = input.length;
    var pos = startPos + 1;
    var depth = 1;
    var hasComma = false;
    var hasRange = false;

    while (pos < len && depth > 0) {
      final c = input[pos];
      if (c == '{') {
        depth++;
        pos++;
      } else if (c == '}') {
        depth--;
        pos++;
      } else if (c == ',' && depth == 1) {
        hasComma = true;
        pos++;
      } else if (c == '.' && pos + 1 < len && input[pos + 1] == '.') {
        hasRange = true;
        pos += 2;
      } else if (c == ' ' ||
          c == '\t' ||
          c == '\n' ||
          c == ';' ||
          c == '&' ||
          c == '|') {
        return null;
      } else {
        pos++;
      }
    }

    if (depth == 0 && (hasComma || hasRange)) {
      return _slice(input, startPos, pos);
    }
    return null;
  }

  String? _scanLiteralBraceWord(int startPos) {
    final len = input.length;
    var pos = startPos + 1;
    var depth = 1;

    while (pos < len && depth > 0) {
      final c = input[pos];
      if (c == '{') {
        depth++;
        pos++;
      } else if (c == '}') {
        depth--;
        if (depth == 0) {
          return _slice(input, startPos, pos + 1);
        }
        pos++;
      } else if (c == ' ' ||
          c == '\t' ||
          c == '\n' ||
          c == ';' ||
          c == '&' ||
          c == '|') {
        return null;
      } else {
        pos++;
      }
    }
    return null;
  }

  ({String content, int end})? _scanExtglobPattern(int startPos) {
    final len = input.length;
    var pos = startPos + 1;
    var depth = 1;

    while (pos < len && depth > 0) {
      final c = input[pos];
      if (c == r'\' && pos + 1 < len) {
        pos += 2;
        continue;
      }
      if ('@*+?!'.contains(c) && pos + 1 < len && input[pos + 1] == '(') {
        pos++;
        depth++;
        pos++;
        continue;
      }
      if (c == '(') {
        depth++;
        pos++;
      } else if (c == ')') {
        depth--;
        pos++;
      } else if (c == '\n') {
        return null;
      } else {
        pos++;
      }
    }

    if (depth == 0) {
      return (content: _slice(input, startPos, pos), end: pos);
    }
    return null;
  }

  ({String varname, int end})? _scanFdVariable(int startPos) {
    final len = input.length;
    var pos = startPos + 1;
    final nameStart = pos;

    while (pos < len) {
      final c = input[pos];
      if (pos == nameStart) {
        if (!((c.compareTo('a') >= 0 && c.compareTo('z') <= 0) ||
            (c.compareTo('A') >= 0 && c.compareTo('Z') <= 0) ||
            c == '_')) {
          return null;
        }
      } else {
        if (!((c.compareTo('a') >= 0 && c.compareTo('z') <= 0) ||
            (c.compareTo('A') >= 0 && c.compareTo('Z') <= 0) ||
            (c.compareTo('0') >= 0 && c.compareTo('9') <= 0) ||
            c == '_')) {
          break;
        }
      }
      pos++;
    }

    if (pos == nameStart) return null;
    final varname = _slice(input, nameStart, pos);

    if (pos >= len || input[pos] != '}') return null;
    pos++;

    if (pos >= len) return null;
    final c = input[pos];
    final c2 = pos + 1 < len ? input[pos + 1] : '';
    final isRedirectOp = c == '>' ||
        c == '<' ||
        (c == '&' && (c2 == '>' || c2 == '<'));
    if (!isRedirectOp) return null;

    return (varname: varname, end: pos);
  }

  bool _dollarDparenIsSubshell(int startPos) {
    final len = input.length;
    var pos = startPos + 1;
    var depth = 2;
    var inSingleQuote = false;
    var inDoubleQuote = false;
    var hasNewline = false;

    while (pos < len && depth > 0) {
      final c = input[pos];

      if (inSingleQuote) {
        if (c == "'") inSingleQuote = false;
        if (c == '\n') hasNewline = true;
        pos++;
        continue;
      }
      if (inDoubleQuote) {
        if (c == r'\') {
          pos += 2;
          continue;
        }
        if (c == '"') inDoubleQuote = false;
        if (c == '\n') hasNewline = true;
        pos++;
        continue;
      }

      if (c == "'") {
        inSingleQuote = true;
        pos++;
        continue;
      }
      if (c == '"') {
        inDoubleQuote = true;
        pos++;
        continue;
      }
      if (c == r'\') {
        pos += 2;
        continue;
      }
      if (c == '\n') hasNewline = true;

      if (c == '(') {
        depth++;
        pos++;
        continue;
      }
      if (c == ')') {
        depth--;
        if (depth == 1) {
          final nextPos = pos + 1;
          if (nextPos < len && input[nextPos] == ')') {
            return false;
          }
          var scanPos = nextPos;
          var hasWhitespace = false;
          while (scanPos < len &&
              (input[scanPos] == ' ' ||
                  input[scanPos] == '\t' ||
                  input[scanPos] == '\n')) {
            hasWhitespace = true;
            scanPos++;
          }
          if (hasWhitespace && scanPos < len && input[scanPos] == ')') {
            return true;
          }
          if (hasNewline) return true;
        }
        if (depth == 0) return false;
        pos++;
        continue;
      }
      pos++;
    }
    return false;
  }

  bool _dparenClosesWithSpacedParens(int startPos) {
    final len = input.length;
    var pos = startPos;
    var depth = 2;
    var inSingleQuote = false;
    var inDoubleQuote = false;

    while (pos < len && depth > 0) {
      final c = input[pos];

      if (inSingleQuote) {
        if (c == "'") inSingleQuote = false;
        pos++;
        continue;
      }
      if (inDoubleQuote) {
        if (c == r'\') {
          pos += 2;
          continue;
        }
        if (c == '"') inDoubleQuote = false;
        pos++;
        continue;
      }

      if (c == "'") {
        inSingleQuote = true;
        pos++;
        continue;
      }
      if (c == '"') {
        inDoubleQuote = true;
        pos++;
        continue;
      }
      if (c == r'\') {
        pos += 2;
        continue;
      }
      if (c == '(') {
        depth++;
        pos++;
        continue;
      }
      if (c == ')') {
        depth--;
        if (depth == 1) {
          final nextPos = pos + 1;
          if (nextPos < len && input[nextPos] == ')') {
            return false;
          }
          var scanPos = nextPos;
          var hasWhitespace = false;
          while (scanPos < len &&
              (input[scanPos] == ' ' ||
                  input[scanPos] == '\t' ||
                  input[scanPos] == '\n')) {
            hasWhitespace = true;
            scanPos++;
          }
          if (hasWhitespace && scanPos < len && input[scanPos] == ')') {
            return true;
          }
        }
        if (depth == 0) return false;
        pos++;
        continue;
      }

      if (depth == 1) {
        if (c == '|' && pos + 1 < len && input[pos + 1] == '|') return true;
        if (c == '&' && pos + 1 < len && input[pos + 1] == '&') return true;
        if (c == '|' && pos + 1 < len && input[pos + 1] != '|') return true;
      }
      pos++;
    }
    return false;
  }
}
