/// Bash glob/pattern matching (`fnmatch`-style) used by `case` and the `==` /
/// `!=` operators in `[[ ]]`.
///
/// Supports `*` (any run, including `/`), `?` (one char), `[...]` character
/// classes with `!`/`^` negation, `a-z` ranges, and POSIX `[:class:]` names,
/// `\x` escaping, and the extended-glob forms `?(...)`, `*(...)`, `+(...)`,
/// `@(...)`, and `!(...)` over `|`-separated alternatives.
library;

const _extglobPrefixes = {'?', '*', '+', '@', '!'};

/// Whether [str] matches the glob [pattern].
bool globMatch(String pattern, String str) => _match(pattern, 0, str, 0);

/// Whether `p[pi..]` matches the whole of `s[si..]`.
bool _match(String p, int pi, String s, int si) {
  if (pi >= p.length) return si >= s.length;
  final pc = p[pi];

  if (_extglobPrefixes.contains(pc) &&
      pi + 1 < p.length &&
      p[pi + 1] == '(') {
    final close = _matchingParen(p, pi + 1);
    if (close != -1) {
      final alts = _splitAlternatives(p.substring(pi + 2, close));
      return _matchExtglob(pc, alts, p, close + 1, s, si);
    }
  }

  if (pc == '*') {
    if (_match(p, pi + 1, s, si)) return true;
    return si < s.length && _match(p, pi, s, si + 1);
  }
  if (pc == '?') {
    return si < s.length && _match(p, pi + 1, s, si + 1);
  }
  if (pc == '[') {
    final probe = _matchClass(p, pi, si < s.length ? s[si] : ' ');
    if (probe == null) {
      return si < s.length && s[si] == '[' && _match(p, pi + 1, s, si + 1);
    }
    if (si >= s.length || !probe.matched) return false;
    return _match(p, probe.nextPi, s, si + 1);
  }
  if (pc == r'\' && pi + 1 < p.length) {
    return si < s.length && s[si] == p[pi + 1] && _match(p, pi + 2, s, si + 1);
  }
  return si < s.length && s[si] == pc && _match(p, pi + 1, s, si + 1);
}

/// Matches an extended-glob group `op(alts)` followed by `p[restPi..]`.
bool _matchExtglob(
  String op,
  List<String> alts,
  String p,
  int restPi,
  String s,
  int si,
) {
  bool rest(int k) => _match(p, restPi, s, k);

  switch (op) {
    case '@':
      return _altEnds(alts, s, si).any(rest);
    case '?':
      return rest(si) || _altEnds(alts, s, si).any(rest);
    case '*':
      return _starMatch(alts, p, restPi, s, si);
    case '+':
      return _altEnds(alts, s, si)
          .any((k) => k > si && _starMatch(alts, p, restPi, s, k));
    case '!':
      for (var k = si; k <= s.length; k++) {
        final sub = s.substring(si, k);
        if (!alts.any((a) => _match(a, 0, sub, 0)) && rest(k)) return true;
      }
      return false;
  }
  return false;
}

/// End indices `k` such that some alternative matches `s[si..k]` exactly.
Iterable<int> _altEnds(List<String> alts, String s, int si) sync* {
  for (final alt in alts) {
    for (var k = si; k <= s.length; k++) {
      if (_match(alt, 0, s.substring(si, k), 0)) yield k;
    }
  }
}

/// Zero-or-more repetition of [alts] (`*(...)` / the tail of `+(...)`).
bool _starMatch(List<String> alts, String p, int restPi, String s, int si) {
  if (_match(p, restPi, s, si)) return true;
  for (final alt in alts) {
    for (var k = si + 1; k <= s.length; k++) {
      if (_match(alt, 0, s.substring(si, k), 0) &&
          _starMatch(alts, p, restPi, s, k)) {
        return true;
      }
    }
  }
  return false;
}

