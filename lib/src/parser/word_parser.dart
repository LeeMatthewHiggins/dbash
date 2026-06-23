/// Word parsing utilities: pure string helpers for words, expansions, and
/// patterns.
///
/// Faithful port of `parser/word-parser.ts`. Part of the `parser` library.
// ignore_for_file: lines_longer_than_80_chars, use_string_buffers
part of 'parser.dart';

/// Safe character access: '' when [i] is out of range (mirrors JS `undefined`).
String _charAt(String s, int i) => (i >= 0 && i < s.length) ? s[i] : '';

/// Safe slice clamped to the string bounds (mirrors JS `slice`).
String _slice(String s, int start, int end) {
  final lo = start < 0 ? 0 : (start > s.length ? s.length : start);
  final hi = end < lo ? lo : (end > s.length ? s.length : end);
  return s.substring(lo, hi);
}

final RegExp _alnumUnderscore = RegExp('[a-zA-Z0-9_]');
final RegExp _tildeChars = RegExp('[a-zA-Z0-9_-]');
final RegExp _octalDigit = RegExp('[0-7]');

/// Decode [bytes] as UTF-8 with error recovery (invalid bytes preserved as
/// Latin-1), matching bash's behavior for `$'\xNN'`.
String _decodeUtf8WithRecovery(List<int> bytes) {
  final sb = StringBuffer();
  var i = 0;
  while (i < bytes.length) {
    final b0 = bytes[i];
    if (b0 < 0x80) {
      sb.writeCharCode(b0);
      i++;
      continue;
    }
    if ((b0 & 0xe0) == 0xc0) {
      if (i + 1 < bytes.length &&
          (bytes[i + 1] & 0xc0) == 0x80 &&
          b0 >= 0xc2) {
        sb.writeCharCode(((b0 & 0x1f) << 6) | (bytes[i + 1] & 0x3f));
        i += 2;
        continue;
      }
      sb.writeCharCode(b0);
      i++;
      continue;
    }
    if ((b0 & 0xf0) == 0xe0) {
      if (i + 2 < bytes.length &&
          (bytes[i + 1] & 0xc0) == 0x80 &&
          (bytes[i + 2] & 0xc0) == 0x80) {
        if (b0 == 0xe0 && bytes[i + 1] < 0xa0) {
          sb.writeCharCode(b0);
          i++;
          continue;
        }
        final codePoint = ((b0 & 0x0f) << 12) |
            ((bytes[i + 1] & 0x3f) << 6) |
            (bytes[i + 2] & 0x3f);
        if (codePoint >= 0xd800 && codePoint <= 0xdfff) {
          sb.writeCharCode(b0);
          i++;
          continue;
        }
        sb.writeCharCode(codePoint);
        i += 3;
        continue;
      }
      sb.writeCharCode(b0);
      i++;
      continue;
    }
    if ((b0 & 0xf8) == 0xf0 && b0 <= 0xf4) {
      if (i + 3 < bytes.length &&
          (bytes[i + 1] & 0xc0) == 0x80 &&
          (bytes[i + 2] & 0xc0) == 0x80 &&
          (bytes[i + 3] & 0xc0) == 0x80) {
        if (b0 == 0xf0 && bytes[i + 1] < 0x90) {
          sb.writeCharCode(b0);
          i++;
          continue;
        }
        final codePoint = ((b0 & 0x07) << 18) |
            ((bytes[i + 1] & 0x3f) << 12) |
            ((bytes[i + 2] & 0x3f) << 6) |
            (bytes[i + 3] & 0x3f);
        if (codePoint > 0x10ffff) {
          sb.writeCharCode(b0);
          i++;
          continue;
        }
        sb.writeCharCode(codePoint);
        i += 4;
        continue;
      }
      sb.writeCharCode(b0);
      i++;
      continue;
    }
    sb.writeCharCode(b0);
    i++;
  }
  return sb.toString();
}

/// Find the end index of a tilde-prefix starting at [start].
int findTildeEnd(Parser p, String value, int start) {
  var i = start + 1;
  while (i < value.length && _tildeChars.hasMatch(value[i])) {
    i++;
  }
  return i;
}

