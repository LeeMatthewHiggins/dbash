import 'package:dbash/src/ast/ast.dart';
import 'package:dbash/src/parser/parser.dart';
import 'package:dbash/src/parser/parser_types.dart';
import 'package:test/test.dart';

void main() {
  group('empty and whitespace input', () {
    test('empty string yields empty script', () {
      final script = parse('');
      expect(script.statements, isEmpty);
    });

    test('only newlines yields empty script', () {
      expect(parse('\n\n\n').statements, isEmpty);
    });

    test('only a comment yields empty script', () {
      expect(parse('# just a comment').statements, isEmpty);
    });
  });

  group('deferred errors for stray close tokens', () {
    test('stray close brace defers an error', () {
      final script = parse('}');
      expect(script.statements, hasLength(1));
      final stmt = script.statements.single;
      expect(stmt.deferredError, isNotNull);
      expect(stmt.deferredError!.token, '}');
      expect(stmt.deferredError!.message, contains('unexpected token'));
    });

    test('stray close paren defers an error', () {
      final stmt = parse(')').statements.single;
      expect(stmt.deferredError?.token, ')');
    });
  });

  group('immediate syntax errors', () {
    test('bare semicolon', () {
      expect(() => parse(';'), throwsA(isA<ParseException>()));
    });

    test('leading pipe', () {
      expect(() => parse('|'), throwsA(isA<ParseException>()));
    });

    test('case terminator at top level', () {
      expect(() => parse(';;'), throwsA(isA<ParseException>()));
    });

    for (final kw in ['do', 'done', 'then', 'else', 'elif', 'fi', 'esac']) {
      test('reserved word "$kw" at statement start', () {
        expect(() => parse(kw), throwsA(isA<ParseException>()));
      });
    }
  });

  group('parse exception details', () {
    test('carries line, column, and formatted message', () {
      try {
        parse(';');
        fail('expected ParseException');
      } on ParseException catch (e) {
        expect(e.line, greaterThan(0));
        expect(e.toString(), startsWith('Parse error at'));
      }
    });
  });

  group('limits', () {
    test('input over size limit throws', () {
      final huge = 'a' * (maxInputSize + 1);
      expect(() => parse(huge), throwsA(isA<ParseException>()));
    });
  });

  group('script returns AST root', () {
    test('parse returns a ScriptNode', () {
      expect(parse(''), isA<ScriptNode>());
      expect(parse('').type, 'Script');
    });
  });
}
