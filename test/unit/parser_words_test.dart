import 'package:dbash/src/ast/ast.dart';
import 'package:dbash/src/parser/parser.dart';
import 'package:test/test.dart';

/// Parse [src] and return its single simple command.
SimpleCommandNode cmd(String src) {
  final script = parse(src);
  final stmt = script.statements.single;
  final pipeline = stmt.pipelines.single;
  return pipeline.commands.single as SimpleCommandNode;
}

String lit(WordNode w) => (w.parts.single as LiteralPart).value;

void main() {
  group('plain commands (the normal path)', () {
    test('bare command with no args or expansion parses', () {
      final c = cmd('ls');
      expect(lit(c.name!), 'ls');
      expect(c.args, isEmpty);
    });

    test('echo hi', () {
      final c = cmd('echo hi');
      expect(lit(c.name!), 'echo');
      expect(c.args, hasLength(1));
      expect(lit(c.args.single), 'hi');
    });

    test('command with several args', () {
      final c = cmd('cat a b c');
      expect(lit(c.name!), 'cat');
      expect(c.args.map(lit), ['a', 'b', 'c']);
    });

    test('option-style args', () {
      final c = cmd('grep -n foo');
      expect(c.args.map(lit), ['-n', 'foo']);
    });
  });

  group('quoting', () {
    test('single-quoted arg', () {
      final c = cmd("echo 'hello world'");
      final part = c.args.single.parts.single;
      expect(part, isA<SingleQuotedPart>());
      expect((part as SingleQuotedPart).value, 'hello world');
    });

    test('double-quoted literal arg', () {
      final c = cmd('echo "hello world"');
      final part = c.args.single.parts.single as DoubleQuotedPart;
      expect((part.parts.single as LiteralPart).value, 'hello world');
    });

    test('double-quoted with variable', () {
      final c = cmd(r'echo "$HOME/x"');
      final dq = c.args.single.parts.single as DoubleQuotedPart;
      expect(dq.parts.first, isA<ParameterExpansionPart>());
      expect((dq.parts.first as ParameterExpansionPart).parameter, 'HOME');
      expect((dq.parts[1] as LiteralPart).value, '/x');
    });
  });

  group('parameter expansion', () {
    test('simple variable', () {
      final c = cmd(r'echo $HOME');
      final pe = c.args.single.parts.single as ParameterExpansionPart;
      expect(pe.parameter, 'HOME');
      expect(pe.operation, isNull);
    });

    test('special parameter', () {
      final pe = cmd(r'echo $?').args.single.parts.single
          as ParameterExpansionPart;
      expect(pe.parameter, '?');
    });

    test('default value operation', () {
      final pe = cmd(r'echo ${VAR:-fallback}').args.single.parts.single
          as ParameterExpansionPart;
      expect(pe.parameter, 'VAR');
      final op = pe.operation! as DefaultValueOp;
      expect(op.checkEmpty, isTrue);
      expect((op.word.parts.single as LiteralPart).value, 'fallback');
    });

    test('length operation', () {
      final pe = cmd(r'echo ${#VAR}').args.single.parts.single
          as ParameterExpansionPart;
      expect(pe.parameter, 'VAR');
      expect(pe.operation, isA<LengthOp>());
    });

    test('pattern removal', () {
      final pe = cmd(r'echo ${file%.txt}').args.single.parts.single
          as ParameterExpansionPart;
      final op = pe.operation! as PatternRemovalOp;
      expect(op.side, 'suffix');
      expect(op.greedy, isFalse);
    });
  });

  group('globs, braces, tilde', () {
    test('glob star plus literal', () {
      final parts = cmd('ls *.txt').args.single.parts;
      expect((parts[0] as GlobPart).pattern, '*');
      expect((parts[1] as LiteralPart).value, '.txt');
    });

    test('brace list expansion', () {
      final be = cmd('echo {a,b,c}').args.single.parts.single
          as BraceExpansionPart;
      expect(be.items, hasLength(3));
    });

    test('numeric brace range', () {
      final be = cmd('echo {1..5}').args.single.parts.single
          as BraceExpansionPart;
      final range = be.items.single as BraceRangeItem;
      expect(range.start, 1);
      expect(range.end, 5);
    });

    test('tilde expansion at start of word', () {
      final part = cmd('echo ~/docs').args.single.parts.first;
      expect(part, isA<TildeExpansionPart>());
    });
  });

  group('assignments', () {
    test('prefix assignment', () {
      final c = cmd('VAR=value');
      expect(c.name, isNull);
      expect(c.assignments.single.name, 'VAR');
      expect(lit(c.assignments.single.value!), 'value');
    });

    test('assignment then command', () {
      final c = cmd('X=1 echo hi');
      expect(c.assignments.single.name, 'X');
      expect(lit(c.name!), 'echo');
    });
  });

  group('pipelines and lists', () {
    test('pipeline of two commands', () {
      final stmt = parse('echo hi | grep h').statements.single;
      final pipe = stmt.pipelines.single;
      expect(pipe.commands, hasLength(2));
    });

    test('and-or list', () {
      final stmt = parse('echo a && echo b').statements.single;
      expect(stmt.pipelines, hasLength(2));
      expect(stmt.operators, ['&&']);
    });

    test('background statement', () {
      final stmt = parse('sleep 1 &').statements.single;
      expect(stmt.background, isTrue);
    });
  });

  group('redirections', () {
    test('output redirection', () {
      final c = cmd('echo hi > out.txt');
      expect(c.redirections.single.operator, '>');
      expect(lit(c.redirections.single.target as WordNode), 'out.txt');
    });

    test('append and fd-dup', () {
      final c = cmd('cmd >> log 2>&1');
      expect(c.redirections[0].operator, '>>');
      expect(c.redirections[1].operator, '>&');
      expect(c.redirections[1].fd, 2);
    });
  });

  group('compound commands', () {
    test('if/then/fi', () {
      final node =
          parse('if true; then echo yes; fi').statements.single.pipelines
              .single.commands.single;
      expect(node, isA<IfNode>());
      expect((node as IfNode).clauses, hasLength(1));
    });

    test('for loop', () {
      final node = parse(r'for x in a b c; do echo $x; done')
          .statements.single.pipelines.single.commands.single;
      expect(node, isA<ForNode>());
      expect((node as ForNode).variable, 'x');
      expect(node.words, hasLength(3));
    });

    test('while loop', () {
      final node = parse('while false; do echo x; done')
          .statements.single.pipelines.single.commands.single;
      expect(node, isA<WhileNode>());
    });
  });

  group('command substitution now parses', () {
    test(r'$(...) parses into a CommandSubstitutionPart', () {
      final part = cmd(r'echo $(date)').args.single.parts.single;
      expect(part, isA<CommandSubstitutionPart>());
      expect((part as CommandSubstitutionPart).legacy, isFalse);
    });

    test('backtick parses into a legacy CommandSubstitutionPart', () {
      final part = cmd('echo `date`').args.single.parts.single;
      expect(part, isA<CommandSubstitutionPart>());
      expect((part as CommandSubstitutionPart).legacy, isTrue);
    });
  });

  group('arithmetic now parses', () {
    test(r'$((...)) parses into an ArithmeticExpansionPart', () {
      final part = cmd(r'echo $((1 + 2))').args.single.parts.single;
      expect(part, isA<ArithmeticExpansionPart>());
    });

    test(r'$((...)) with nested parens stays arithmetic, not subshell', () {
      final part = cmd(r'echo $(((1 + 2) * 3))').args.single.parts.single;
      expect(part, isA<ArithmeticExpansionPart>());
    });

    test('(( ... )) parses into an ArithmeticCommandNode', () {
      final node = parse('(( 1 + 2 ))')
          .statements.single.pipelines.single.commands.single;
      expect(node, isA<ArithmeticCommandNode>());
    });

    test('C-style for parses into a CStyleForNode', () {
      final node = parse('for ((i=0; i<3; i++)); do echo x; done')
          .statements.single.pipelines.single.commands.single;
      expect(node, isA<CStyleForNode>());
    });
  });

  // These stubbed sub-parsers are not yet ported. The assertions make the
  // boundaries visible in the suite so the gaps cannot regress silently.
  group('not-yet-ported boundaries throw UnimplementedError', () {
    test('conditional command [[ ... ]]', () {
      expect(() => parse('[[ x ]]'), throwsUnimplementedError);
    });
  });
}