/// Find the index of the matching [close] bracket for the [open] at [start],
/// or -1 if unbalanced.
int findMatchingBracket(
  Parser p,
  String value,
  int start,
  String open,
  String close,
) {
  var depth = 1;
  var i = start + 1;
  while (i < value.length && depth > 0) {
    if (value[i] == open) {
      depth++;
    } else if (value[i] == close) {
      depth--;
    }
    if (depth > 0) i++;
  }
  return depth == 0 ? i : -1;
}

/// Find the end of a parameter operation word (stops at the closing `}`),
/// honoring quotes and escapes.
int findParameterOperationEnd(Parser p, String value, int start) {
  var i = start;
  var depth = 1;
  while (i < value.length && depth > 0) {
    final char = value[i];
    if (char == r'\' && i + 1 < value.length) {
      i += 2;
      continue;
    }
    if (char == "'") {
      final closeIdx = value.indexOf("'", i + 1);
      if (closeIdx != -1) {
        i = closeIdx + 1;
        continue;
      }
    }
    if (char == '"') {
      i++;
      while (i < value.length && value[i] != '"') {
        if (value[i] == r'\' && i + 1 < value.length) {
          i += 2;
        } else {
          i++;
        }
      }
      if (i < value.length) i++;
      continue;
    }
    if (char == '{') {
      depth++;
    } else if (char == '}') {
      depth--;
    }
    if (depth > 0) i++;
  }
  return i;
}

/// Find the end of a `${var/PATTERN/...}` pattern (stops at unescaped `/` or
/// `}`).
int findPatternEnd(Parser p, String value, int start) {
  var i = start;
  var consumedAny = false;
  while (i < value.length) {
    final char = value[i];
    if ((char == '/' && consumedAny) || char == '}') break;
    if (char == "'") {
      final closeIdx = value.indexOf("'", i + 1);
      if (closeIdx != -1) {
        i = closeIdx + 1;
        consumedAny = true;
        continue;
      }
    }
    if (char == '"') {
      i++;
      while (i < value.length && value[i] != '"') {
        if (value[i] == r'\' && i + 1 < value.length) {
          i += 2;
        } else {
          i++;
        }
      }
      if (i < value.length) i++;
      consumedAny = true;
      continue;
    }
    if (char == r'\') {
      i += 2;
      consumedAny = true;
    } else {
      i++;
      consumedAny = true;
    }
  }
  return i;
}

/// Parse a glob pattern (`*`, `?`, `[...]`) starting at [start].
({String pattern, int endIndex}) parseGlobPattern(
  Parser p,
  String value,
  int start,
) {
  var i = start;
  var pattern = '';
  while (i < value.length) {
    final char = value[i];
    if (char == '*' || char == '?') {
      pattern += char;
      i++;
    } else if (char == '[') {
      final closeIdx = _findCharacterClassEnd(value, i);
      if (closeIdx == -1) {
        pattern += char;
        i++;
      } else {
        pattern += _slice(value, i, closeIdx + 1);
        i = closeIdx + 1;
      }
    } else {
      break;
    }
  }
  return (pattern: pattern, endIndex: i);
}

int _findCharacterClassEnd(String value, int start) {
  var i = start + 1;
  if (i < value.length && value[i] == '^') i++;
  if (i < value.length && value[i] == ']') i++;

  while (i < value.length) {
    final char = value[i];
    if (char == r'\' && i + 1 < value.length) {
      final next = value[i + 1];
      if (next == '"' || next == "'") return -1;
      i += 2;
      continue;
    }
    if (char == ']') return i;
    if (char == '"' || char == r'$' || char == '`') return -1;
    if (char == "'") {
      final closeQuote = value.indexOf("'", i + 1);
      if (closeQuote != -1) {
        i = closeQuote + 1;
        continue;
      }
    }
    if (char == '[' && i + 1 < value.length && value[i + 1] == ':') {
      final closePos = value.indexOf(':]', i + 2);
      if (closePos != -1) {
        i = closePos + 2;
        continue;
      }
    }
    if (char == '[' &&
        i + 1 < value.length &&
        (value[i + 1] == '.' || value[i + 1] == '=')) {
      final closeSeq = '${value[i + 1]}]';
      final closePos = value.indexOf(closeSeq, i + 2);
      if (closePos != -1) {
        i = closePos + 2;
        continue;
      }
    }
    i++;
  }
  return -1;
}

