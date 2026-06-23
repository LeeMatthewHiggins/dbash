import 'package:dbash/src/ast/ast.dart';
import 'package:test/test.dart';

WordNode _w(String s) => WordNode([LiteralPart(s)]);

void main() {
  group('discriminant strings match upstream', () {
    test('structural nodes', () {
      expect(ScriptNode([]).type, 'Script');
      expect(StatementNode([]).type, 'Statement');
      expect(PipelineNode([]).type, 'Pipeline');
      expect(SimpleCommandNode(name: _w('echo')).type, 'SimpleCommand');
    });

    test('control-flow nodes', () {
      expect(IfNode([]).type, 'If');
      expect(ForNode('i', null, []).type, 'For');
      expect(WhileNode([], []).type, 'While');
      expect(UntilNode([], []).type, 'Until');
      expect(CaseNode(_w('x'), []).type, 'Case');
      expect(SubshellNode([]).type, 'Subshell');
      expect(GroupNode([]).type, 'Group');
    });

    test('word parts', () {
      expect(LiteralPart('a').type, 'Literal');
      expect(SingleQuotedPart('a').type, 'SingleQuoted');
      expect(DoubleQuotedPart([]).type, 'DoubleQuoted');
      expect(EscapedPart('a').type, 'Escaped');
      expect(ParameterExpansionPart('VAR').type, 'ParameterExpansion');
      expect(GlobPart('*').type, 'Glob');
      expect(TildeExpansionPart(null).type, 'TildeExpansion');
    });

    test('parameter operations', () {
      expect(DefaultValueOp(_w('d'), true).type, 'DefaultValue');
      expect(LengthOp().type, 'Length');
      expect(PatternRemovalOp(_w('p'), 'prefix', false).type, 'PatternRemoval');
      expect(IndirectionOp().type, 'Indirection');
    });

    test('arithmetic nodes', () {
      expect(ArithNumberNode(42).type, 'ArithNumber');
      expect(ArithVariableNode('x').type, 'ArithVariable');
      expect(
        ArithBinaryNode('+', ArithNumberNode(1), ArithNumberNode(2)).type,
        'ArithBinary',
      );
    });

    test('conditional nodes', () {
      expect(CondWordNode(_w('x')).type, 'CondWord');
      expect(CondBinaryNode('==', _w('a'), _w('b')).type, 'CondBinary');
      expect(CondNotNode(CondWordNode(_w('x'))).type, 'CondNot');
    });
  });

  group('sealed-class membership', () {
    test('command union', () {
      expect(SimpleCommandNode(name: null), isA<CommandNode>());
      expect(IfNode([]), isA<CompoundCommandNode>());
      expect(IfNode([]), isA<CommandNode>());
      expect(FunctionDefNode('f', GroupNode([])), isA<CommandNode>());
    });

    test('word part union', () {
      expect(LiteralPart('a'), isA<WordPart>());
      expect(CommandSubstitutionPart(ScriptNode([])), isA<WordPart>());
    });

    test('inner parameter operation marker', () {
      expect(DefaultValueOp(_w('d'), false), isA<InnerParameterOperation>());
      expect(LengthOp(), isA<InnerParameterOperation>());
      // ArrayKeys is a ParameterOperation but not an inner op.
      expect(ArrayKeysOp('a', false), isNot(isA<InnerParameterOperation>()));
    });

    test('brace items', () {
      expect(BraceWordItem(_w('a')).type, 'Word');
      expect(BraceRangeItem(1, 10).type, 'Range');
      expect(BraceRangeItem(1, 10), isA<BraceItem>());
    });
  });

  group('exhaustive switch over sealed WordPart compiles', () {
    String kind(WordPart p) => switch (p) {
          LiteralPart() => 'lit',
          SingleQuotedPart() => 'sq',
          DoubleQuotedPart() => 'dq',
          EscapedPart() => 'esc',
          ParameterExpansionPart() => 'param',
          CommandSubstitutionPart() => 'cmdsub',
          ArithmeticExpansionPart() => 'arith',
          ProcessSubstitutionPart() => 'procsub',
          BraceExpansionPart() => 'brace',
          TildeExpansionPart() => 'tilde',
          GlobPart() => 'glob',
        };

    test('returns expected kinds', () {
      expect(kind(LiteralPart('a')), 'lit');
      expect(kind(GlobPart('*')), 'glob');
      expect(kind(ParameterExpansionPart('V')), 'param');
    });
  });
}