/// Index of the `)` closing the `(` at [open], skipping nested groups,
/// bracket classes, and escapes. Returns -1 when unbalanced.
int _matchingParen(String p, int open) {
  var depth = 0;
  var i = open;
  while (i < p.length) {
    final c = p[i];
    if (c == r'\') {
      i += 2;
      continue;
    }
    if (c == '[') {
      final probe = _matchClass(p, i, ' ');
      if (probe != null) {
        i = probe.nextPi;
        continue;
      }
    }
    if (c == '(') {
      depth++;
    } else if (c == ')') {
      depth--;
      if (depth == 0) return i;
    }
    i++;
  }
  return -1;
}

/// Splits extglob group [content] on top-level `|`, respecting nesting.
List<String> _splitAlternatives(String content) {
  final alts = <String>[];
  var depth = 0;
  var start = 0;
  var i = 0;
  while (i < content.length) {
    final c = content[i];
    if (c == r'\') {
      i += 2;
      continue;
    }
    if (c == '[') {
      final probe = _matchClass(content, i, ' ');
      if (probe != null) {
        i = probe.nextPi;
        continue;
      }
    }
    if (c == '(') {
      depth++;
    } else if (c == ')') {
      depth--;
    } else if (c == '|' && depth == 0) {
      alts.add(content.substring(start, i));
      start = i + 1;
    }
    i++;
  }
  alts.add(content.substring(start));
  return alts;
}

({bool matched, int nextPi})? _matchClass(String p, int pi, String c) {
  var i = pi + 1;
  var negate = false;
  if (i < p.length && (p[i] == '!' || p[i] == '^')) {
    negate = true;
    i++;
  }
  var matched = false;
  var first = true;
  while (i < p.length) {
    if (p[i] == ']' && !first) break;
    first = false;

    if (p[i] == '[' && i + 1 < p.length && p[i + 1] == ':') {
      final close = p.indexOf(':]', i + 2);
      if (close != -1) {
        if (_posixClass(p.substring(i + 2, close), c)) matched = true;
        i = close + 2;
        continue;
      }
    }

    if (i + 2 < p.length && p[i + 1] == '-' && p[i + 2] != ']') {
      final lo = p.codeUnitAt(i);
      final hi = p.codeUnitAt(i + 2);
      final cc = c.codeUnitAt(0);
      if (cc >= lo && cc <= hi) matched = true;
      i += 3;
      continue;
    }

    if (p[i] == c) matched = true;
    i++;
  }
  if (i >= p.length || p[i] != ']') return null;
  return (matched: negate ? !matched : matched, nextPi: i + 1);
}

bool _posixClass(String name, String c) {
  final code = c.codeUnitAt(0);
  bool digit() => code >= 0x30 && code <= 0x39;
  bool upper() => code >= 0x41 && code <= 0x5a;
  bool lower() => code >= 0x61 && code <= 0x7a;
  bool alpha() => upper() || lower();
  switch (name) {
    case 'alpha':
      return alpha();
    case 'digit':
      return digit();
    case 'alnum':
      return alpha() || digit();
    case 'upper':
      return upper();
    case 'lower':
      return lower();
    case 'space':
      return c == ' ' || c == '\t' || c == '\n' || c == '\r' ||
          code == 0x0b || code == 0x0c;
    case 'blank':
      return c == ' ' || c == '\t';
    case 'punct':
      return (code >= 0x21 && code <= 0x2f) ||
          (code >= 0x3a && code <= 0x40) ||
          (code >= 0x5b && code <= 0x60) ||
          (code >= 0x7b && code <= 0x7e);
    case 'xdigit':
      return digit() ||
          (code >= 0x41 && code <= 0x46) ||
          (code >= 0x61 && code <= 0x66);
    case 'cntrl':
      return code < 0x20 || code == 0x7f;
    case 'print':
      return code >= 0x20 && code < 0x7f;
    case 'graph':
      return code > 0x20 && code < 0x7f;
    default:
      return false;
  }
}