/// Parse a `$'...'` ANSI-C quoted string body starting at [start] (after `$'`).
({WordPart part, int endIndex}) parseAnsiCQuoted(
  Parser p,
  String value,
  int start,
) {
  var result = '';
  var i = start;
  while (i < value.length && value[i] != "'") {
    final char = value[i];
    if (char == r'\' && i + 1 < value.length) {
      final next = value[i + 1];
      switch (next) {
        case 'n':
          result += '\n';
          i += 2;
        case 't':
          result += '\t';
          i += 2;
        case 'r':
          result += '\r';
          i += 2;
        case r'\':
          result += r'\';
          i += 2;
        case "'":
          result += "'";
          i += 2;
        case '"':
          result += '"';
          i += 2;
        case 'a':
          result += String.fromCharCode(7); // bell
          i += 2;
        case 'b':
          result += String.fromCharCode(8); // backspace
          i += 2;
        case 'e':
        case 'E':
          result += String.fromCharCode(27); // escape
          i += 2;
        case 'f':
          result += String.fromCharCode(12); // form feed
          i += 2;
        case 'v':
          result += String.fromCharCode(11); // vertical tab
          i += 2;
        case 'x':
          final bytes = <int>[];
          var j = i;
          while (j + 1 < value.length &&
              value[j] == r'\' &&
              value[j + 1] == 'x') {
            final hex = _slice(value, j + 2, j + 4);
            final code = hex.isEmpty ? null : int.tryParse(hex, radix: 16);
            if (code != null) {
              bytes.add(code);
              j += 2 + hex.length;
            } else {
              break;
            }
          }
          if (bytes.isNotEmpty) {
            result += _decodeUtf8WithRecovery(bytes);
            i = j;
          } else {
            result += r'\x';
            i += 2;
          }
        case 'u':
          final hex = _slice(value, i + 2, i + 6);
          final code = int.tryParse(hex, radix: 16);
          if (code != null) {
            result += String.fromCharCode(code);
            i += 6;
          } else {
            result += r'\u';
            i += 2;
          }
        case 'c':
          if (i + 2 < value.length) {
            final code = value.codeUnitAt(i + 2) & 0x1f;
            result += String.fromCharCode(code);
            i += 3;
          } else {
            result += r'\c';
            i += 2;
          }
        case '0':
        case '1':
        case '2':
        case '3':
        case '4':
        case '5':
        case '6':
        case '7':
          var octal = '';
          var j = i + 1;
          while (j < value.length && j < i + 4 && _octalDigit.hasMatch(value[j])) {
            octal += value[j];
            j++;
          }
          result += String.fromCharCode(int.parse(octal, radix: 8));
          i = j;
        default:
          result += char;
          i++;
      }
    } else {
      result += char;
      i++;
    }
  }
  if (i < value.length && value[i] == "'") i++;
  return (part: LiteralPart(result), endIndex: i);
}

/// Parse an arithmetic expression from [str] (empty → literal 0).
ArithmeticExpressionNode parseArithExprFromString(Parser p, String str) {
  final trimmed = str.trim();
  if (trimmed.isEmpty) {
    return ArithmeticExpressionNode(ArithNumberNode(0));
  }
  return p.parseArithmeticExpression(trimmed);
}

List<String> _splitBraceItems(String inner) {
  final items = <String>[];
  var current = '';
  var depth = 0;
  for (var i = 0; i < inner.length; i++) {
    final c = inner[i];
    if (c == '{') {
      depth++;
      current += c;
    } else if (c == '}') {
      depth--;
      current += c;
    } else if (c == ',' && depth == 0) {
      items.add(current);
      current = '';
    } else {
      current += c;
    }
  }
  items.add(current);
  return items;
}

final RegExp _numRangeRe = RegExp(r'^(-?\d+)\.\.(-?\d+)(?:\.\.(-?\d+))?$');
final RegExp _charRangeRe =
    RegExp(r'^([a-zA-Z])\.\.([a-zA-Z])(?:\.\.(-?\d+))?$');

