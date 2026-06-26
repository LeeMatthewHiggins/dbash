/// Bash glob/pattern matching (`fnmatch`-style) used by `case` and the `==` /
/// `!=` operators in `[[ ]]`.
///
/// Supports `*` (any run, including `/`), `?` (one char), `[...]` character
/// classes with `!`/`^` negation, `a-z` ranges, and POSIX `[:class:]` names,
/// and `\x` escaping. Not full extglob.
library;

/// Whether [str] matches the glob [pattern].
bool globMatch(String pattern, String str) => _match(pattern, 0, str, 0);

bool _match(String p, int pi, String s, int si) {
  var pIdx = pi;
  var sIdx = si;
  while (pIdx < p.length) {
    final pc = p[pIdx];
    if (pc == '*') {
      while (pIdx < p.length && p[pIdx] == '*') {
        pIdx++;
      }
      if (pIdx == p.length) return true;
      for (var k = sIdx; k <= s.length; k++) {
        if (_match(p, pIdx, s, k)) return true;
      }
      return false;
    } else if (pc == '?') {
      if (sIdx >= s.length) return false;
      pIdx++;
      sIdx++;
    } else if (pc == '[') {
      if (sIdx >= s.length) return false;
      final res = _matchClass(p, pIdx, s[sIdx]);
      if (res == null) {
        if (s[sIdx] != '[') return false;
        pIdx++;
        sIdx++;
      } else {
        if (!res.matched) return false;
        pIdx = res.nextPi;
        sIdx++;
      }
    } else if (pc == r'\' && pIdx + 1 < p.length) {
      if (sIdx >= s.length || s[sIdx] != p[pIdx + 1]) return false;
      pIdx += 2;
      sIdx++;
    } else {
      if (sIdx >= s.length || s[sIdx] != pc) return false;
      pIdx++;
      sIdx++;
    }
  }
  return sIdx == s.length;
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
