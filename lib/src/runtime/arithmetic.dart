/// Runtime arithmetic evaluator.
///
/// Walks an [ArithExpr] tree (produced by the arithmetic parser) and computes
/// an integer result with bash integer semantics. Variables are resolved and
/// their string values are recursively re-parsed and evaluated, matching bash.
///
/// This is a focused evaluator: numbers (all bases), variables, every binary
/// and unary operator, ternary, scalar assignment (incl. compound and
/// increment/decrement), grouping and nesting. Array elements, dynamic names,
/// command substitution inside arithmetic, and special variables are not yet
/// supported and throw [UnimplementedError] at their boundary.
library;

import 'package:dbash/src/ast/ast.dart';
import 'package:dbash/src/parser/parser.dart';

/// Evaluates arithmetic expressions against a variable store.
class ArithEvaluator {
  /// Creates an evaluator reading/writing variables via [getVar]/[setVar].
  ArithEvaluator({required this.getVar, required this.setVar});

  /// Reads a variable's raw string value (null if unset).
  final String? Function(String name) getVar;

  /// Writes a variable's value (stored as its decimal string).
  final void Function(String name, String value) setVar;

  int _depth = 0;

  /// Evaluate an arithmetic expression wrapper.
  int evaluate(ArithmeticExpressionNode node) => eval(node.expression);

  /// Evaluate an arithmetic expression node to an integer.
  int eval(ArithExpr node) {
    switch (node) {
      case ArithNumberNode():
        return _toInt(node.value);
      case ArithVariableNode():
        return _evalVarName(node.name);
      case ArithBracedExpansionNode():
        if (_isName(node.content)) return _evalVarName(node.content);
        throw UnimplementedError(
          r'complex ${...} inside arithmetic is not supported yet',
        );
      case ArithSingleQuoteNode():
        return _toInt(node.value);
      case ArithGroupNode():
        return eval(node.expression);
      case ArithNestedNode():
        return eval(node.expression);
      case ArithBinaryNode():
        return _evalBinary(node);
      case ArithUnaryNode():
        return _evalUnary(node);
      case ArithTernaryNode():
        return eval(node.condition) != 0
            ? eval(node.consequent)
            : eval(node.alternate);
      case ArithAssignmentNode():
        return _evalAssignment(node);
      case ArithSyntaxErrorNode():
        throw ArithmeticError(node.message);
      case ArithNumberSubscriptNode():
        throw ArithmeticError(
          '${node.errorToken}: syntax error: invalid arithmetic operator',
        );
      case ArithDoubleSubscriptNode():
        throw ArithmeticError('${node.array}: bad array subscript');
      case ArithArrayElementNode():
      case ArithDynamicAssignmentNode():
      case ArithDynamicElementNode():
      case ArithConcatNode():
      case ArithCommandSubstNode():
      case ArithSpecialVarNode():
      case ArithDynamicBaseNode():
      case ArithDynamicNumberNode():
        throw UnimplementedError(
          'arithmetic node ${node.type} is not supported yet',
        );
    }
  }

  int _evalBinary(ArithBinaryNode node) {
    switch (node.operator) {
      case '&&':
        return (eval(node.left) != 0 && eval(node.right) != 0) ? 1 : 0;
      case '||':
        return (eval(node.left) != 0 || eval(node.right) != 0) ? 1 : 0;
      case ',':
        eval(node.left);
        return eval(node.right);
    }
    final l = eval(node.left);
    final r = eval(node.right);
    switch (node.operator) {
      case '+':
        return l + r;
      case '-':
        return l - r;
      case '*':
        return l * r;
      case '/':
        if (r == 0) throw ArithmeticError('division by 0');
        return l ~/ r;
      case '%':
        if (r == 0) throw ArithmeticError('division by 0');
        return l.remainder(r);
      case '**':
        if (r < 0) throw ArithmeticError('exponent less than 0');
        return _ipow(l, r);
      case '<<':
        return l << r;
      case '>>':
        return l >> r;
      case '&':
        return l & r;
      case '|':
        return l | r;
      case '^':
        return l ^ r;
      case '<':
        return l < r ? 1 : 0;
      case '<=':
        return l <= r ? 1 : 0;
      case '>':
        return l > r ? 1 : 0;
      case '>=':
        return l >= r ? 1 : 0;
      case '==':
        return l == r ? 1 : 0;
      case '!=':
        return l != r ? 1 : 0;
    }
    throw ArithmeticError('unknown operator ${node.operator}');
  }

  int _evalUnary(ArithUnaryNode node) {
    if (node.operator == '++' || node.operator == '--') {
      final operand = node.operand;
      if (operand is! ArithVariableNode) {
        throw ArithmeticError('attempted assignment to non-variable');
      }
      final old = _evalVarName(operand.name);
      final updated = node.operator == '++' ? old + 1 : old - 1;
      setVar(operand.name, updated.toString());
      return node.prefix ? updated : old;
    }
    final v = eval(node.operand);
    switch (node.operator) {
      case '-':
        return -v;
      case '+':
        return v;
      case '!':
        return v == 0 ? 1 : 0;
      case '~':
        return ~v;
    }
    throw ArithmeticError('unknown unary operator ${node.operator}');
  }

  int _evalAssignment(ArithAssignmentNode node) {
    if (node.subscript != null || node.stringKey != null) {
      throw UnimplementedError(
        'array element assignment in arithmetic is not supported yet',
      );
    }
    final rhs = eval(node.value);
    final int result;
    if (node.operator == '=') {
      result = rhs;
    } else {
      final cur = _evalVarName(node.variable);
      result = _applyCompound(node.operator, cur, rhs);
    }
    setVar(node.variable, result.toString());
    return result;
  }

  int _applyCompound(String op, int cur, int rhs) {
    switch (op) {
      case '+=':
        return cur + rhs;
      case '-=':
        return cur - rhs;
      case '*=':
        return cur * rhs;
      case '/=':
        if (rhs == 0) throw ArithmeticError('division by 0');
        return cur ~/ rhs;
      case '%=':
        if (rhs == 0) throw ArithmeticError('division by 0');
        return cur.remainder(rhs);
      case '<<=':
        return cur << rhs;
      case '>>=':
        return cur >> rhs;
      case '&=':
        return cur & rhs;
      case '|=':
        return cur | rhs;
      case '^=':
        return cur ^ rhs;
    }
    throw ArithmeticError('unknown assignment operator $op');
  }

  int _evalVarName(String name) {
    if (++_depth > 1000) {
      _depth--;
      throw ArithmeticError('expression recursion level exceeded');
    }
    try {
      final raw = getVar(name);
      if (raw == null || raw.trim().isEmpty) return 0;
      final node = Parser().parseArithmeticExpression(raw);
      return eval(node.expression);
    } finally {
      _depth--;
    }
  }

  int _toInt(num v) {
    if (v.isNaN || v.isInfinite) {
      throw ArithmeticError('invalid number');
    }
    return v.toInt();
  }

  static int _ipow(int base, int exp) {
    var result = 1;
    var b = base;
    var e = exp;
    while (e > 0) {
      if (e & 1 == 1) result *= b;
      e >>= 1;
      if (e > 0) b *= b;
    }
    return result;
  }

  static final RegExp _nameRe = RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$');
  static bool _isName(String s) => _nameRe.hasMatch(s);
}
