import 'package:dbash/src/parser/lexer.dart';
import 'package:dbash/src/parser/token.dart';
import 'package:test/test.dart';

/// Tokenize [src] and return all tokens except the trailing EOF.
List<Token> lex(String src) {
  final tokens = Lexer(src).tokenize();
  expect(tokens.last.type, TokenType.eof);
  return tokens.sublist(0, tokens.length - 1);
}

/// Tokenize and return (type, value) pairs (excluding EOF).
List<(TokenType, String)> pairs(String src) =>
    lex(src).map((t) => (t.type, t.value)).toList();

void main() {
  group('basic words and classification', () {
    test('simple command', () {
      expect(pairs('echo hello'), [
        (TokenType.name, 'echo'),
        (TokenType.name, 'hello'),
      ]);
    });

    test('number token', () {
      expect(pairs('2'), [(TokenType.number, '2')]);
    });

    test('word with special chars is WORD not NAME', () {
      expect(pairs('foo-bar'), [(TokenType.word, 'foo-bar')]);
    });

    test('assignment word', () {
      expect(pairs('VAR=value'), [(TokenType.assignmentWord, 'VAR=value')]);
    });

    test('append assignment word', () {
      expect(pairs('VAR+=x'), [(TokenType.assignmentWord, 'VAR+=x')]);
    });

    test('array subscript assignment', () {
      expect(pairs('a[0]=v'), [(TokenType.assignmentWord, 'a[0]=v')]);
    });

    test('leading-digit name is a word', () {
      expect(pairs('1abc'), [(TokenType.word, '1abc')]);
    });
  });

  group('reserved words', () {
    test('control keywords', () {
      expect(pairs('if then else elif fi'), [
        (TokenType.ifKw, 'if'),
        (TokenType.then, 'then'),
        (TokenType.elseKw, 'else'),
        (TokenType.elif, 'elif'),
        (TokenType.fi, 'fi'),
      ]);
    });

    test('loop keywords', () {
      expect(pairs('for while until do done').map((p) => p.$1), [
        TokenType.forKw,
        TokenType.whileKw,
        TokenType.until,
        TokenType.doKw,
        TokenType.done,
      ]);
    });

    test('quoted keyword is a word/name, not reserved', () {
      expect(lex("'if'").single.type, isNot(TokenType.ifKw));
    });
  });

  group('operators', () {
    test('single-char operators', () {
      expect(pairs('a | b & c ; d').map((p) => p.$1), [
        TokenType.name,
        TokenType.pipe,
        TokenType.name,
        TokenType.amp,
        TokenType.name,
        TokenType.semicolon,
        TokenType.name,
      ]);
    });

    test('two-char logical operators', () {
      expect(pairs('a && b || c').map((p) => p.$1), [
        TokenType.name,
        TokenType.andAnd,
        TokenType.name,
        TokenType.orOr,
        TokenType.name,
      ]);
    });

    test('pipe-amp', () {
      expect(lex('a |& b')[1].type, TokenType.pipeAmp);
    });

    test('redirections', () {
      expect(pairs('> >> < <& >& <> >| &> &>>').map((p) => p.$1), [
        TokenType.great,
        TokenType.dgreat,
        TokenType.less,
        TokenType.lessand,
        TokenType.greatand,
        TokenType.lessgreat,
        TokenType.clobber,
        TokenType.andGreat,
        TokenType.andDgreat,
      ]);
    });

    test('fd number before redirect', () {
      expect(pairs('2>&1'), [
        (TokenType.number, '2'),
        (TokenType.greatand, '>&'),
        (TokenType.number, '1'),
      ]);
    });

    test('case terminators', () {
      expect(pairs(';; ;& ;;&').map((p) => p.$1), [
        TokenType.dsemi,
        TokenType.semiAnd,
        TokenType.semiSemiAnd,
      ]);
    });

    test('bang token', () {
      expect(lex('! cmd').first.type, TokenType.bang);
    });

    test('bang-equals is a word', () {
      expect(lex('!=').single, isA<Token>());
      expect(lex('!=').single.value, '!=');
    });
  });

  group('grouping and compound starts', () {
    test('double bracket conditional', () {
      expect(pairs('[[ x ]]').map((p) => p.$1), [
        TokenType.dbrackStart,
        TokenType.name,
        TokenType.dbrackEnd,
      ]);
    });

    test('arithmetic command', () {
      expect(pairs('(( 1 + 2 ))').first.$1, TokenType.dparenStart);
      expect(lex('(( 1 + 2 ))').last.type, TokenType.dparenEnd);
    });

    test('subshell parens', () {
      expect(pairs('( a )').map((p) => p.$1), [
        TokenType.lparen,
        TokenType.name,
        TokenType.rparen,
      ]);
    });

    test('nested subshells are not arithmetic', () {
      // ((a) || (b)) closes with spaced parens / has || => two LPARENs.
      final t = lex('((a) || (b))');
      expect(t.first.type, TokenType.lparen);
      expect(t[1].type, TokenType.lparen);
    });
  });

  group('quoting', () {
    test('fully single-quoted word', () {
      final t = lex("'hello world'").single;
      expect(t.value, 'hello world');
      expect(t.singleQuoted, isTrue);
      expect(t.quoted, isTrue);
    });

    test('fully double-quoted word', () {
      final t = lex('"hello"').single;
      expect(t.value, 'hello');
      expect(t.quoted, isTrue);
      expect(t.singleQuoted, isFalse);
    });

    test('partial quoting preserves quotes in value', () {
      final t = lex("a'b'c").single;
      expect(t.value, "a'b'c");
      expect(t.quoted, isFalse);
    });

    test(r"ANSI-C $'...' is kept in value", () {
      final t = lex(r"$'\n'").single;
      expect(t.value, r"$'\n'");
    });

    test('unterminated single quote throws', () {
      expect(() => lex("'abc"), throwsA(isA<LexerError>()));
    });

    test('unterminated double quote throws', () {
      expect(() => lex('"abc'), throwsA(isA<LexerError>()));
    });
  });

  group('expansions kept intact in word value', () {
    test('command substitution', () {
      expect(lex(r'$(echo hi)').single.value, r'$(echo hi)');
    });

    test('parameter expansion with hash is not a comment', () {
      expect(lex(r'${#var}').single.value, r'${#var}');
    });

    test('arithmetic expansion', () {
      expect(lex(r'$((1+2))').single.value, r'$((1+2))');
    });

    test('backtick substitution', () {
      expect(lex('`echo hi`').single.value, '`echo hi`');
    });

    test('special variables', () {
      expect(lex(r'$?').single.value, r'$?');
      expect(lex(r'$#').single.value, r'$#');
      expect(lex(r'$1').single.value, r'$1');
    });

    test('nested parameter expansion with braces', () {
      expect(lex(r'${x:-${y}}').single.value, r'${x:-${y}}');
    });

    test('unterminated quote inside parameter expansion throws', () {
      expect(() => lex(r"${x:-'}"), throwsA(isA<LexerError>()));
    });
  });

  group('comments and newlines', () {
    test('comment token', () {
      expect(pairs('# a comment'), [
        (TokenType.comment, '# a comment'),
      ]);
    });

    test('trailing comment after command', () {
      expect(pairs('echo hi # note').map((p) => p.$1), [
        TokenType.name,
        TokenType.name,
        TokenType.comment,
      ]);
    });

    test('newline token', () {
      expect(pairs('a\nb').map((p) => p.$1), [
        TokenType.name,
        TokenType.newline,
        TokenType.name,
      ]);
    });

    test('line continuation is skipped', () {
      expect(pairs('a\\\nb'), [(TokenType.name, 'ab')]);
    });
  });

  group('heredocs', () {
    test('basic heredoc content', () {
      final t = lex('cat <<EOF\nline1\nline2\nEOF\n');
      final content =
          t.firstWhere((x) => x.type == TokenType.heredocContent).value;
      expect(content, 'line1\nline2\n');
    });

    test('tab-stripping heredoc strips tabs only for delimiter match', () {
      // The lexer keeps raw body content; the stripTabs flag is applied by a
      // later stage. Only the delimiter line (\tEOF) is matched tab-stripped.
      final t = lex('cat <<-EOF\n\t\tindented\n\tEOF\n');
      final content =
          t.firstWhere((x) => x.type == TokenType.heredocContent).value;
      expect(content, '\t\tindented\n');
    });

    test('here-string operator', () {
      expect(lex('cat <<< word').first.type, TokenType.name);
      expect(
        lex('cat <<< word').map((t) => t.type),
        contains(TokenType.tless),
      );
    });

    test('quoted delimiter', () {
      final t = lex("cat <<'EOF'\n\$x\nEOF\n");
      final content =
          t.firstWhere((x) => x.type == TokenType.heredocContent).value;
      expect(content, '\$x\n');
    });
  });

  group('brace expansion words', () {
    test('comma brace expansion stays one word', () {
      expect(lex('{a,b,c}').single.value, '{a,b,c}');
    });

    test('range brace expansion stays one word', () {
      expect(lex('{1..5}').single.value, '{1..5}');
    });

    test('prefix and suffix around brace', () {
      expect(lex('pre{a,b}post').single.value, 'pre{a,b}post');
    });

    test('brace group when followed by space', () {
      expect(lex('{ a; }').first.type, TokenType.lbrace);
    });

    test('empty braces word for find -exec', () {
      expect(lex('{}').single, isA<Token>());
      expect(lex('{}').single.value, '{}');
    });
  });

  group('fd variable redirection', () {
    test('{fd}> is an FD_VARIABLE token', () {
      final t = lex('{fd}>file');
      expect(t.first.type, TokenType.fdVariable);
      expect(t.first.value, 'fd');
      expect(t[1].type, TokenType.great);
    });

    test('{var} not before redirect is a brace word/group', () {
      expect(lex('{var}').first.type, isNot(TokenType.fdVariable));
    });
  });

  group('extglob', () {
    test('extglob pattern kept in one word', () {
      expect(lex('@(a|b)').single.value, '@(a|b)');
    });
  });

  group('positions', () {
    test('token line and column tracking', () {
      final t = lex('a\n  b');
      final b = t.firstWhere((x) => x.value == 'b');
      expect(b.line, 2);
      expect(b.column, 3);
    });
  });
}
