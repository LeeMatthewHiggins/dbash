// Unquoted word splitting on default IFS whitespace.
//
// Regression coverage for issue #6: leading/trailing IFS whitespace must NOT
// produce spurious empty fields. The defect lived in the shared `appendSplit`
// field builder (lib/src/runtime/expansion.dart), so it spans BOTH the command
// substitution `$(...)` path and the unquoted parameter expansion `$var` path.
// The production fix landed earlier; these tests pin the behaviour so it can't
// silently regress, covering the cases the issue called out explicitly.
import 'package:dbash/dbash.dart';
import 'package:test/test.dart';

void main() {
  group('issue #6 — IFS-whitespace word splitting drops no empty fields', () {
    test(r'$(...) path: leading/trailing whitespace yields a single field',
        () async {
      // bash: `for w in $(echo " a "); do echo "[$w]"; done` -> [a]
      final r = await Bash().exec(
        r'for w in $(echo " a "); do echo "[$w]"; done',
      );
      expect(r.stdout, '[a]\n');
    });

    test(r'$var path: leading/trailing/interior whitespace splits cleanly',
        () async {
      // bash: v="  a  b  "; for w in $v -> [a] [b], no empty boundary fields.
      final r = await Bash().exec(
        r'v="  a  b  "; for w in $v; do echo "[$w]"; done',
      );
      expect(r.stdout, '[a]\n[b]\n');
    });

    test(r'$var path: a whitespace-only value yields no fields', () async {
      // The loop body must never run for an all-whitespace value.
      final r = await Bash().exec(
        r'v="   "; n=0; for w in $v; do n=1; done; echo $n',
      );
      expect(r.stdout, '0\n');
    });

    test('adjacent concat: leading-whitespace split breaks the current field',
        () async {
      // Assignment form from the issue: x="a"$(echo " b") -> x is "a b", then
      // `$x` splits to two fields. The in-progress field must break, not merge.
      final r = await Bash().exec(
        r'x="a"$(echo " b"); for w in $x; do echo "[$w]"; done',
      );
      expect(r.stdout, '[a]\n[b]\n');
    });

    test('adjacent concat: unquoted literal + leading-ws substitution breaks',
        () async {
      // bash: `for w in a$(echo " b")` -> the leading space delimits, so the
      // literal "a" stays its own field and "b" is separate ([a] [b]).
      final r = await Bash().exec(
        r'for w in a$(echo " b"); do echo "[$w]"; done',
      );
      expect(r.stdout, '[a]\n[b]\n');
    });

    test('adjacent concat: no whitespace at the seam keeps fields joined',
        () async {
      // The trim must not over-split: `a$(echo "b")` -> single field "ab".
      final r = await Bash().exec(
        r'for w in a$(echo "b"); do echo "[$w]"; done',
      );
      expect(r.stdout, '[ab]\n');
    });

    test('adjacent concat: trailing-whitespace substitution + literal breaks',
        () async {
      // `$(echo "a ")b` -> "a " then "b" -> two fields [a] [b].
      final r = await Bash().exec(
        r'for w in $(echo "a ")b; do echo "[$w]"; done',
      );
      expect(r.stdout, '[a]\n[b]\n');
    });
  });
}