/// Try to parse a brace expansion at [start]; returns null if not one.
({WordPart part, int endIndex})? tryParseBraceExpansion(
  Parser p,
  String value,
  int start,
  List<WordPart> Function(Parser, String)? parseWordPartsFn,
) {
  final closeIdx = findMatchingBracket(p, value, start, '{', '}');
  if (closeIdx == -1) return null;

  final inner = _slice(value, start + 1, closeIdx);

  final rangeMatch = _numRangeRe.firstMatch(inner);
  if (rangeMatch != null) {
    return (
      part: BraceExpansionPart([
        BraceRangeItem(
          int.parse(rangeMatch.group(1)!),
          int.parse(rangeMatch.group(2)!),
          step: rangeMatch.group(3) != null
              ? int.parse(rangeMatch.group(3)!)
              : null,
          startStr: rangeMatch.group(1),
          endStr: rangeMatch.group(2),
        ),
      ]),
      endIndex: closeIdx + 1,
    );
  }

  final charRangeMatch = _charRangeRe.firstMatch(inner);
  if (charRangeMatch != null) {
    return (
      part: BraceExpansionPart([
        BraceRangeItem(
          charRangeMatch.group(1)!,
          charRangeMatch.group(2)!,
          step: charRangeMatch.group(3) != null
              ? int.parse(charRangeMatch.group(3)!)
              : null,
        ),
      ]),
      endIndex: closeIdx + 1,
    );
  }

  if (inner.contains(',') && parseWordPartsFn != null) {
    final rawItems = _splitBraceItems(inner);
    final items = rawItems
        .map<BraceItem>(
          (s) => BraceWordItem(WordNode(parseWordPartsFn(p, s))),
        )
        .toList();
    return (part: BraceExpansionPart(items), endIndex: closeIdx + 1);
  }

  if (inner.contains(',')) {
    final rawItems = _splitBraceItems(inner);
    final items = rawItems
        .map<BraceItem>((s) => BraceWordItem(WordNode([LiteralPart(s)])))
        .toList();
    return (part: BraceExpansionPart(items), endIndex: closeIdx + 1);
  }

  return null;
}

/// Render a [word] back to a source string (for reconstructing array
/// assignments).
String wordToString(Parser p, WordNode word) {
  var result = '';
  for (final part in word.parts) {
    switch (part) {
      case LiteralPart():
        result += part.value;
      case SingleQuotedPart():
        result += "'${part.value}'";
      case EscapedPart():
        result += part.value;
      case DoubleQuotedPart():
        result += '"';
        for (final inner in part.parts) {
          if (inner is LiteralPart) {
            result += inner.value;
          } else if (inner is EscapedPart) {
            result += inner.value;
          } else if (inner is ParameterExpansionPart) {
            result += '\${${inner.parameter}}';
          }
        }
        result += '"';
      case ParameterExpansionPart():
        result += '\${${part.parameter}}';
      case GlobPart():
        result += part.pattern;
      case TildeExpansionPart():
        result += '~';
        if (part.user != null) result += part.user!;
      case BraceExpansionPart():
        result += '{';
        final braceItems = <String>[];
        for (final item in part.items) {
          if (item is BraceRangeItem) {
            final startVal = item.startStr ?? '${item.start}';
            final endVal = item.endStr ?? '${item.end}';
            if (item.step != null) {
              braceItems.add('$startVal..$endVal..${item.step}');
            } else {
              braceItems.add('$startVal..$endVal');
            }
          } else if (item is BraceWordItem) {
            braceItems.add(wordToString(p, item.word));
          }
        }
        if (braceItems.length == 1 && part.items[0] is BraceRangeItem) {
          result += braceItems[0];
        } else {
          result += braceItems.join(',');
        }
        result += '}';
      case ArithmeticExpansionPart():
      case CommandSubstitutionPart():
      case ProcessSubstitutionPart():
        result += part.type;
    }
  }
  return result;
}

const Map<TokenType, String> _redirectOpMap = {
  TokenType.less: '<',
  TokenType.great: '>',
  TokenType.dgreat: '>>',
  TokenType.lessand: '<&',
  TokenType.greatand: '>&',
  TokenType.lessgreat: '<>',
  TokenType.clobber: '>|',
  TokenType.tless: '<<<',
  TokenType.andGreat: '&>',
  TokenType.andDgreat: '&>>',
  TokenType.dless: '<',
  TokenType.dlessdash: '<',
};

/// Map a redirection token [type] to its operator string.
String tokenToRedirectOp(Parser p, TokenType type) =>
    _redirectOpMap[type] ?? '>';
